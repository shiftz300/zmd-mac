#!/bin/bash
# Build-time Python and compilers are confined to CI/developer machines.
set -euo pipefail
ZMD_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
export ZMD_WORK_DIR="${ZMD_WORK_DIR:-$ZMD_PROJECT/.work}"
mkdir -p "$ZMD_WORK_DIR"
if [ -z "${ZMD_RUNTIME_SOURCE:-}" ]; then
    python3 "$ZMD_PROJECT/scripts/bootstrap.py"
    python3 "$ZMD_PROJECT/scripts/bootstrap-x86.py"
    python3 "$ZMD_PROJECT/scripts/fetch-sources.py"
    python3 "$ZMD_PROJECT/scripts/prepare-source.py"
    bash "$ZMD_PROJECT/scripts/build-wine.sh"
    python3 "$ZMD_PROJECT/scripts/assemble-runtime.py"
    python3 "$ZMD_PROJECT/scripts/install-moltenvk.py" --runtime "$ZMD_WORK_DIR/runtime"
    python3 "$ZMD_PROJECT/scripts/build-dxmt-metalfx.py" --runtime "$ZMD_WORK_DIR/runtime"
    ZMD_RUNTIME_SOURCE="$ZMD_WORK_DIR/runtime"
fi
if [ -z "${ZMD_SEVENZIP_SOURCE:-}" ]; then
    python3 "$ZMD_PROJECT/scripts/bootstrap.py" --only sevenzip
    ZMD_SEVENZIP_SOURCE="$ZMD_WORK_DIR/tools/native/opt/sevenzip"
fi
python3 "$ZMD_PROJECT/scripts/package-distribution.py" \
    --runtime "$ZMD_RUNTIME_SOURCE" --sevenzip "$ZMD_SEVENZIP_SOURCE" \
    --output "${ZMD_RELEASE_OUTPUT:-$ZMD_PROJECT/release/zmd-mac}"
python3 "$ZMD_PROJECT/scripts/package-pkg.py" \
    --distribution "${ZMD_RELEASE_OUTPUT:-$ZMD_PROJECT/release/zmd-mac}" \
    --output "${ZMD_RELEASE_OUTPUT:-$ZMD_PROJECT/release/zmd-mac}-macos-arm64.pkg"
