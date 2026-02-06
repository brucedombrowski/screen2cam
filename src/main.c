#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <getopt.h>

#include "capture.h"
#include "convert.h"
#include "vcam.h"

static volatile sig_atomic_t running = 1;

static void on_signal(int sig)
{
    (void)sig;
    running = 0;
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [OPTIONS]\n"
        "\n"
        "Stream your screen as a virtual camera for video calls.\n"
        "\n"
        "Options:\n"
#ifdef __APPLE__
        "  -d, --device PATH   output path or '-' for stdout  [-]\n"
#else
        "  -d, --device PATH   v4l2loopback device  [/dev/video10]\n"
#endif
        "  -f, --fps N         target frame rate     [15]\n"
        "  -h, --help          show this help\n",
        prog);
}

int main(int argc, char *argv[])
{
#ifdef __APPLE__
    const char *device = "-";
#else
    const char *device = "/dev/video10";
#endif
    int fps = 15;

    static struct option long_opts[] = {
        { "device", required_argument, NULL, 'd' },
        { "fps",    required_argument, NULL, 'f' },
        { "help",   no_argument,       NULL, 'h' },
        { NULL, 0, NULL, 0 }
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:f:h", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'd': device = optarg; break;
        case 'f': fps = atoi(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 1;
        }
    }

    if (fps < 1 || fps > 60) {
        fprintf(stderr, "error: fps must be 1-60\n");
        return 1;
    }

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    /* Initialize screen capture */
    capture_ctx_t *cap = capture_init();
    if (!cap)
        return 1;

    int w = capture_width(cap);
    int h = capture_height(cap);

    /* Open virtual camera */
    vcam_ctx_t *cam = vcam_open(device, w, h);
    if (!cam) {
        capture_free(cap);
        return 1;
    }

    /* Allocate YUV buffer */
    size_t yuv_size = (size_t)w * h * 3 / 2;
    uint8_t *yuv_buf = malloc(yuv_size);
    if (!yuv_buf) {
        perror("malloc");
        vcam_close(cam);
        capture_free(cap);
        return 1;
    }

    long frame_ns = 1000000000L / fps;
    unsigned long frames = 0;

    fprintf(stderr, "screen2cam: streaming %dx%d @ %d fps -> %s\n", w, h, fps, device);
    fprintf(stderr, "screen2cam: press Ctrl+C to stop\n");

    while (running) {
        struct timespec t0;
        clock_gettime(CLOCK_MONOTONIC, &t0);

        /* Grab screen */
        const uint8_t *bgra = capture_grab(cap);
        if (!bgra) {
            fprintf(stderr, "screen2cam: capture failed, retrying...\n");
            usleep(100000);
            continue;
        }

        /* Convert BGRA -> YUV420P */
        bgra_to_yuv420p(bgra, yuv_buf, w, h);

        /* Write to virtual camera */
        if (vcam_write(cam, yuv_buf, yuv_size) < 0)
            break;

        frames++;
        if (frames % (unsigned long)fps == 0)
            fprintf(stderr, "\rscreen2cam: %lu frames sent", frames);

        /* Sleep to maintain target fps */
        struct timespec t1;
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long elapsed = (t1.tv_sec - t0.tv_sec) * 1000000000L + (t1.tv_nsec - t0.tv_nsec);
        long remaining = frame_ns - elapsed;
        if (remaining > 0) {
            struct timespec ts = { .tv_sec = 0, .tv_nsec = remaining };
            nanosleep(&ts, NULL);
        }
    }

    fprintf(stderr, "\nscreen2cam: stopping (%lu frames total)\n", frames);

    free(yuv_buf);
    vcam_close(cam);
    capture_free(cap);
    return 0;
}
