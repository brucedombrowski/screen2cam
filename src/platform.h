/*
 * Windows Portability Shims
 *
 * Provides POSIX-like functions missing on Windows (MSVC/MinGW):
 *   - clock_gettime(CLOCK_MONOTONIC) via QueryPerformanceCounter
 *   - nanosleep() via Sleep()
 *   - usleep() via Sleep()
 *   - struct timespec definition
 *
 * Header-only. No-op on non-Windows platforms.
 */

#ifndef PLATFORM_H
#define PLATFORM_H

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <stdint.h>

/* --- struct timespec (may already be defined by some MinGW versions) --- */

#ifndef _TIMESPEC_DEFINED
#define _TIMESPEC_DEFINED
struct timespec {
    long tv_sec;
    long tv_nsec;
};
#endif

/* --- clock_gettime(CLOCK_MONOTONIC) --- */

#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif

static inline int clock_gettime(int clk_id, struct timespec *ts)
{
    (void)clk_id;
    LARGE_INTEGER freq, count;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&count);
    ts->tv_sec  = (long)(count.QuadPart / freq.QuadPart);
    ts->tv_nsec = (long)((count.QuadPart % freq.QuadPart) * 1000000000LL / freq.QuadPart);
    return 0;
}

/* --- nanosleep() --- */

static inline int nanosleep(const struct timespec *req, struct timespec *rem)
{
    (void)rem;
    DWORD ms = (DWORD)(req->tv_sec * 1000 + req->tv_nsec / 1000000);
    if (ms == 0 && req->tv_nsec > 0)
        ms = 1;
    Sleep(ms);
    return 0;
}

/* --- usleep() --- */

static inline int usleep(unsigned int usec)
{
    DWORD ms = usec / 1000;
    if (ms == 0 && usec > 0)
        ms = 1;
    Sleep(ms);
    return 0;
}

#endif /* _WIN32 */
#endif /* PLATFORM_H */
