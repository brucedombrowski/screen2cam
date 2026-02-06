#!/usr/bin/env python3
"""
screen2cam virtual camera bridge (macOS)

Reads raw YUV420P frames from stdin and sends them to a virtual camera
via pyvirtualcam (OBS Virtual Camera backend).

Usage:
    ./screen2cam | python3 bridge.py WIDTH HEIGHT [FPS]

Example:
    ./screen2cam --fps 15 | python3 bridge.py 3024 1964 15
"""

import sys
import signal
import numpy as np
import pyvirtualcam

def yuv420p_to_rgba(data, w, h):
    """Convert a raw YUV420P frame to RGBA using BT.601 (matches convert.c)."""
    y_size = w * h
    uv_size = (w // 2) * (h // 2)

    y = np.frombuffer(data[:y_size], np.uint8).reshape(h, w).astype(np.int16)
    u = np.frombuffer(data[y_size:y_size + uv_size], np.uint8).reshape(h // 2, w // 2).astype(np.int16)
    v = np.frombuffer(data[y_size + uv_size:y_size + 2 * uv_size], np.uint8).reshape(h // 2, w // 2).astype(np.int16)

    # Upsample chroma (nearest-neighbor)
    u = np.repeat(np.repeat(u, 2, axis=0), 2, axis=1)
    v = np.repeat(np.repeat(v, 2, axis=0), 2, axis=1)

    # BT.601 inverse
    c = y - 16
    d = u - 128
    e = v - 128

    r = np.clip((298 * c + 409 * e + 128) >> 8, 0, 255).astype(np.uint8)
    g = np.clip((298 * c - 100 * d - 208 * e + 128) >> 8, 0, 255).astype(np.uint8)
    b = np.clip((298 * c + 516 * d + 128) >> 8, 0, 255).astype(np.uint8)

    rgb = np.stack([r, g, b], axis=2)
    return rgb

def main():
    if len(sys.argv) < 3:
        print("Usage: ./screen2cam | python3 bridge.py WIDTH HEIGHT [FPS]", file=sys.stderr)
        sys.exit(1)

    w = int(sys.argv[1])
    h = int(sys.argv[2])
    fps = int(sys.argv[3]) if len(sys.argv) > 3 else 15
    frame_size = w * h * 3 // 2

    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    print(f"bridge: waiting for {w}x{h} YUV420P frames ({frame_size} bytes each) @ {fps} fps", file=sys.stderr)

    cam = pyvirtualcam.Camera(width=w, height=h, fps=fps, print_fps=True)
    print(f"bridge: virtual camera -> {cam.device}", file=sys.stderr)

    frames = 0
    while True:
        data = sys.stdin.buffer.read(frame_size)
        if len(data) < frame_size:
            break

        rgba = yuv420p_to_rgba(data, w, h)
        cam.send(rgba)
        cam.sleep_until_next_frame()

        frames += 1
        if frames % fps == 0:
            print(f"\rbridge: {frames} frames delivered", end="", file=sys.stderr)

    print(f"\nbridge: done ({frames} frames total)", file=sys.stderr)
    cam.close()

if __name__ == "__main__":
    main()
