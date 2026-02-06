#!/usr/bin/env bash
#
# screen2cam live demo
# Builds the tool, loads the virtual camera kernel module, and starts streaming.
#
set -euo pipefail

DEVICE="/dev/video10"
FPS=15
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Colors ---
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
RST='\033[0m'

info()  { printf "${GRN}[+]${RST} %s\n" "$*"; }
warn()  { printf "${YEL}[!]${RST} %s\n" "$*"; }
die()   { printf "${RED}[-]${RST} %s\n" "$*"; exit 1; }

# --- Dependency check ---
check_deps() {
    info "Checking dependencies..."

    local missing=()

    # Build deps
    command -v gcc   >/dev/null || missing+=("gcc")
    dpkg -s libx11-dev    >/dev/null 2>&1 || missing+=("libx11-dev")
    dpkg -s libxext-dev   >/dev/null 2>&1 || missing+=("libxext-dev")

    # Runtime deps (kernel headers needed for DKMS to build v4l2loopback)
    dpkg -s v4l2loopback-dkms >/dev/null 2>&1 || missing+=("v4l2loopback-dkms")
    dpkg -s "linux-headers-$(uname -r)" >/dev/null 2>&1 || missing+=("linux-headers-$(uname -r)")
    command -v v4l2-ctl       >/dev/null || missing+=("v4l-utils")

    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing packages: ${missing[*]}"
        info "Installing..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing[@]}"
    fi

    info "All dependencies satisfied."
}

# --- Load v4l2loopback ---
load_module() {
    if [ -e "$DEVICE" ]; then
        info "Virtual camera device $DEVICE already exists."
        return
    fi

    info "Loading v4l2loopback kernel module..."
    sudo modprobe v4l2loopback \
        devices=1 \
        video_nr=10 \
        card_label="screen2cam" \
        exclusive_caps=1

    # Wait for device to appear
    for i in $(seq 1 10); do
        [ -e "$DEVICE" ] && break
        sleep 0.5
    done

    [ -e "$DEVICE" ] || die "Device $DEVICE did not appear after loading module."
    info "Virtual camera ready at $DEVICE"
}

# --- Build ---
build() {
    info "Building screen2cam..."
    cd "$SCRIPT_DIR"
    make clean
    make
    info "Build complete."
}

# --- Run ---
run() {
    info "Starting screen capture -> virtual camera"
    info "Device: $DEVICE | FPS: $FPS"
    info "Open your video app and select 'screen2cam' as the camera."
    info "Press Ctrl+C to stop."
    echo ""

    "$SCRIPT_DIR/screen2cam" --device "$DEVICE" --fps "$FPS"
}

# --- Cleanup on exit ---
cleanup() {
    echo ""
    info "Cleaning up..."
    if lsmod | grep -q v4l2loopback; then
        warn "v4l2loopback module still loaded. Remove with: sudo modprobe -r v4l2loopback"
    fi
    info "Done."
}
trap cleanup EXIT

# --- Main ---
main() {
    echo ""
    echo "========================================="
    echo "  screen2cam - live demo"
    echo "========================================="
    echo ""

    check_deps
    load_module
    build
    run
}

main "$@"
