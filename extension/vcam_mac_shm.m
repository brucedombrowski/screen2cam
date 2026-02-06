/*
 * macOS Virtual Camera Output — updated for Camera Extension support
 *
 * DROP-IN REPLACEMENT for src/vcam_mac.m
 *
 * Two output modes:
 *
 *   1. Pipe mode (default / "-"): Writes raw YUV420P frames to stdout
 *      for piping into bridge.py / ffmpeg / ffplay.
 *
 *   2. Extension mode ("shm"): Writes BGRA frames to POSIX shared memory
 *      for the screen2cam Camera Extension (CMIOExtension) to read.
 *      This eliminates the need for OBS and bridge.py.
 *
 * Usage:
 *   ./screen2cam --device -   --fps 15 | python3 bridge.py W H 15   # pipe mode (existing)
 *   ./screen2cam --device shm --fps 15                               # extension mode (new)
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
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdatomic.h>

#include "../extension/shm_protocol.h"

typedef enum {
    VCAM_MODE_PIPE,   /* stdout / file — raw YUV420P */
    VCAM_MODE_SHM     /* shared memory — BGRA for Camera Extension */
} vcam_mode_t;

struct vcam_ctx {
    vcam_mode_t mode;
    int         width;
    int         height;
    int         fd;
    size_t      frame_size;

    /* Shared memory (extension mode only) */
    shm_header_t *shm_hdr;
    size_t        shm_size;
};

/* ── Pipe mode (unchanged from original) ──────────────────── */

static vcam_ctx_t *pipe_open(const char *device, int width, int height)
{
    vcam_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    ctx->mode       = VCAM_MODE_PIPE;
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

    signal(SIGPIPE, SIG_IGN);
    fprintf(stderr, "vcam: output %dx%d yuv420p -> %s\n", width, height, device);
    return ctx;
}

static int pipe_write(vcam_ctx_t *ctx, const uint8_t *yuv420p, size_t len)
{
    if (len < ctx->frame_size)
        return -1;

    size_t written = 0;
    while (written < ctx->frame_size) {
        ssize_t n = write(ctx->fd, yuv420p + written, ctx->frame_size - written);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EPIPE) return -1;
            perror("vcam: write");
            return -1;
        }
        written += n;
    }
    return 0;
}

static void pipe_close(vcam_ctx_t *ctx)
{
    if (ctx->fd >= 0 && ctx->fd != STDOUT_FILENO)
        close(ctx->fd);
}

/* ── Shared memory mode (Camera Extension) ────────────────── */

static vcam_ctx_t *shm_open_ctx(int width, int height, int fps)
{
    size_t total = shm_total_size(width, height);

    int fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        fprintf(stderr, "vcam: shm_open(%s): %s\n", SHM_NAME, strerror(errno));
        return NULL;
    }

    if (ftruncate(fd, total) < 0) {
        fprintf(stderr, "vcam: ftruncate: %s\n", strerror(errno));
        close(fd);
        return NULL;
    }

    shm_header_t *hdr = mmap(NULL, total, PROT_READ | PROT_WRITE,
                              MAP_SHARED, fd, 0);
    if (hdr == MAP_FAILED) {
        fprintf(stderr, "vcam: mmap: %s\n", strerror(errno));
        close(fd);
        return NULL;
    }

    hdr->magic     = SHM_MAGIC;
    hdr->version   = SHM_VERSION;
    hdr->width     = width;
    hdr->height    = height;
    hdr->fps       = fps;
    hdr->stride    = width * 4;
    hdr->pixel_fmt = 'BGRA';
    atomic_store_explicit(&hdr->frame_seq, 0, memory_order_release);

    vcam_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        munmap(hdr, total);
        close(fd);
        return NULL;
    }

    ctx->mode       = VCAM_MODE_SHM;
    ctx->width      = width;
    ctx->height     = height;
    ctx->fd         = fd;
    ctx->frame_size = (size_t)width * height * 4;
    ctx->shm_hdr    = hdr;
    ctx->shm_size   = total;

    fprintf(stderr, "vcam: output %dx%d bgra -> shared memory (%s)\n",
            width, height, SHM_NAME);
    fprintf(stderr, "vcam: Camera Extension can now read frames\n");
    return ctx;
}

/*
 * YUV420P → BGRA (BT.601 inverse) — reverse of convert.c
 *
 * TODO: Eliminate double conversion by passing BGRA directly from
 * capture when in extension mode. Requires a vcam_write_bgra() path
 * or a flag in main.c to skip bgra_to_yuv420p().
 */
static void yuv420p_to_bgra(const uint8_t *yuv, uint8_t *bgra, int w, int h)
{
    const uint8_t *y_plane = yuv;
    const uint8_t *u_plane = yuv + w * h;
    const uint8_t *v_plane = u_plane + (w / 2) * (h / 2);

    for (int j = 0; j < h; j++) {
        for (int i = 0; i < w; i++) {
            int y = y_plane[j * w + i];
            int u = u_plane[(j / 2) * (w / 2) + (i / 2)];
            int v = v_plane[(j / 2) * (w / 2) + (i / 2)];

            int c = y - 16;
            int d = u - 128;
            int e = v - 128;

            int r = (298 * c + 409 * e + 128) >> 8;
            int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
            int b = (298 * c + 516 * d + 128) >> 8;

            if (r < 0) r = 0; if (r > 255) r = 255;
            if (g < 0) g = 0; if (g > 255) g = 255;
            if (b < 0) b = 0; if (b > 255) b = 255;

            uint8_t *px = bgra + (j * w + i) * 4;
            px[0] = (uint8_t)b;
            px[1] = (uint8_t)g;
            px[2] = (uint8_t)r;
            px[3] = 255;
        }
    }
}

static int shm_write(vcam_ctx_t *ctx, const uint8_t *yuv420p, size_t len)
{
    size_t yuv_size = (size_t)ctx->width * ctx->height * 3 / 2;
    if (len < yuv_size)
        return -1;

    uint8_t *frame = shm_frame_ptr(ctx->shm_hdr);
    yuv420p_to_bgra(yuv420p, frame, ctx->width, ctx->height);

    atomic_fetch_add_explicit(&ctx->shm_hdr->frame_seq, 1,
                               memory_order_release);
    return 0;
}

static void shm_close(vcam_ctx_t *ctx)
{
    if (ctx->shm_hdr)
        munmap(ctx->shm_hdr, ctx->shm_size);
    if (ctx->fd >= 0) {
        close(ctx->fd);
        shm_unlink(SHM_NAME);
    }
}

/* ── Public interface (vcam.h) ─────────────────────────────── */

vcam_ctx_t *vcam_open(const char *device, int width, int height)
{
    if (strcmp(device, "shm") == 0)
        return shm_open_ctx(width, height, 15);
    return pipe_open(device, width, height);
}

int vcam_write(vcam_ctx_t *ctx, const uint8_t *yuv420p, size_t len)
{
    switch (ctx->mode) {
    case VCAM_MODE_SHM:  return shm_write(ctx, yuv420p, len);
    case VCAM_MODE_PIPE: return pipe_write(ctx, yuv420p, len);
    }
    return -1;
}

void vcam_close(vcam_ctx_t *ctx)
{
    if (!ctx) return;
    switch (ctx->mode) {
    case VCAM_MODE_SHM:  shm_close(ctx);  break;
    case VCAM_MODE_PIPE: pipe_close(ctx);  break;
    }
    free(ctx);
}
