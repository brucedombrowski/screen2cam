#!/usr/bin/env bash
#
# screen2cam Linux deploy — one-shot setup, build, and run
#
# Usage:
#   ./deploy_linux.sh              # setup + build + run
#   ./deploy_linux.sh --setup      # just install deps + load module
#   ./deploy_linux.sh --run        # just build + run (deps already done)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${DEVICE:-/dev/video10}"
DEVICE_NUM="${DEVICE##*/video}"
FPS="${FPS:-15}"

# --- Colors ---
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
RST='\033[0m'

info()  { printf "${GRN}[+]${RST} %s\n" "$*"; }
warn()  { printf "${YEL}[!]${RST} %s\n" "$*"; }
die()   { printf "${RED}[-]${RST} %s\n" "$*"; exit 1; }
step()  { printf "${CYN}[>]${RST} %s\n" "$*"; }

# --- Check kernel/header mismatch (rolling distro issue — see #5) ---
check_kernel_headers() {
    local running_kernel headers_pkg
    running_kernel="$(uname -r)"
    headers_pkg="linux-headers-${running_kernel}"

    if dpkg -s "$headers_pkg" >/dev/null 2>&1; then
        info "Kernel headers match running kernel: ${running_kernel}"
        return 0
    fi

    # Headers not installed — check what's available
    local available_headers
    available_headers="$(apt-cache search "^linux-headers-[0-9]" 2>/dev/null | sort -V | tail -5)" || true

    if [ -n "$available_headers" ]; then
        warn "Kernel/header mismatch detected!"
        warn "  Running kernel:    ${running_kernel}"
        warn "  Expected package:  ${headers_pkg}"
        warn "  Available headers:"
        echo "$available_headers" | while read -r line; do
            warn "    $line"
        done
        warn ""
        warn "This is common on rolling-release distros (Kali, Arch, Fedora)"
        warn "where the kernel and header packages can desync."
        warn ""
        warn "Options:"
        warn "  1. sudo apt-get upgrade && sudo reboot  (sync to latest kernel)"
        warn "  2. Continue anyway (v4l2loopback DKMS build will likely fail)"
        warn ""
        read -r -p "Continue without matching headers? [y/N] " answer
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            die "Aborting. Fix kernel headers and re-run."
        fi
    fi
    # If no headers found at all, install_deps will attempt to install them
}

# --- Install dependencies ---
install_deps() {
    check_kernel_headers

    info "Installing build dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        build-essential \
        libx11-dev \
        libxext-dev \
        v4l2loopback-dkms \
        v4l2loopback-utils \
        v4l-utils
    info "Dependencies installed."
}

# --- Load v4l2loopback kernel module ---
load_module() {
    if lsmod | grep -q v4l2loopback; then
        info "v4l2loopback already loaded."
        # Check if our device exists
        if [ -e "$DEVICE" ]; then
            info "$DEVICE exists."
            return 0
        else
            warn "$DEVICE not found — reloading module with correct device number..."
            sudo modprobe -r v4l2loopback
        fi
    fi

    info "Loading v4l2loopback module (device=$DEVICE_NUM)..."
    sudo modprobe v4l2loopback \
        video_nr="$DEVICE_NUM" \
        card_label="screen2cam" \
        exclusive_caps=1

    # Wait for device to appear
    local tries=0
    while [ ! -e "$DEVICE" ] && [ "$tries" -lt 10 ]; do
        sleep 0.2
        tries=$((tries + 1))
    done

    if [ ! -e "$DEVICE" ]; then
        die "$DEVICE did not appear after loading module."
    fi

    info "v4l2loopback loaded: $DEVICE"
}

# --- Make module persistent across reboots ---
persist_module() {
    local conf="/etc/modules-load.d/screen2cam.conf"
    local opts="/etc/modprobe.d/screen2cam.conf"

    if [ ! -f "$conf" ]; then
        info "Making v4l2loopback load on boot..."
        echo "v4l2loopback" | sudo tee "$conf" > /dev/null
        echo "options v4l2loopback video_nr=$DEVICE_NUM card_label=screen2cam exclusive_caps=1" \
            | sudo tee "$opts" > /dev/null
        info "Module will auto-load on reboot."
    else
        info "Boot persistence already configured."
    fi
}

