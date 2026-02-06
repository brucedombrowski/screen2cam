#ifndef VCAM_H
#define VCAM_H

#include <stddef.h>
#include <stdint.h>

typedef struct vcam_ctx vcam_ctx_t;

/*
 * Open a v4l2loopback device and configure it for YUV420 output.
 * device: path like "/dev/video10"
 * Returns NULL on failure.
 */
vcam_ctx_t *vcam_open(const char *device, int width, int height);

/*
 * Write a YUV420P frame to the virtual camera.
 * data must be (width * height * 3 / 2) bytes.
 * Returns 0 on success, -1 on failure.
 */
int vcam_write(vcam_ctx_t *ctx, const uint8_t *yuv420p, size_t len);

/* Close the device and free resources. */
void vcam_close(vcam_ctx_t *ctx);

#endif /* VCAM_H */
