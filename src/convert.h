#ifndef CONVERT_H
#define CONVERT_H

#include <stdint.h>

/*
 * Convert BGRA frame to YUV420P (I420).
 * src:  input  BGRA buffer (width * height * 4 bytes)
 * dst:  output YUV420P buffer (width * height * 3/2 bytes)
 * Caller must allocate dst.
 */
void bgra_to_yuv420p(const uint8_t *src, uint8_t *dst, int width, int height);

#endif /* CONVERT_H */