# --- Check display server ---
check_display() {
    if [ -z "${DISPLAY:-}" ]; then
        if [ -n "${WAYLAND_DISPLAY:-}" ]; then
            die "Wayland detected but no DISPLAY set. screen2cam requires X11.\n     Try: export DISPLAY=:0  (if XWayland is running)"
        fi
        die "No DISPLAY set. Run this on the desktop or: export DISPLAY=:0"
    fi

    # Quick sanity check — can we talk to X?
    if ! xdpyinfo >/dev/null 2>&1; then
        die "Cannot connect to X display '$DISPLAY'. Is X running?"
    fi

    info "X11 display: $DISPLAY"
}

# --- Build ---
build() {
    info "Building screen2cam..."
    cd "$SCRIPT_DIR"
    make clean 2>/dev/null || true
    make
    info "Build complete: $SCRIPT_DIR/screen2cam"
}

# --- Run ---
run() {
    info "Starting: screen2cam -> $DEVICE @ $FPS fps"
    info "Press Ctrl+C to stop."
    echo ""
    exec "$SCRIPT_DIR/screen2cam" --device "$DEVICE" --fps "$FPS"
}

# --- Verify everything ---
verify() {
    info "Verifying setup..."
    local ok=true

    [ -e "$DEVICE" ]                    || { warn "$DEVICE missing"; ok=false; }
    [ -x "$SCRIPT_DIR/screen2cam" ]     || { warn "screen2cam not built"; ok=false; }
    command -v xdpyinfo >/dev/null      || { warn "xdpyinfo not found (apt install x11-utils)"; ok=false; }

    if $ok; then
        info "All checks passed."
        # Show device info
        v4l2-ctl --device="$DEVICE" --info 2>/dev/null | head -5 || true
    else
        die "Fix the issues above and re-run."
    fi
}

# --- Cleanup hint ---
show_status() {
    echo ""
    step "Virtual camera: $DEVICE"
    step "In your video call app, select 'screen2cam' as the camera."
    echo ""
}

# --- Environment check (no install, no sudo) ---
check_env() {
    echo ""
    step "screen2cam — environment check"
    echo ""

    local ok=true
    local running_kernel headers_pkg
    running_kernel="$(uname -r)"
    headers_pkg="linux-headers-${running_kernel}"

    # Display server
    if [ -n "${DISPLAY:-}" ]; then
        info "Display: $DISPLAY (X11)"
    elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
        warn "Wayland detected — screen2cam requires X11"
        ok=false
    else
        warn "No DISPLAY set"
        ok=false
    fi

    # Kernel + headers
    info "Running kernel: ${running_kernel}"
    if dpkg -s "$headers_pkg" >/dev/null 2>&1; then
        info "Kernel headers: ${headers_pkg} (installed)"
    else
        warn "Kernel headers: ${headers_pkg} (NOT installed)"
        local latest
        latest="$(apt-cache search "^linux-headers-[0-9]" 2>/dev/null | sort -V | tail -1)" || true
        if [ -n "$latest" ]; then
            warn "  Latest available: $latest"
            if [ "$latest" != "$headers_pkg" ]; then
                warn "  MISMATCH — running kernel does not match available headers"
                warn "  Fix: sudo apt-get upgrade && sudo reboot"
            fi
        fi
        ok=false
    fi

    # Build tools
    if command -v gcc >/dev/null; then
        info "gcc: $(gcc --version | head -1)"
    else
        warn "gcc: NOT found"
        ok=false
    fi

    # Libraries
    for pkg in libx11-dev libxext-dev; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            info "$pkg: installed"
        else
            warn "$pkg: NOT installed"
            ok=false
        fi
    done

    # v4l2loopback
    if dpkg -s v4l2loopback-dkms >/dev/null 2>&1; then
        info "v4l2loopback-dkms: installed"
    else
        warn "v4l2loopback-dkms: NOT installed"
        ok=false
    fi

    if lsmod | grep -q v4l2loopback 2>/dev/null; then
        info "v4l2loopback module: loaded"
    else
        warn "v4l2loopback module: NOT loaded"
    fi

    if [ -e "$DEVICE" ]; then
        info "Virtual camera: $DEVICE (exists)"
    else
        warn "Virtual camera: $DEVICE (not present)"
    fi

    echo ""
    if $ok; then
        info "Environment OK — ready to deploy."
    else
        warn "Issues detected — see warnings above."
    fi
}

# --- Main ---
case "${1:-}" in
    --check)
        check_env
        ;;
    --setup)
        install_deps
        load_module
        persist_module
        check_display
        build
        verify
        show_status
        info "Setup complete. Run again without flags to start streaming."
        ;;
    --run)
        check_display
        build
        verify
        show_status
        run
        ;;
    *)
        install_deps
        load_module
        persist_module
        check_display
        build
        verify
        show_status
        run
        ;;
esac
