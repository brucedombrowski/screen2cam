#!/usr/bin/env bash
#
# screen2cam macOS live demo
#
# Builds the tool, starts capture, and pipes to a virtual camera or preview.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/config.ini"

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

# --- Load config ---
load_config() {
    if [ -f "$CONFIG" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG"
        info "Loaded config from config.ini"
    else
        warn "No config.ini found — copy config.example.ini and fill in your values"
    fi
}

# --- Dependency check ---
check_deps() {
    info "Checking dependencies..."
    local ok=true

    command -v clang >/dev/null || { warn "Missing: Xcode Command Line Tools (xcode-select --install)"; ok=false; }
    command -v python3 >/dev/null || { warn "Missing: python3"; ok=false; }
    command -v ffplay >/dev/null || { warn "Missing: ffplay (brew install ffmpeg)"; ok=false; }

    python3 -c "import pyvirtualcam" 2>/dev/null || {
        warn "Missing: pyvirtualcam (pip3 install pyvirtualcam)"
        ok=false
    }

    $ok || die "Install missing dependencies and re-run."
    info "All dependencies satisfied."
}

# --- Build ---
build() {
    info "Building screen2cam..."
    cd "$SCRIPT_DIR"
    make clean
    make
    info "Build complete."
}

# --- Probe display resolution ---
probe_resolution() {
    # Run screen2cam briefly to get resolution from stderr
    local log
    log=$(mktemp)

    "$SCRIPT_DIR/screen2cam" --fps 1 > /dev/null 2>"$log" &
    local pid=$!
    sleep 2
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true

    # Parse: "capture_mac: WxH (ScreenCaptureKit)"
    local res
    res=$(grep -oE '[0-9]+x[0-9]+' "$log" | head -1)
    rm -f "$log"

    if [ -z "$res" ]; then
        die "Could not detect display resolution. Check Screen Recording permission."
    fi

    WIDTH="${res%x*}"
    HEIGHT="${res#*x}"
    info "Display resolution: ${WIDTH}x${HEIGHT}"
}

# --- Open Teams meeting (optional) ---
open_teams() {
    if [ -n "${TEAMS_MEETING_ID:-}" ]; then
        step "Teams Meeting ID: $TEAMS_MEETING_ID"
        step "Teams Password:   ${TEAMS_MEETING_PASSWORD:-}"
        step "Display Name:     ${TEAMS_DISPLAY_NAME:-}"
        echo ""
        info "Opening Microsoft Teams..."
        open -a "Microsoft Teams" 2>/dev/null || open "https://teams.microsoft.com" 2>/dev/null || true
        echo ""
        warn "Join the meeting manually with the ID and password above."
        warn "Select 'OBS Virtual Camera' as your camera in Teams."
        echo ""
        read -rp "Press Enter when ready to start streaming..."
    fi
}

# --- Run: virtual camera mode ---
run_vcam() {
    local fps="${FPS:-15}"
    info "Starting: screen capture -> OBS Virtual Camera"
    info "Resolution: ${WIDTH}x${HEIGHT} @ ${fps} fps"
    info "Press Ctrl+C to stop."
    echo ""

    "$SCRIPT_DIR/screen2cam" --fps "$fps" 2>/dev/null \
        | python3 "$SCRIPT_DIR/bridge.py" "$WIDTH" "$HEIGHT" "$fps"
}

# --- Run: preview mode (ffplay) ---
run_preview() {
    local fps="${FPS:-15}"
    info "Starting: screen capture -> ffplay preview window"
    info "Resolution: ${WIDTH}x${HEIGHT} @ ${fps} fps"
    info "Press Ctrl+C to stop."
    echo ""

    "$SCRIPT_DIR/screen2cam" --fps "$fps" 2>/dev/null \
        | ffplay -f rawvideo -pixel_format yuv420p \
                 -video_size "${WIDTH}x${HEIGHT}" \
                 -framerate "$fps" \
                 -window_title "screen2cam preview" \
                 -loglevel quiet \
                 -
}

# --- Cleanup ---
cleanup() {
    echo ""
    info "Done."
}
trap cleanup EXIT

# --- Main ---
main() {
    echo ""
    echo "========================================="
    echo "  screen2cam - macOS live demo"
    echo "========================================="
    echo ""

    load_config
    check_deps
    build
    probe_resolution

    echo ""
    step "Choose output mode:"
    echo "  1) Virtual Camera  (OBS Virtual Camera -> Teams)"
    echo "  2) Preview Window  (ffplay — for testing)"
    echo ""
    read -rp "Select [1/2]: " mode

    case "$mode" in
        2) run_preview ;;
        *) open_teams; run_vcam ;;
    esac
}

main "$@"
