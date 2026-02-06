# screen2cam

Stream your screen as a virtual camera for video calls (Teams, Zoom, etc.).

Both participants can show their desktops simultaneously as "webcam" feeds — no screen share needed.

## Quick Start

```bash
./demo.sh
```

## Live Demo Target

Run this one-liner on the target machine to stream its screen as a virtual camera:

```bash
git clone https://github.com/brucedombrowski/screen2cam.git /tmp/screen2cam && /tmp/screen2cam/demo.sh
```

This will install dependencies, load the virtual camera kernel module, build, and start streaming.

Then in your video app, select **"screen2cam"** as the camera.

## Requirements

- Linux with X11
- `v4l2loopback-dkms`, `gcc`, `libx11-dev`, `libxext-dev` (auto-installed by demo script)
- Kernel headers for your running kernel

## Usage

```bash
./demo.sh                           # live demo — full auto setup + run
./screen2cam --help                  # manual usage
./screen2cam --device /dev/video10 --fps 15
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `-d, --device` | `/dev/video10` | v4l2loopback device path |
| `-f, --fps` | `15` | Target frame rate (1-60) |

## Architecture

```
src/
├── main.c       # entry point, frame loop, arg parsing
├── capture.c    # X11 screen grab (MIT-SHM accelerated)
├── vcam.c       # V4L2 loopback output
└── convert.c    # BGRA → YUV420P pixel conversion
```

## macOS Support

In progress — see [open issues](https://github.com/brucedombrowski/screen2cam/issues).

## License

MIT
