# screen2cam

Stream your screen as a virtual camera for video calls (Teams, Zoom, etc.).

Both participants can show their desktops simultaneously as "webcam" feeds — no screen share needed.

## Quick Start

**Linux** — one-shot deploy (installs deps, loads kernel module, builds, runs):

```bash
./deploy_linux.sh
```

**macOS** — interactive demo (builds, probes resolution, launches bridge):

```bash
./demo_mac.sh
```

## Live Demo Target

Run this one-liner on the target machine to stream its screen as a virtual camera:

```bash
git clone https://github.com/brucedombrowski/screen2cam.git /tmp/screen2cam && /tmp/screen2cam/deploy_linux.sh
```

Then in your video app, select **"screen2cam"** as the camera.

## Requirements

**Linux** (Ubuntu 20.04+):
- X11 display server
- `v4l2loopback-dkms`, `gcc`, `libx11-dev`, `libxext-dev` (auto-installed by deploy script)
- Kernel headers for your running kernel

**macOS** (12.3+ Monterey):
- Xcode Command Line Tools
- Python 3 with `pyvirtualcam` and `numpy`
- OBS (provides the virtual camera backend)
- Screen Recording permission (System Settings > Privacy & Security)

## Usage

```bash
# Linux
./deploy_linux.sh                        # full auto — setup + build + run
./deploy_linux.sh --setup                # just install deps + load module
./deploy_linux.sh --run                  # just build + run (deps already done)
./screen2cam --device /dev/video10 --fps 15

# macOS
./demo_mac.sh                            # interactive — build + run
./screen2cam --fps 15 | python3 bridge.py 3024 1964 15
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `-d, --device` | `/dev/video10` (Linux) or `-` (macOS) | Output device or path |
| `-f, --fps` | `15` | Target frame rate (1-60) |

## Architecture

```
src/
├── main.c          # entry point, frame loop, arg parsing
├── capture.c       # Linux: X11 screen grab (MIT-SHM accelerated)
├── capture_mac.m   # macOS: ScreenCaptureKit capture
├── vcam.c          # Linux: V4L2 loopback output
├── vcam_mac.m      # macOS: raw YUV420P stdout output
└── convert.c       # BGRA → YUV420P pixel conversion
bridge.py           # macOS: stdin → OBS Virtual Camera (pyvirtualcam)
```

## License

MIT — see [LICENSE](LICENSE).
