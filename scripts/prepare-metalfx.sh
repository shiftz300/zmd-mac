#!/bin/bash
# Run before Wine starts. Keep the signed NGX discovery file inside this prefix;
# nvngx=b loads DXMT's implementation instead. Never alter the game directory.
set -euo pipefail
ZMD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZMD_PREFIX="${ZMD_PREFIX:-$ZMD_ROOT/prefix}"
ZMD_MODE="${1:?renderer required}"
ZMD_STATE="$ZMD_PREFIX/.zmd-metalfx-ngx"
ZMD_TARGET="$ZMD_PREFIX/drive_c/windows/system32/nvngx.dll"
ZMD_SOURCE="$ZMD_PREFIX/drive_c/EndfieldLauncher/games/Arknights Endfield/nvngx_dlss.dll"
# GRYPHLINK also uses the EndField Game directory. Restrict discovery to these
# known locations inside this app's prefix; never search other users or drives.
ZMD_GLOBAL_SOURCE="$ZMD_PREFIX/drive_c/EndfieldLauncher/games/EndField Game/nvngx_dlss.dll"
if [ ! -f "$ZMD_SOURCE" ] && [ -f "$ZMD_GLOBAL_SOURCE" ]; then
    ZMD_SOURCE="$ZMD_GLOBAL_SOURCE"
fi

hash_file() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
fail() { echo "MetalFX NGX: $*" >&2; exit 2; }
atomic_copy() {
    local temporary
    temporary="$(mktemp "$ZMD_TARGET.zmd.XXXXXX")"
    cp -p "$1" "$temporary"
    mv -f "$temporary" "$ZMD_TARGET"
}
matches_record() {
    [ -f "$1" ] && [ -f "$ZMD_TARGET" ] &&
        [ "$(cat "$1")" = "$(hash_file "$ZMD_TARGET")" ]
}

case "$ZMD_MODE" in dxmt|dxmt-metalfx|vulkan) ;; *) fail "unknown renderer";; esac
if [ -d "$ZMD_STATE" ]; then
    # Refuse to replace a file changed by another tool or a Wine upgrade.
    if ! matches_record "$ZMD_STATE/installed.sha256" &&
       ! matches_record "$ZMD_STATE/pending.sha256" &&
       ! matches_record "$ZMD_STATE/original.sha256"; then
        [ -f "$ZMD_STATE/original.absent" ] && [ ! -e "$ZMD_TARGET" ] &&
            [ ! -L "$ZMD_TARGET" ] || fail "entry changed externally; backup retained in $ZMD_STATE"
    fi
    if [ -f "$ZMD_STATE/original.dll" ]; then
        [ "$(hash_file "$ZMD_STATE/original.dll")" = "$(cat "$ZMD_STATE/original.sha256")" ] ||
            fail "original backup checksum mismatch"
    elif [ ! -f "$ZMD_STATE/original.absent" ]; then
        fail "original backup is missing"
    fi
fi

if [ "$ZMD_MODE" != dxmt-metalfx ] || [ ! -f "$ZMD_SOURCE" ]; then
    if [ -d "$ZMD_STATE" ]; then
        if [ -f "$ZMD_STATE/original.dll" ]; then
            atomic_copy "$ZMD_STATE/original.dll"
        else
            rm -f "$ZMD_TARGET"
        fi
        rm -f "$ZMD_STATE"/{original.dll,original.sha256,original.absent,installed.sha256,pending.sha256}
        rmdir "$ZMD_STATE"
        echo "MetalFX NGX: restored original prefix entry"
    fi
    # The launcher must still open when the game has not been downloaded yet.
    exit 0
fi

mkdir -p "$(dirname "$ZMD_TARGET")"
if [ ! -d "$ZMD_STATE" ]; then
    ZMD_TEMP="$(mktemp -d "$ZMD_PREFIX/.zmd-metalfx-ngx.XXXXXX")"
    if [ -f "$ZMD_TARGET" ]; then
        cp -p "$ZMD_TARGET" "$ZMD_TEMP/original.dll"
        hash_file "$ZMD_TEMP/original.dll" > "$ZMD_TEMP/original.sha256"
    elif [ -e "$ZMD_TARGET" ] || [ -L "$ZMD_TARGET" ]; then
        rmdir "$ZMD_TEMP"
        fail "unexpected prefix entry type"
    else
        touch "$ZMD_TEMP/original.absent"
    fi
    mv "$ZMD_TEMP" "$ZMD_STATE"
fi
ZMD_HASH="$(hash_file "$ZMD_SOURCE")"
if [ ! -f "$ZMD_TARGET" ] || [ "$(hash_file "$ZMD_TARGET")" != "$ZMD_HASH" ]; then
    printf '%s\n' "$ZMD_HASH" > "$ZMD_STATE/pending.sha256"
    atomic_copy "$ZMD_SOURCE"
fi
printf '%s\n' "$ZMD_HASH" > "$ZMD_STATE/installed.sha256"
rm -f "$ZMD_STATE/pending.sha256"
echo "MetalFX NGX: signed discovery entry prepared; DXMT builtin selected"
