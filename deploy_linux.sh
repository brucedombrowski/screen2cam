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

# --- Install dependencies ---
install_deps() {
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

# --- Main ---
case "${1:-}" in
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
