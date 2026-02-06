#include "vcam.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

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

    ctx->fd = open(device, O_WRONLY);
    if (ctx->fd < 0) {
        fprintf(stderr, "vcam: cannot open %s: %s\n", device, strerror(errno));
        free(ctx);
        return NULL;
    }

    ctx->width      = width;
    ctx->height     = height;
    ctx->frame_size = (size_t)width * height * 3 / 2;

    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type                = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width       = width;
    fmt.fmt.pix.height      = height;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUV420;
    fmt.fmt.pix.sizeimage   = ctx->frame_size;
    fmt.fmt.pix.field       = V4L2_FIELD_NONE;

    if (ioctl(ctx->fd, VIDIOC_S_FMT, &fmt) < 0) {
        fprintf(stderr, "vcam: VIDIOC_S_FMT failed: %s\n", strerror(errno));
        close(ctx->fd);
        free(ctx);
        return NULL;
    }

    fprintf(stderr, "vcam: opened %s %dx%d yuv420p\n", device, width, height);
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
    if (ctx->fd >= 0)
        close(ctx->fd);
    free(ctx);
}
