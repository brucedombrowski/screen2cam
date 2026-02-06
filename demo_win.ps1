#
# screen2cam Windows live demo
#
# Builds the tool, starts capture, and pipes to a virtual camera or preview.
#
# Usage: .\demo_win.ps1
#

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Colors ---
function Info  { param($msg) Write-Host "[+] $msg" -ForegroundColor Green }
function Warn  { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Step  { param($msg) Write-Host "[>] $msg" -ForegroundColor Cyan }
function Die   { param($msg) Write-Host "[-] $msg" -ForegroundColor Red; exit 1 }

# --- Dependency check ---
function Check-Deps {
    Info "Checking dependencies..."
    $ok = $true

    # Build deps (gcc from MSYS2/MinGW)
    if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
        Warn "Missing: gcc (install MSYS2 and mingw-w64-x86_64-gcc)"
        $ok = $false
    }
    if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
        Warn "Missing: make (install MSYS2 and make package)"
        $ok = $false
    }

    # Preview deps
    if (-not (Get-Command ffplay -ErrorAction SilentlyContinue)) {
        Warn "Missing: ffplay (install ffmpeg and add to PATH)"
        $ok = $false
    }

    # Virtual camera deps
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Warn "Missing: python"
        $ok = $false
    } else {
        $pvc = python -c "import pyvirtualcam" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Warn "Missing: pyvirtualcam (pip install pyvirtualcam)"
            Warn "Note: OBS Studio must be installed for virtual camera backend"
            $ok = $false
        }
    }

    if (-not $ok) { Die "Install missing dependencies and re-run." }
    Info "All dependencies satisfied."
}

# --- Build ---
function Build {
    Info "Building screen2cam..."
    Push-Location $ScriptDir
    try {
        make clean 2>$null
        make
        if ($LASTEXITCODE -ne 0) { Die "Build failed." }
    } finally {
        Pop-Location
    }
    Info "Build complete."
}

# --- Probe display resolution ---
function Probe-Resolution {
    $exe = Join-Path $ScriptDir "screen2cam.exe"
    $logFile = [System.IO.Path]::GetTempFileName()

    # Run briefly to capture resolution from stderr
    $proc = Start-Process -FilePath $exe -ArgumentList "--fps","1" `
        -RedirectStandardError $logFile -RedirectStandardOutput "NUL" `
        -PassThru -NoNewWindow

    Start-Sleep -Seconds 2
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force 2>$null }
    Start-Sleep -Milliseconds 500

    $log = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue

    if ($log -match '(\d+)x(\d+)') {
        $script:Width  = $Matches[1]
        $script:Height = $Matches[2]
        Info "Display resolution: ${Width}x${Height}"
    } else {
        Die "Could not detect display resolution. Check that screen2cam.exe runs correctly."
    }
}

# --- Run: virtual camera mode ---
function Run-VCam {
    $fps = 15
    $exe = Join-Path $ScriptDir "screen2cam.exe"
    $bridge = Join-Path $ScriptDir "bridge.py"

    Info "Starting: screen capture -> OBS Virtual Camera"
    Info "Resolution: ${Width}x${Height} @ ${fps} fps"
    Info "Press Ctrl+C to stop."
    Write-Host ""

    # Pipe screen2cam output through bridge.py to OBS virtual camera
    & $exe --fps $fps 2>$null | python $bridge $Width $Height $fps
}

# --- Run: preview mode (ffplay) ---
function Run-Preview {
    $fps = 15
    $exe = Join-Path $ScriptDir "screen2cam.exe"

    Info "Starting: screen capture -> ffplay preview window"
    Info "Resolution: ${Width}x${Height} @ ${fps} fps"
    Info "Press Ctrl+C to stop."
    Write-Host ""

    & $exe --fps $fps 2>$null | ffplay -f rawvideo -pixel_format yuv420p `
        -video_size "${Width}x${Height}" `
        -framerate $fps `
        -window_title "screen2cam preview" `
        -loglevel quiet -
}

# --- Main ---
Write-Host ""
Write-Host "========================================="
Write-Host "  screen2cam - Windows live demo"
Write-Host "========================================="
Write-Host ""

Check-Deps
Build
Probe-Resolution

Write-Host ""
Step "Choose output mode:"
Write-Host "  1) Virtual Camera  (OBS Virtual Camera -> Teams)"
Write-Host "  2) Preview Window  (ffplay - for testing)"
Write-Host ""
$mode = Read-Host "Select [1/2]"

switch ($mode) {
    "2" { Run-Preview }
    default { Run-VCam }
}

Write-Host ""
Info "Done."
