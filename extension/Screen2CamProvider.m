/*
 * screen2cam Camera Extension (macOS 12.3+)
 *
 * CMIOExtension-based virtual camera that reads BGRA frames from
 * shared memory written by the screen2cam host process.
 *
 * Architecture:
 *   Screen2CamProviderSource  — CMIOExtensionProviderSource (top-level)
 *   Screen2CamDeviceSource    — CMIOExtensionDeviceSource (one virtual camera)
 *   Screen2CamStreamSource    — CMIOExtensionStreamSource (one video stream)
 *
 * The stream source polls shared memory for new frames and serves them
 * to consuming apps (Teams, Zoom, FaceTime, etc.).
 *
 * Build: Requires Xcode, must be code-signed and embedded in a host .app.
 *        See extension/README.md for build instructions.
 *
 * Frameworks: CoreMediaIO, CoreMedia, CoreVideo, Foundation
 */

#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include "shm_protocol.h"

/* ── Shared memory reader ──────────────────────────────────── */

typedef struct {
    int             fd;
    shm_header_t   *hdr;
    size_t          mapped_size;
    uint64_t        last_seq;
} shm_reader_t;

static shm_reader_t *shm_reader_open(void)
{
    int fd = shm_open(SHM_NAME, O_RDONLY, 0);
    if (fd < 0)
        return NULL;

    /* Map just the header first to read dimensions */
    shm_header_t *hdr = mmap(NULL, sizeof(shm_header_t),
                              PROT_READ, MAP_SHARED, fd, 0);
    if (hdr == MAP_FAILED) {
        close(fd);
        return NULL;
    }

    if (hdr->magic != SHM_MAGIC || hdr->version != SHM_VERSION) {
        munmap(hdr, sizeof(shm_header_t));
        close(fd);
        return NULL;
    }

    /* Remap with full frame size */
    size_t total = shm_total_size(hdr->width, hdr->height);
    munmap(hdr, sizeof(shm_header_t));

    hdr = mmap(NULL, total, PROT_READ, MAP_SHARED, fd, 0);
    if (hdr == MAP_FAILED) {
        close(fd);
        return NULL;
    }

    shm_reader_t *r = calloc(1, sizeof(*r));
    r->fd = fd;
    r->hdr = hdr;
    r->mapped_size = total;
    r->last_seq = 0;
    return r;
}

static void shm_reader_close(shm_reader_t *r)
{
    if (!r) return;
    if (r->hdr) munmap(r->hdr, r->mapped_size);
    if (r->fd >= 0) close(r->fd);
    free(r);
}

/* ── Stream Source ─────────────────────────────────────────── */

@interface Screen2CamStreamSource : NSObject <CMIOExtensionStreamSource>
{
    shm_reader_t        *_reader;
    CMIOExtensionStream *_stream;
    dispatch_source_t    _timer;
    uint32_t             _width;
    uint32_t             _height;
    int                  _fps;
}

@property (nonatomic, strong) CMIOExtensionStreamFormat *activeFormat;

- (instancetype)initWithWidth:(uint32_t)w height:(uint32_t)h fps:(int)fps;
- (void)startStreamingToStream:(CMIOExtensionStream *)stream;
- (void)stopStreaming;

@end

@implementation Screen2CamStreamSource

- (instancetype)initWithWidth:(uint32_t)w height:(uint32_t)h fps:(int)fps
{
    self = [super init];
    if (self) {
        _width = w;
        _height = h;
        _fps = fps;

        CMVideoFormatDescriptionRef desc = NULL;
        CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                        kCVPixelFormatType_32BGRA,
                                        w, h, NULL, &desc);

        CMIOExtensionStreamFormat *fmt =
            [[CMIOExtensionStreamFormat alloc] initWithFormatDescription:desc
                                                       maxFrameDuration:CMTimeMake(1, fps)
                                                       minFrameDuration:CMTimeMake(1, fps)
                                                            validFrameDurations:nil];
        self.activeFormat = fmt;
        CFRelease(desc);
    }
    return self;
}

- (NSArray<CMIOExtensionStreamFormat *> *)formats
{
    return @[self.activeFormat];
}

