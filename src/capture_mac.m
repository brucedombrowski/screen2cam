/*
 * macOS Screen Capture Module (ScreenCaptureKit)
 *
 * Implements the capture.h interface using ScreenCaptureKit (macOS 12.3+).
 *
 * Architecture:
 *   - SCStream delivers frames asynchronously via a delegate callback
 *   - Delegate stores the latest CVPixelBuffer (thread-safe via mutex)
 *   - capture_grab() copies pixel data from the latest buffer into a
 *     persistent BGRA buffer that matches convert.c expectations
 *
 * Pixel format: BGRA (byte order: B G R A) — set via kCVPixelFormatType_32BGRA.
 *
 * Notes:
 *   - Requires Screen Recording permission (System Settings > Privacy &
 *     Security > Screen Recording). First API call triggers the prompt.
 *   - ObjC objects stored in C struct via CFBridgingRetain/Release for
 *     ARC compatibility.
 *
 * Frameworks: ScreenCaptureKit, CoreMedia, CoreVideo, CoreGraphics
 */

#include "capture.h"

#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ── Frame receiver (SCStreamOutput delegate) ──────────────── */

@interface SCKFrameReceiver : NSObject <SCStreamOutput>
{
    pthread_mutex_t _lock;
    CVPixelBufferRef _latestPixelBuffer;
}
- (CVPixelBufferRef)copyLatestFrame;
@end

@implementation SCKFrameReceiver

- (instancetype)init
{
    self = [super init];
    if (self) {
        pthread_mutex_init(&_lock, NULL);
        _latestPixelBuffer = NULL;
    }
    return self;
}

- (void)dealloc
{
    if (_latestPixelBuffer)
        CVPixelBufferRelease(_latestPixelBuffer);
    pthread_mutex_destroy(&_lock);
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
               ofType:(SCStreamOutputType)type
{
    (void)stream;
    if (type != SCStreamOutputTypeScreen)
        return;

    CVPixelBufferRef pixbuf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixbuf)
        return;

    CVPixelBufferRetain(pixbuf);

    pthread_mutex_lock(&_lock);
    CVPixelBufferRef old = _latestPixelBuffer;
    _latestPixelBuffer = pixbuf;
    pthread_mutex_unlock(&_lock);

    if (old)
        CVPixelBufferRelease(old);
}

- (CVPixelBufferRef)copyLatestFrame
{
    pthread_mutex_lock(&_lock);
    CVPixelBufferRef buf = _latestPixelBuffer;
    if (buf)
        CVPixelBufferRetain(buf);
    pthread_mutex_unlock(&_lock);
    return buf;
}

@end

/* ── Capture context ───────────────────────────────────────── */

struct capture_ctx {
    void               *stream;      /* SCStream — retained via CFBridgingRetain */
    void               *receiver;    /* SCKFrameReceiver — retained */
    dispatch_queue_t    queue;
    int                 width;
    int                 height;
    uint8_t            *buffer;
    size_t              buffer_size;
};

/* ── Helper: synchronous shareable content query ───────────── */

static SCShareableContent *get_shareable_content(void)
{
    __block SCShareableContent *result = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                             onScreenWindowsOnly:NO
                                               completionHandler:^(SCShareableContent *content,
                                                                   NSError *error) {
        result = content;
        err = error;
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                               5 * NSEC_PER_SEC));

    if (err) {
        fprintf(stderr, "capture_mac: SCShareableContent error: %s\n",
                [[err localizedDescription] UTF8String]);
    }
    return result;
}

/* ── Public interface ──────────────────────────────────────── */

