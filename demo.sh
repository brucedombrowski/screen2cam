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
    command -v v4l2-ctl       >/dev/null || missing+=("v4l-utils")

    # Kernel header check — detect mismatch on rolling distros (Kali, Arch, Fedora)
    local running_kernel headers_pkg
    running_kernel="$(uname -r)"
    headers_pkg="linux-headers-${running_kernel}"
    if ! dpkg -s "$headers_pkg" >/dev/null 2>&1; then
        # Check if ANY headers are available vs none at all
        local available_headers
        available_headers="$(apt-cache search "^linux-headers-" 2>/dev/null | head -5)" || true
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
            warn "  1. sudo apt-get install linux-headers-\$(uname -r)  # if available"
            warn "  2. sudo apt-get upgrade && sudo reboot              # sync to latest kernel"
            warn "  3. Continue anyway (v4l2loopback may fail to build)"
            warn ""
            read -r -p "Continue without matching headers? [y/N] " answer
            if [[ ! "$answer" =~ ^[Yy] ]]; then
                die "Aborting. Fix kernel headers and re-run."
            fi
        else
            missing+=("$headers_pkg")
        fi
    fi

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
    for _i in $(seq 1 10); do
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

# --- Environment check (no install, no sudo) ---
check_env() {
    echo ""
    echo "========================================="
    echo "  screen2cam - environment check"
    echo "========================================="
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

    if lsmod | grep -q v4l2loopback; then
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
        info "Environment OK — ready to run."
    else
        warn "Issues detected — see warnings above."
    fi
}

# --- Main ---
main() {
    case "${1:-}" in
        --check)
            check_env
            exit 0
            ;;
    esac

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
