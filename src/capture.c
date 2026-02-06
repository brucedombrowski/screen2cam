#include "capture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <X11/extensions/XShm.h>

struct capture_ctx {
    Display        *dpy;
    Window          root;
    int             width;
    int             height;
    int             use_shm;
    XShmSegmentInfo shm_info;
    XImage         *img;
};

capture_ctx_t *capture_init(void)
{
    capture_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx)
        return NULL;

    ctx->dpy = XOpenDisplay(NULL);
    if (!ctx->dpy) {
        fprintf(stderr, "capture: cannot open X display\n");
        free(ctx);
        return NULL;
    }

    Screen *scr = DefaultScreenOfDisplay(ctx->dpy);
    ctx->root   = DefaultRootWindow(ctx->dpy);
    ctx->width  = WidthOfScreen(scr);
    ctx->height = HeightOfScreen(scr);

    /* Try MIT-SHM for fast capture */
    ctx->use_shm = XShmQueryExtension(ctx->dpy) ? 1 : 0;

    if (ctx->use_shm) {
        ctx->img = XShmCreateImage(ctx->dpy,
                                   DefaultVisualOfScreen(scr),
                                   DefaultDepthOfScreen(scr),
                                   ZPixmap, NULL, &ctx->shm_info,
                                   ctx->width, ctx->height);
        if (!ctx->img) {
            ctx->use_shm = 0;
        } else {
            ctx->shm_info.shmid = shmget(IPC_PRIVATE,
                                         (size_t)ctx->img->bytes_per_line * ctx->img->height,
                                         IPC_CREAT | 0600);
            if (ctx->shm_info.shmid < 0) {
                XDestroyImage(ctx->img);
                ctx->img = NULL;
                ctx->use_shm = 0;
            } else {
                ctx->shm_info.shmaddr = ctx->img->data = shmat(ctx->shm_info.shmid, NULL, 0);
                ctx->shm_info.readOnly = False;
                XShmAttach(ctx->dpy, &ctx->shm_info);
                XSync(ctx->dpy, False);
            }
        }
    }

    fprintf(stderr, "capture: %dx%d shm=%s\n",
            ctx->width, ctx->height, ctx->use_shm ? "yes" : "no");
    return ctx;
}

int capture_width(const capture_ctx_t *ctx)  { return ctx->width;  }
int capture_height(const capture_ctx_t *ctx) { return ctx->height; }

const uint8_t *capture_grab(capture_ctx_t *ctx)
{
    if (ctx->use_shm) {
        XShmGetImage(ctx->dpy, ctx->root, ctx->img, 0, 0, AllPlanes);
        return (const uint8_t *)ctx->img->data;
    }

    /* Fallback: slow but works everywhere */
    if (ctx->img) {
        XDestroyImage(ctx->img);
        ctx->img = NULL;
    }
    ctx->img = XGetImage(ctx->dpy, ctx->root,
                         0, 0, ctx->width, ctx->height,
                         AllPlanes, ZPixmap);
    if (!ctx->img)
        return NULL;

    return (const uint8_t *)ctx->img->data;
}

void capture_free(capture_ctx_t *ctx)
{
    if (!ctx)
        return;

    if (ctx->use_shm) {
        XShmDetach(ctx->dpy, &ctx->shm_info);
        shmdt(ctx->shm_info.shmaddr);
        shmctl(ctx->shm_info.shmid, IPC_RMID, NULL);
    }

    if (ctx->img)
        XDestroyImage(ctx->img);

    if (ctx->dpy)
        XCloseDisplay(ctx->dpy);

    free(ctx);
}
