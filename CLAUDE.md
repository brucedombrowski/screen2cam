# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) and AI agents working with code in this repository.

## Project Overview

screen2cam streams your screen as a virtual camera for video calls (Teams, Zoom, etc.). Both participants can show their desktops simultaneously as "webcam" feeds — no screen share needed. Pure C implementation with platform-specific backends for Linux (X11/V4L2), macOS (ScreenCaptureKit/OBS), and Windows (DXGI Desktop Duplication).

## Commands

```bash
# Build (auto-detects platform)
make
make clean

# Linux — one-shot deploy (installs deps, loads kernel module, builds, runs)
./deploy_linux.sh
./deploy_linux.sh --setup     # just install deps + load module
./deploy_linux.sh --run       # just build + run

# macOS — interactive demo
./demo_mac.sh

# Run directly
./screen2cam --device /dev/video10 --fps 15              # Linux
./screen2cam --fps 15 | python3 bridge.py 3024 1964 15   # macOS
```

## Repository Structure

```
screen2cam/
├── CLAUDE.md               # This file (AI agent instructions)
├── README.md               # Usage documentation
├── LICENSE                  # MIT License
├── Makefile                 # Cross-platform build (Linux/macOS/Windows)
├── config.example.ini      # Config template (Teams credentials, FPS)
├── config.ini              # User config (gitignored)
├── bridge.py               # macOS: stdin YUV420P → OBS Virtual Camera
├── deploy_linux.sh         # Linux: one-shot setup + build + run
├── demo.sh                 # Linux: quick demo
├── demo_mac.sh             # macOS: interactive demo
├── demo_win.ps1            # Windows: PowerShell demo
├── .claude/commands/       # Claude Code skills (assign-role, etc.)
├── .github/workflows/
│   ├── ci.yml              # Build + ShellCheck on all 3 platforms
│   └── release.yml         # Automated releases
└── src/
    ├── main.c              # Entry point, frame loop, arg parsing
    ├── capture.c / .h      # Linux: X11 screen grab (MIT-SHM)
    ├── capture_mac.m        # macOS: ScreenCaptureKit capture
    ├── capture_win.c        # Windows: DXGI Desktop Duplication
    ├── vcam.c / .h          # Linux: V4L2 loopback output
    ├── vcam_mac.m           # macOS: raw YUV420P stdout output
    ├── vcam_win.c           # Windows: raw stdout output
    ├── convert.c / .h       # BGRA → YUV420P pixel conversion
    ├── platform.h           # Platform detection macros
    └── getopt_win.h         # POSIX getopt shim for Windows
```

## Architecture

Each platform follows the same pattern: **capture → convert → output**.

| Platform | Capture | Output | Virtual Camera |
|----------|---------|--------|----------------|
| Linux | X11 + MIT-SHM (`capture.c`) | V4L2 loopback (`vcam.c`) | v4l2loopback kernel module |
| macOS | ScreenCaptureKit (`capture_mac.m`) | stdout YUV420P (`vcam_mac.m`) | OBS via `bridge.py` + pyvirtualcam |
| Windows | DXGI Desktop Duplication (`capture_win.c`) | stdout (`vcam_win.c`) | TBD (Phase 2: DirectShow/MF) |

## CI/CD

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `ci.yml` | Push to master, PRs | Build on Linux + macOS + Windows, ShellCheck |
| `release.yml` | Version tags | Automated releases |

## Agent Identification

When multiple agents are active, **sign off each response with your role** so the user can identify which agent they're talking to:

```
— Windows Developer
```

Standard roles for this project:
- **Lead Software Developer / GOAT SWE** (LSD) — Code review, architecture decisions, technical leadership
- **Lead Systems Engineer** (LSE) — Core implementation, architecture
- **Documentation Engineer** — Docs, README, guides
- **Windows Developer** — Windows support, PowerShell scripts, DirectShow/MF
- **QA Engineer** — Testing, validation, CI/CD

### Multi-Agent Context Awareness

When the user mentions another agent's activity, this is **informational context**, not a request for you to take action:

| User Says | Meaning | Your Action |
|-----------|---------|-------------|
| "The LSE is working on the V4L2 fix" | Context: another agent is on it | Acknowledge; do NOT start the same work |
| "QA is running CI" | Context: another agent is testing | Wait for results or ask how you can help |
| "Fix the kernel header detection" | Direct request to you | Do the work |

**Rule:** Only invoke skills/commands when the user directly requests YOU to perform them. Statements about what other agents are doing are situational awareness, not task delegation.

### Issue Coordination (Avoiding Duplicate Work)

**Before starting work on a GitHub issue:**

1. **Check if claimed:**
   ```bash
   gh issue view <NUMBER> --json assignees,comments
   ```

2. **Claim the issue:**
   ```bash
   gh issue comment <NUMBER> --body "🤖 [Role] claiming this issue"
   gh issue edit <NUMBER> --add-assignee @me
   ```

3. **When complete:**
   ```bash
   gh issue close <NUMBER> --comment "Completed in PR #<PR_NUMBER>"
   ```

## Key Considerations

- **config.ini** contains meeting credentials — never commit it (gitignored)
- **Kernel headers** must match the running kernel for v4l2loopback (rolling distro issue — see #5)
- **Screen Recording permission** required on macOS (System Settings > Privacy & Security)
- macOS virtual camera currently depends on OBS; native Camera Extension is planned (#2)
- Windows Phase 2 (tray icon + embedded virtual camera) tracked in #6