- (CMIOExtensionStreamFormat *)activeFormatIndex
{
    return self.activeFormat;
}

- (CMTime)frameDuration
{
    return CMTimeMake(1, _fps);
}

- (void)startStreamingToStream:(CMIOExtensionStream *)stream
{
    _stream = stream;
    _reader = shm_reader_open();

    if (!_reader) {
        NSLog(@"screen2cam-ext: shared memory not available yet, will retry");
    }

    /* Timer fires at target FPS to poll shared memory */
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));

    uint64_t interval = (uint64_t)(1000000000.0 / _fps);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, interval, interval / 10);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf pollAndSendFrame];
    });

    dispatch_resume(_timer);
}

- (void)stopStreaming
{
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    shm_reader_close(_reader);
    _reader = NULL;
    _stream = nil;
}

- (void)pollAndSendFrame
{
    /* Retry connection if not yet open */
    if (!_reader) {
        _reader = shm_reader_open();
        if (!_reader) return;
    }

    /* Check for new frame */
    uint64_t seq = atomic_load_explicit(&_reader->hdr->frame_seq,
                                         memory_order_acquire);
    if (seq == _reader->last_seq)
        return;  /* No new frame */

    _reader->last_seq = seq;

    /* Create CVPixelBuffer from shared memory data */
    CVPixelBufferRef pixbuf = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                           _width, _height,
                                           kCVPixelFormatType_32BGRA,
                                           NULL, &pixbuf);
    if (status != kCVReturnSuccess || !pixbuf)
        return;

    CVPixelBufferLockBaseAddress(pixbuf, 0);
    void *dest = CVPixelBufferGetBaseAddress(pixbuf);
    size_t destStride = CVPixelBufferGetBytesPerRow(pixbuf);
    size_t srcStride = _width * 4;

    const uint8_t *src = shm_frame_ptr_const(_reader->hdr);

    if (destStride == srcStride) {
        memcpy(dest, src, srcStride * _height);
    } else {
        for (uint32_t row = 0; row < _height; row++) {
            memcpy((uint8_t *)dest + row * destStride,
                   src + row * srcStride,
                   srcStride);
        }
    }

    CVPixelBufferUnlockBaseAddress(pixbuf, 0);

    /* Wrap in CMSampleBuffer and send */
    CMVideoFormatDescriptionRef fmtDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                  pixbuf, &fmtDesc);

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, _fps),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef sampleBuf = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                              pixbuf, fmtDesc,
                                              &timing, &sampleBuf);

    if (sampleBuf) {
        [_stream sendSampleBuffer:sampleBuf
                   discontinuity:CMIOExtensionStreamDiscontinuityFlagNone
                   hostTimeInNanoseconds:(uint64_t)(CMTimeGetSeconds(timing.presentationTimeStamp) * 1e9)];
        CFRelease(sampleBuf);
    }

    if (fmtDesc) CFRelease(fmtDesc);
    CVPixelBufferRelease(pixbuf);
}

/* Required CMIOExtensionStreamSource methods */

- (CMIOExtensionStreamProperties *)propertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties
                                                     error:(NSError **)outError
{
    return [[CMIOExtensionStreamProperties alloc] initWithDictionary:@{}];
}

- (BOOL)setPropertyValues:(CMIOExtensionStreamProperties *)properties
                    error:(NSError **)outError
{
    return YES;
}

- (BOOL)authorizedToStartStreamForClient:(CMIOExtensionClient *)client
{
    return YES;
}

- (BOOL)startStreamAndReturnError:(NSError **)outError
{
    return YES;
}

- (void)stopStream
{
    [self stopStreaming];
}

@end

/* ── Device Source ─────────────────────────────────────────── */

@interface Screen2CamDeviceSource : NSObject <CMIOExtensionDeviceSource>

@property (nonatomic, strong) Screen2CamStreamSource *streamSource;
@property (nonatomic, strong) CMIOExtensionStream *stream;

- (instancetype)initWithWidth:(uint32_t)w height:(uint32_t)h fps:(int)fps;

@end

@implementation Screen2CamDeviceSource

