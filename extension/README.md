# screen2cam Camera Extension (macOS)

Native macOS virtual camera using CMIOExtension (macOS 12.3+). Replaces the OBS + bridge.py workaround with a proper Camera Extension that apps like Teams, Zoom, and FaceTime discover automatically.

## Architecture

```
screen2cam (host)                    Camera Extension
┌──────────────┐    POSIX shm    ┌──────────────────┐
│ capture_mac  │───────────────>│ Screen2CamProvider│───> Teams/Zoom/FaceTime
│ (BGRA frames)│  /screen2cam   │ (CMIOExtension)   │
└──────────────┘                └──────────────────┘
```

The host process captures the screen and writes BGRA frames to shared memory (`/dev/shm/screen2cam`). The Camera Extension polls shared memory and serves frames to any app requesting the "screen2cam" camera.

## Files

| File | Purpose |
|------|---------|
| `shm_protocol.h` | Shared memory layout and helpers (used by both sides) |
| `Screen2CamProvider.m` | Camera Extension: provider, device, stream sources |
| `vcam_mac_shm.m` | Updated vcam_mac.m with shared memory output mode |
| `Info.plist` | Extension bundle metadata |
| `Screen2CamExtension.entitlements` | Sandbox + app group entitlements |

## Usage

Once built and installed:

```bash
# Start streaming to the Camera Extension (no OBS needed)
./screen2cam --device shm --fps 15

# Pipe mode still works for backward compatibility
./screen2cam --fps 15 | python3 bridge.py 3024 1964 15
```

## Build Instructions

The Camera Extension must be built with Xcode, code-signed, and bundled inside a host `.app`. This cannot be done with a plain Makefile.

### Prerequisites

- macOS 12.3+ (Monterey)
- Xcode 14+
- Apple Developer account (for code signing)

### Steps

1. **Replace `src/vcam_mac.m`** with the updated version:
   ```bash
   cp extension/vcam_mac_shm.m src/vcam_mac.m
   ```

2. **Create an Xcode project** for the Camera Extension:
   - File > New > Target > Camera Extension
   - Bundle ID: `com.screen2cam.extension`
   - Replace generated source with `Screen2CamProvider.m`
   - Add `shm_protocol.h` to the target
   - Set entitlements from `Screen2CamExtension.entitlements`

3. **Embed the extension** in a host app:
   - The extension `.appex` must live inside `screen2cam.app/Contents/Library/SystemExtensions/`
   - The host app activates the extension via `OSSystemExtensionManager`

4. **Code sign** both the host app and extension with your Developer ID

### Development (unsigned)

For local testing without code signing:

1. Disable SIP: boot to Recovery > `csrutil disable`
2. Enable developer mode: `systemextensionsctl developer on`
3. Build and run from Xcode

## Known Limitations

- **Double conversion**: Currently the pipeline does BGRA→YUV420P→BGRA when in extension mode because `main.c` always calls `bgra_to_yuv420p()`. A future optimization should pass BGRA directly to `vcam_write()` when `--device shm` is used.
- **Fixed dimensions**: The extension reads dimensions from shared memory at startup. If the host restarts with a different resolution, the extension must be restarted too.
- **macOS 15+**: DAL plugins are fully deprecated. Camera Extensions are the only supported path.
