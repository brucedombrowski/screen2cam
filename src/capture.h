#ifndef CAPTURE_H
#define CAPTURE_H

#include <stdint.h>

typedef struct capture_ctx capture_ctx_t;

/* Initialize screen capture. Returns NULL on failure. */
capture_ctx_t *capture_init(void);

/* Get capture dimensions. */
int capture_width(const capture_ctx_t *ctx);
int capture_height(const capture_ctx_t *ctx);

/*
 * Grab a frame. Returns pointer to BGRA pixel data (4 bytes/pixel).
 * The pointer is valid until the next call to capture_grab() or capture_free().
 */
const uint8_t *capture_grab(capture_ctx_t *ctx);

/* Release resources. */
void capture_free(capture_ctx_t *ctx);

#endif /* CAPTURE_H */