- (instancetype)initWithWidth:(uint32_t)w height:(uint32_t)h fps:(int)fps
{
    self = [super init];
    if (self) {
        _streamSource = [[Screen2CamStreamSource alloc] initWithWidth:w height:h fps:fps];
    }
    return self;
}

- (NSArray<CMIOExtensionStream *> *)streams
{
    return self.stream ? @[self.stream] : @[];
}

- (CMIOExtensionDeviceProperties *)propertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties
                                                     error:(NSError **)outError
{
    CMIOExtensionDeviceProperties *props = [[CMIOExtensionDeviceProperties alloc] initWithDictionary:@{}];
    [props setTransportType:@(kIOAudioDeviceTransportTypeVirtual)];
    return props;
}

- (BOOL)setPropertyValues:(CMIOExtensionDeviceProperties *)properties
                    error:(NSError **)outError
{
    return YES;
}

@end

/* ── Provider Source ───────────────────────────────────────── */

@interface Screen2CamProviderSource : NSObject <CMIOExtensionProviderSource>

@property (nonatomic, strong) Screen2CamDeviceSource *deviceSource;
@property (nonatomic, strong) CMIOExtensionDevice *device;
@property (nonatomic, strong) CMIOExtensionProvider *provider;

@end

@implementation Screen2CamProviderSource

- (CMIOExtensionProvider *)createProviderWithClientQueue:(dispatch_queue_t)queue
{
    /* Default to 1920x1080 @ 30fps — host will update via shm header */
    uint32_t w = 1920, h = 1080;
    int fps = 30;

    /* Try to read dimensions from shared memory */
    shm_reader_t *reader = shm_reader_open();
    if (reader) {
        w = reader->hdr->width;
        h = reader->hdr->height;
        fps = reader->hdr->fps;
        shm_reader_close(reader);
    }

    _deviceSource = [[Screen2CamDeviceSource alloc] initWithWidth:w height:h fps:fps];

    _provider = [[CMIOExtensionProvider alloc] initWithSource:self
                                                  clientQueue:queue];

    _device = [[CMIOExtensionDevice alloc] initWithLocalizedName:@"screen2cam"
                                                        deviceID:@"com.screen2cam.device"
                                                      legacyDeviceID:nil
                                                          source:_deviceSource];

    CMIOExtensionStream *stream =
        [[CMIOExtensionStream alloc] initWithLocalizedName:@"screen2cam"
                                                  streamID:@"com.screen2cam.stream"
                                                 direction:CMIOExtensionStreamDirectionSource
                                                  clockType:CMIOExtensionStreamClockTypeHostTime
                                                    source:_deviceSource.streamSource];

    _deviceSource.stream = stream;

    NSError *error = nil;
    [_provider addDevice:_device error:&error];
    if (error) {
        NSLog(@"screen2cam-ext: addDevice error: %@", error);
    }

    [_device addStream:stream error:&error];
    if (error) {
        NSLog(@"screen2cam-ext: addStream error: %@", error);
    }

    return _provider;
}

- (NSArray<CMIOExtensionDevice *> *)availableDevices
{
    return self.device ? @[self.device] : @[];
}

- (CMIOExtensionProviderProperties *)propertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties
                                                       error:(NSError **)outError
{
    return [[CMIOExtensionProviderProperties alloc] initWithDictionary:@{}];
}

- (BOOL)setPropertyValues:(CMIOExtensionProviderProperties *)properties
                    error:(NSError **)outError
{
    return YES;
}

- (void)connectClient:(CMIOExtensionClient *)client error:(NSError **)outError
{
    NSLog(@"screen2cam-ext: client connected: %@", client.signingID);
}

- (void)disconnectClient:(CMIOExtensionClient *)client
{
    NSLog(@"screen2cam-ext: client disconnected: %@", client.signingID);
}

@end

/* ── Extension entry point ─────────────────────────────────── */

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        Screen2CamProviderSource *providerSource = [[Screen2CamProviderSource alloc] init];

        CMIOExtensionProvider *provider =
            [providerSource createProviderWithClientQueue:
                dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)];

        [CMIOExtensionProvider startServiceWithProvider:provider];

        NSLog(@"screen2cam-ext: Camera Extension started");
        CFRunLoopRun();
    }
    return 0;
}
