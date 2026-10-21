#!/bin/bash
# Configure the next launch only. Never terminate a running game.
set -euo pipefail
ZMD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "$ZMD_ROOT/dist/鹰角启动器.app/Contents/SharedSupport" ]; then
    ZMD_ROOT="$ZMD_ROOT/dist/鹰角启动器.app/Contents/SharedSupport"
elif [ -d "$ZMD_ROOT/dist/终末地.app/Contents/SharedSupport" ]; then
    ZMD_ROOT="$ZMD_ROOT/dist/终末地.app/Contents/SharedSupport"
fi
case "${1:-}" in
    dxmt) ;;
    dxmt-metalfx)
        [ -f "$ZMD_ROOT/runtime/renderers/dxmt-metalfx/provenance.json" ] &&
        [ -f "$ZMD_ROOT/runtime/renderers/dxmt-metalfx/x86_64-windows/nvngx.dll" ] ||
            { echo "Patched DXMT MetalFX is not installed." >&2; exit 2; }
        ;;
    vulkan)
        [ -f "$ZMD_ROOT/runtime/renderers/moltenvk/libMoltenVK.dylib" ] ||
            { echo "MoltenVK is not installed." >&2; exit 2; }
        ;;
    *) echo "Usage: bash scripts/set-renderer.sh dxmt|dxmt-metalfx|vulkan [game|windowed]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    case "$2" in game|windowed) ;; *) echo "Unknown window mode: $2" >&2; exit 2 ;; esac
    printf '%s\n' "$2" > "$ZMD_ROOT/window-mode.conf"
fi
printf '%s\n' "$1" > "$ZMD_ROOT/renderer.conf"
printf 'Next launch: %s. Exit the game and launcher normally, then reopen the official launcher app.\n' "$1"
