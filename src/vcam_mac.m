/*
 * macOS Virtual Camera Output
 *
 * Writes raw YUV420P frames to stdout (default) or a file path.
 * Designed for piping into ffmpeg/ffplay for preview or encoding:
 *
 *   ./screen2cam | ffplay -f rawvideo -pix_fmt yuv420p -video_size WxH -
 *
 * Uses the same vcam.h interface as the Linux V4L2 implementation.
 */

#include "vcam.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>

struct vcam_ctx {
    int    fd;
    int    width;
    int    height;
    size_t frame_size;   /* width * height * 3 / 2 for YUV420P */
};

vcam_ctx_t *vcam_open(const char *device, int width, int height)
{
    vcam_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx)
        return NULL;

    ctx->width      = width;
    ctx->height     = height;
    ctx->frame_size = (size_t)width * height * 3 / 2;

    if (strcmp(device, "-") == 0 || strcmp(device, "/dev/stdout") == 0) {
        ctx->fd = STDOUT_FILENO;
    } else {
        ctx->fd = open(device, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (ctx->fd < 0) {
            fprintf(stderr, "vcam: cannot open %s: %s\n", device, strerror(errno));
            free(ctx);
            return NULL;
        }
    }

    /* Ignore SIGPIPE so broken-pipe returns EPIPE to write() instead of killing us */
    signal(SIGPIPE, SIG_IGN);

    fprintf(stderr, "vcam: output %dx%d yuv420p -> %s\n", width, height, device);
    return ctx;
}

int vcam_write(vcam_ctx_t *ctx, const uint8_t *yuv420p, size_t len)
{
    if (len < ctx->frame_size)
        return -1;

    size_t written = 0;
    while (written < ctx->frame_size) {
        ssize_t n = write(ctx->fd, yuv420p + written, ctx->frame_size - written);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EPIPE)
                return -1;   /* reader closed — graceful exit */
            perror("vcam: write");
            return -1;
        }
        written += n;
    }
    return 0;
}

void vcam_close(vcam_ctx_t *ctx)
{
    if (!ctx)
        return;
    if (ctx->fd >= 0 && ctx->fd != STDOUT_FILENO)
        close(ctx->fd);
    free(ctx);
}
