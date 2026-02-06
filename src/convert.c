#include "convert.h"

/*
 * BGRA -> YUV420P (I420) conversion.
 *
 * Y  plane: width * height bytes
 * Cb plane: (width/2) * (height/2) bytes
 * Cr plane: (width/2) * (height/2) bytes
 *
 * Uses standard BT.601 coefficients.
 */
void bgra_to_yuv420p(const uint8_t *src, uint8_t *dst, int width, int height)
{
    int half_w = width  / 2;
    int half_h = height / 2;

    uint8_t *y_plane = dst;
    uint8_t *u_plane = dst + width * height;
    uint8_t *v_plane = u_plane + half_w * half_h;

    for (int j = 0; j < height; j++) {
        for (int i = 0; i < width; i++) {
            int idx = (j * width + i) * 4;
            uint8_t b = src[idx + 0];
            uint8_t g = src[idx + 1];
            uint8_t r = src[idx + 2];
            /* src[idx+3] is alpha, ignored */

            /* Y */
            int y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            y_plane[j * width + i] = (uint8_t)(y < 0 ? 0 : (y > 255 ? 255 : y));

            /* Subsample U and V: one value per 2x2 block */
            if ((j & 1) == 0 && (i & 1) == 0) {
                int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                int ci = (j / 2) * half_w + (i / 2);
                u_plane[ci] = (uint8_t)(u < 0 ? 0 : (u > 255 ? 255 : u));
                v_plane[ci] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
            }
        }
    }
}
