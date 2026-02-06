/*
 * Windows Virtual Camera Output
 *
 * Writes raw YUV420P frames to stdout (default) or a file path.
 * Near-identical to vcam_mac.m but uses Windows CRT equivalents:
 *   - _fileno(stdout) instead of STDOUT_FILENO
 *   - _setmode(fd, _O_BINARY) to prevent \n -> \r\n corruption
 *   - _open() / _write() / _close() for file I/O
 *
 * Designed for piping into ffmpeg/ffplay for preview or encoding:
 *   screen2cam.exe | ffplay -f rawvideo -pix_fmt yuv420p -video_size WxH -
 *
 * Uses the same vcam.h interface as Linux and macOS implementations.
 */

#include "vcam.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <io.h>
#include <errno.h>

struct vcam_ctx {
    int    fd;
    int    is_stdout;
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

    if (strcmp(device, "-") == 0) {
        ctx->fd = _fileno(stdout);
        ctx->is_stdout = 1;
        /* Critical: prevent \n -> \r\n translation on binary data */
        if (_setmode(ctx->fd, _O_BINARY) == -1) {
            fprintf(stderr, "vcam: _setmode(stdout, _O_BINARY) failed\n");
            free(ctx);
            return NULL;
        }
    } else {
        ctx->fd = _open(device, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY, 0644);
        ctx->is_stdout = 0;
        if (ctx->fd < 0) {
            fprintf(stderr, "vcam: cannot open %s: %s\n", device, strerror(errno));
            free(ctx);
            return NULL;
        }
    }

    fprintf(stderr, "vcam: output %dx%d yuv420p -> %s\n", width, height, device);
    return ctx;
}

int vcam_write(vcam_ctx_t *ctx, const uint8_t *yuv420p, size_t len)
{
    if (len < ctx->frame_size)
        return -1;

    size_t written = 0;
    while (written < ctx->frame_size) {
        int n = _write(ctx->fd, yuv420p + written,
                       (unsigned int)(ctx->frame_size - written));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            /* Broken pipe or other error — graceful exit */
            perror("vcam: write");
            return -1;
        }
        written += (size_t)n;
    }
    return 0;
}

void vcam_close(vcam_ctx_t *ctx)
{
    if (!ctx)
        return;
    if (ctx->fd >= 0 && !ctx->is_stdout)
        _close(ctx->fd);
    free(ctx);
}
