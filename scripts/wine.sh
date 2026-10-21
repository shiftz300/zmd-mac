#!/bin/bash
set -euo pipefail
ZMD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZMD_RUNTIME="$ZMD_ROOT/runtime"
export WINEPREFIX="${ZMD_PREFIX:-$ZMD_ROOT/prefix}"
export WINEDEBUG="${WINEDEBUG:--all,err+all}"
# Saved diagnostic choices override inherited values only when explicitly set.
if [ -f "$ZMD_ROOT/wine-log.conf" ]; then
    IFS= read -r ZMD_WINE_LOG < "$ZMD_ROOT/wine-log.conf"
    case "$ZMD_WINE_LOG" in
        errors) export WINEDEBUG=-all,err+all ;;
        warnings) export WINEDEBUG=-all,err+all,warn+all ;;
        off) export WINEDEBUG=-all ;;
        *) echo "Unknown Wine log level: $ZMD_WINE_LOG" >&2; exit 2 ;;
    esac
fi
if [ -f "$ZMD_ROOT/dxmt-log.conf" ]; then
    IFS= read -r ZMD_DXMT_LOG < "$ZMD_ROOT/dxmt-log.conf"
    case "$ZMD_DXMT_LOG" in
        default) unset DXMT_LOG_LEVEL ;;
        error|debug|none) export DXMT_LOG_LEVEL="$ZMD_DXMT_LOG" ;;
        *) echo "Unknown DXMT log level: $ZMD_DXMT_LOG" >&2; exit 2 ;;
    esac
fi
zmd_debug_switch() {
    local config="$1" variable="$2" value
    if [ -f "$ZMD_ROOT/$config" ]; then
        IFS= read -r value < "$ZMD_ROOT/$config"
        case "$value" in
            on) export "$variable=1" ;;
            off) export "$variable=0" ;;
            *) echo "Unknown $config value: $value" >&2; exit 2 ;;
        esac
    fi
}
zmd_debug_switch shader-cache.conf DXMT_SHADER_CACHE
zmd_debug_switch metal-validation.conf MTL_DEBUG_LAYER
zmd_debug_switch shader-validation.conf MTL_SHADER_VALIDATION
export ROSETTA_ADVERTISE_AVX=1
# The no-preloader Wine build only creates per-EXE Dock identities when this is
# explicit. This points exclusively at the app's own runtime.
export WINEDLLPATH="$ZMD_RUNTIME/wine/lib/wine"
ZMD_SYNC="${ZMD_MSYNC:-}"
if [ -z "$ZMD_SYNC" ] && [ -f "$ZMD_ROOT/msync.conf" ]; then
    IFS= read -r ZMD_SYNC < "$ZMD_ROOT/msync.conf"
fi
case "${ZMD_SYNC:-on}" in
    on|1) export WINEMSYNC=1 ;;
    off|0) export WINEMSYNC=0 ;;
    *) echo "Unknown MSync selection: $ZMD_SYNC" >&2; exit 2 ;;
esac
if [ -f "$ZMD_ROOT/metal-hud.conf" ]; then
    IFS= read -r ZMD_HUD < "$ZMD_ROOT/metal-hud.conf"
    case "$ZMD_HUD" in
        on) export MTL_HUD_ENABLED=1 ;;
        off) export MTL_HUD_ENABLED=0 ;;
        *) echo "Unknown Metal HUD selection: $ZMD_HUD" >&2; exit 2 ;;
    esac
fi
export WINEDLLPATH_DXMT="$ZMD_RUNTIME/renderers/dxmt"
export WINEDLLPATH_PREPEND="$ZMD_RUNTIME/renderers/dxmt"
export DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1
unset MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS
ZMD_SELECTED="${ZMD_RENDERER:-}"
ZMD_OVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d;mscoree,mshtml=}"
if [ -z "$ZMD_SELECTED" ] && [ -f "$ZMD_ROOT/renderer.conf" ]; then
    IFS= read -r ZMD_SELECTED < "$ZMD_ROOT/renderer.conf"
fi
case "${ZMD_SELECTED:-dxmt}" in
    dxmt)
        unset CX_LIBVULKAN CX_ACTIVE_GRAPHICS_BACKEND DXMT_ENABLE_NVEXT
        ;;
    dxmt-metalfx)
        unset CX_LIBVULKAN CX_ACTIVE_GRAPHICS_BACKEND
        export WINEDLLPATH_DXMT="$ZMD_RUNTIME/renderers/dxmt-metalfx"
        [ -f "$WINEDLLPATH_DXMT/provenance.json" ] &&
        [ -f "$WINEDLLPATH_DXMT/x86_64-windows/nvapi64.dll" ] &&
        [ -f "$WINEDLLPATH_DXMT/x86_64-windows/nvngx.dll" ] ||
            { echo "Patched DXMT MetalFX is not installed." >&2; exit 2; }
        export WINEDLLPATH_PREPEND="$WINEDLLPATH_DXMT"
        export DXMT_ENABLE_NVEXT=1
        # NGX checks a signed on-disk entry, then Wine loads DXMT's builtin.
        # These unsupported Streamline plugins otherwise attempt D3D12 init
        # even when the game only requests DLSS super resolution.
        ZMD_OVERRIDES="$ZMD_OVERRIDES;nvngx=b;sl.dlss_g,sl.dlss_d,sl.deepdvc=d"
        ;;
    vulkan)
        unset DXMT_ENABLE_NVEXT
        ZMD_MVK=stable
        if [ -f "$ZMD_ROOT/moltenvk.conf" ]; then
            IFS= read -r ZMD_MVK < "$ZMD_ROOT/moltenvk.conf"
        fi
        case "$ZMD_MVK" in
            stable) ZMD_MVK_DIR=moltenvk ;;
            experimental) ZMD_MVK_DIR=moltenvk-experimental ;;
            *) echo "Unknown MoltenVK version: $ZMD_MVK" >&2; exit 2 ;;
        esac
        export CX_LIBVULKAN="$ZMD_RUNTIME/renderers/$ZMD_MVK_DIR/libMoltenVK.dylib"
        [ -f "$CX_LIBVULKAN" ] || { echo "MoltenVK is not installed." >&2; exit 2; }
        ZMD_VK_QUEUE=default
        if [ -f "$ZMD_ROOT/vulkan-queue.conf" ]; then
            IFS= read -r ZMD_VK_QUEUE < "$ZMD_ROOT/vulkan-queue.conf"
        fi
        case "$ZMD_VK_QUEUE" in
            default) export MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 ;;
            async) export MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 ;;
            *) echo "Unknown Vulkan queue mode: $ZMD_VK_QUEUE" >&2; exit 2 ;;
        esac
        # This Wine source requires this name to honor CX_LIBVULKAN. DXMT stays
        # available for the official launcher's separate Direct3D UI.
        export CX_ACTIVE_GRAPHICS_BACKEND=wined3d
        ;;
    *) echo "Unknown renderer selection: $ZMD_SELECTED" >&2; exit 2 ;;
esac
export DYLD_FALLBACK_LIBRARY_PATH="$ZMD_RUNTIME/wine/lib:$ZMD_RUNTIME/wine/lib/wine/x86_64-unix:/usr/lib"
export SSL_CERT_FILE="$ZMD_RUNTIME/ca-bundle.crt"
export WINEDLLOVERRIDES="$ZMD_OVERRIDES"
exec "$ZMD_RUNTIME/wine/bin/wine" "$@"
