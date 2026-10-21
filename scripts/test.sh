#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
for file in scripts/*.sh; do bash -n "$file"; done
python3 - <<'PY'
import ast
from pathlib import Path
for path in Path("scripts").glob("*.py"):
    ast.parse(path.read_text(), filename=str(path))
print("PASS: shell and Python syntax")
PY
xcrun swiftc -module-cache-path build/swift-module-cache \
    Sources/zmd/Core.swift Tests/main.swift -o build/tests/core
build/tests/core
xcrun swiftc -O -module-cache-path build/swift-module-cache \
    Sources/zmd/Core.swift Sources/zmd/main.swift -o build/tests/zmd
build/tests/zmd --help
python3 scripts/test-cli.py build/tests/zmd
python3 scripts/test-metalfx.py
python3 scripts/test-build.py
python3 scripts/test-release.py
