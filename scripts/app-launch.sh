#!/bin/bash
set -euo pipefail
ZMD_SUPPORT="$(cd "$(dirname "$0")/../SharedSupport" && pwd)"
export ZMD_PREFIX="$ZMD_SUPPORT/prefix"
mkdir -p "$ZMD_SUPPORT/logs"
ZMD_LOG="$ZMD_SUPPORT/logs/launcher-$(date +%Y%m%d-%H%M%S).log"
cd "$ZMD_SUPPORT"
if [ "${1:-}" = "--attach" ]; then
    # Used once when upgrading the wrapper around an already-running game.
    WINEPREFIX="$ZMD_PREFIX" "$ZMD_SUPPORT/runtime/wine/bin/wineserver" -w >> "$ZMD_LOG" 2>&1
    exit 0
fi
ZMD_SELECTED=dxmt
if [ -f renderer.conf ]; then IFS= read -r ZMD_SELECTED < renderer.conf; fi
case "$ZMD_SELECTED" in
    dxmt|dxmt-metalfx) ZMD_FLAGS="-force-d3d11" ;;
    vulkan) ZMD_FLAGS="-force-vulkan" ;;
    *) echo "Unknown renderer selection: $ZMD_SELECTED" >> "$ZMD_LOG"; exit 2 ;;
esac
export ZMD_RENDERER="$ZMD_SELECTED"
ZMD_WINDOW=game
if [ -f window-mode.conf ]; then IFS= read -r ZMD_WINDOW < window-mode.conf; fi
case "$ZMD_WINDOW" in
    game) ;;
    windowed) ZMD_FLAGS="$ZMD_FLAGS -screen-fullscreen 0" ;;
    fullscreen) ZMD_FLAGS="$ZMD_FLAGS -screen-fullscreen 1 -window-mode borderless" ;;
    *) echo "Unknown window mode: $ZMD_WINDOW" >> "$ZMD_LOG"; exit 2 ;;
esac
ZMD_RESOLUTION=game
if [ -f resolution.conf ]; then IFS= read -r ZMD_RESOLUTION < resolution.conf; fi
if [ "$ZMD_RESOLUTION" != game ]; then
    if [[ ! "$ZMD_RESOLUTION" =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]]; then
        echo "Invalid resolution: $ZMD_RESOLUTION" >> "$ZMD_LOG"; exit 2
    fi
    ZMD_WIDTH="${ZMD_RESOLUTION%x*}"
    ZMD_HEIGHT="${ZMD_RESOLUTION#*x}"
    if (( ZMD_WIDTH < 320 || ZMD_WIDTH > 16384 || ZMD_HEIGHT < 320 || ZMD_HEIGHT > 16384 )); then
        echo "Resolution out of range" >> "$ZMD_LOG"; exit 2
    fi
    ZMD_FLAGS="$ZMD_FLAGS -screen-width $ZMD_WIDTH -screen-height $ZMD_HEIGHT"
fi
printf 'Renderer: %s; game arguments: %s\n' "$ZMD_SELECTED" "$ZMD_FLAGS" >> "$ZMD_LOG"
bash "$ZMD_SUPPORT/scripts/prepare-metalfx.sh" "$ZMD_SELECTED" >> "$ZMD_LOG" 2>&1
bash "$ZMD_SUPPORT/scripts/wine.sh" reg add \
    'HKCU\Software\Wine\AppDefaults\Endfield.exe' \
    /v CommandLineAppend /t REG_SZ /d "$ZMD_FLAGS" /f >> "$ZMD_LOG" 2>&1
ZMD_LAUNCH_STATUS=0
bash "$ZMD_SUPPORT/scripts/wine.sh" 'C:\EndfieldLauncher\Launcher.exe' >> "$ZMD_LOG" 2>&1 || ZMD_LAUNCH_STATUS=$?
# Keep the native application alive until this prefix's windows have exited,
# even if an already-running official launcher rejects a second bootstrap.
WINEPREFIX="$ZMD_PREFIX" "$ZMD_SUPPORT/runtime/wine/bin/wineserver" -w >> "$ZMD_LOG" 2>&1
exit "$ZMD_LAUNCH_STATUS"
