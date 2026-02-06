/*
 * screen2cam Shared Memory Protocol
 *
 * IPC between the host process (screen2cam) and the Camera Extension.
 * Host writes BGRA frames; extension reads and serves them to apps.
 *
 * Layout:
 *   [shm_header_t][frame data (width * height * 4 bytes)]
 *
 * Synchronization: atomic frame_seq counter. Extension polls and
 * compares against its last-seen sequence number.
 */

#ifndef SHM_PROTOCOL_H
#define SHM_PROTOCOL_H

#include <stdint.h>
#include <stdatomic.h>

#define SHM_NAME         "/screen2cam"
#define SHM_MAX_WIDTH    7680   /* 8K */
#define SHM_MAX_HEIGHT   4320

typedef struct {
    uint32_t             magic;       /* 'S2CM' = 0x5332434D */
    uint32_t             version;     /* protocol version (1) */
    int32_t              width;
    int32_t              height;
    int32_t              fps;
    uint32_t             stride;      /* bytes per row (width * 4 for BGRA) */
    _Atomic uint64_t     frame_seq;   /* incremented each frame write */
    uint32_t             pixel_fmt;   /* kCVPixelFormatType_32BGRA = 'BGRA' */
    uint32_t             _reserved[5];
} shm_header_t;

#define SHM_MAGIC   0x5332434D
#define SHM_VERSION 1

/* Total shared memory size for given dimensions */
static inline size_t shm_total_size(int width, int height)
{
    return sizeof(shm_header_t) + (size_t)width * height * 4;
}

/* Pointer to frame data region */
static inline uint8_t *shm_frame_ptr(shm_header_t *hdr)
{
    return (uint8_t *)hdr + sizeof(shm_header_t);
}

static inline const uint8_t *shm_frame_ptr_const(const shm_header_t *hdr)
{
    return (const uint8_t *)hdr + sizeof(shm_header_t);
}

#endif /* SHM_PROTOCOL_H */