capture_ctx_t *capture_init(void)
{
    @autoreleasepool {
        capture_ctx_t *ctx = calloc(1, sizeof(*ctx));
        if (!ctx)
            return NULL;

        /* Query available displays */
        SCShareableContent *content = get_shareable_content();
        if (!content || content.displays.count == 0) {
            fprintf(stderr, "capture_mac: no displays found\n");
            fprintf(stderr, "capture_mac: check Screen Recording permission "
                            "in System Settings > Privacy & Security\n");
            free(ctx);
            return NULL;
        }

        SCDisplay *display = content.displays[0];
        ctx->width  = (int)(display.width);
        ctx->height = (int)(display.height);

        /* Configure stream: BGRA pixel format, up to 60 fps */
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width  = ctx->width;
        config.height = ctx->height;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.minimumFrameInterval = CMTimeMake(1, 60);
        config.showsCursor = YES;

        /* Filter: capture entire display, exclude nothing */
        SCContentFilter *filter =
            [[SCContentFilter alloc] initWithDisplay:display
                                    excludingWindows:@[]];

        /* Create stream and frame receiver */
        SCStream *stream =
            [[SCStream alloc] initWithFilter:filter
                               configuration:config
                                    delegate:nil];

        SCKFrameReceiver *receiver = [[SCKFrameReceiver alloc] init];
        ctx->queue = dispatch_queue_create("com.screen2cam.capture",
                                           DISPATCH_QUEUE_SERIAL);

        NSError *error = nil;
        if (![stream addStreamOutput:receiver
                                type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:ctx->queue
                               error:&error]) {
            fprintf(stderr, "capture_mac: addStreamOutput: %s\n",
                    [[error localizedDescription] UTF8String]);
            free(ctx);
            return NULL;
        }

        /* Start capture (synchronous wait) */
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSError *startErr = nil;

        [stream startCaptureWithCompletionHandler:^(NSError *err) {
            startErr = err;
            dispatch_semaphore_signal(sem);
        }];

        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                   5 * NSEC_PER_SEC));

        if (startErr) {
            fprintf(stderr, "capture_mac: startCapture: %s\n",
                    [[startErr localizedDescription] UTF8String]);
            free(ctx);
            return NULL;
        }

        /* Retain ObjC objects into the C struct */
        ctx->stream   = (void *)CFBridgingRetain(stream);
        ctx->receiver = (void *)CFBridgingRetain(receiver);

        /* Allocate persistent BGRA buffer */
        ctx->buffer_size = (size_t)ctx->width * ctx->height * 4;
        ctx->buffer = malloc(ctx->buffer_size);
        if (!ctx->buffer) {
            perror("capture_mac: malloc");
            capture_free(ctx);
            return NULL;
        }

        /* Wait for first frame delivery */
        usleep(200000);

        fprintf(stderr, "capture_mac: %dx%d (ScreenCaptureKit)\n",
                ctx->width, ctx->height);
        return ctx;
    }
}

int capture_width(const capture_ctx_t *ctx)  { return ctx->width;  }
int capture_height(const capture_ctx_t *ctx) { return ctx->height; }

const uint8_t *capture_grab(capture_ctx_t *ctx)
{
    @autoreleasepool {
        SCKFrameReceiver *receiver =
            (__bridge SCKFrameReceiver *)ctx->receiver;

        CVPixelBufferRef pixbuf = [receiver copyLatestFrame];
        if (!pixbuf)
            return NULL;

        CVPixelBufferLockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);

        void  *base       = CVPixelBufferGetBaseAddress(pixbuf);
        size_t srcStride  = CVPixelBufferGetBytesPerRow(pixbuf);
        size_t destStride = (size_t)ctx->width * 4;
        int h = ctx->height;

        /* Copy pixel data — handle row padding if present */
        if (srcStride == destStride) {
            memcpy(ctx->buffer, base, destStride * h);
        } else {
            for (int j = 0; j < h; j++) {
                memcpy(ctx->buffer + j * destStride,
                       (uint8_t *)base + j * srcStride,
                       destStride);
            }
        }

        CVPixelBufferUnlockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(pixbuf);

        return ctx->buffer;
    }
}

void capture_free(capture_ctx_t *ctx)
{
    if (!ctx)
        return;

    @autoreleasepool {
        if (ctx->stream) {
            SCStream *stream = (__bridge SCStream *)ctx->stream;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [stream stopCaptureWithCompletionHandler:^(NSError *err) {
                (void)err;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                      2 * NSEC_PER_SEC));
            CFBridgingRelease(ctx->stream);
        }

        if (ctx->receiver)
            CFBridgingRelease(ctx->receiver);
    }

    free(ctx->buffer);
    free(ctx);
}
