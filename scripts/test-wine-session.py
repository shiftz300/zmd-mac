#!/usr/bin/env python3
"""Test real Wine Dock routing in isolated prefixes, without the installed game."""
import argparse
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime", type=Path, default=root / "runtime")
runtime = parser.parse_args().runtime.resolve()
build = root / "build/wine-session-tests"
build.mkdir(parents=True, exist_ok=True)
compiler = root / "tools/native/opt/mingw-w64/bin/x86_64-w64-mingw32-gcc"
subprocess.run([str(compiler), "-O2", "-static", "-mwindows",
                str(root / "Tests/wine-session-fixture.c"), "-luser32",
                "-o", str(build / "fixture.exe")], check=True)
subprocess.run([str(compiler), "-O2", "-static", "-shared",
                str(root / "Tests/qt-exit-fixture.c"),
                str(root / "Tests/qt-exit-fixture.def"), "-luser32",
                "-o", str(build / "Qt5Core.dll")], check=True)
for source, output in (("scripts/native-launcher.swift", "Endfield"),
                       ("Tests/check-wine-session.swift", "check")):
    subprocess.run(["swiftc", "-O", "-module-cache-path", str(root / "build/swift-module-cache"),
                    str(root / source),
                    *([str(root / "scripts/native-settings.swift"), str(root / "Sources/zmd/Core.swift")] if output == "Endfield" else []), "-o", str(build / output)], check=True)
for selected in ("game", "launcher", "launcher-retry"):
    with tempfile.TemporaryDirectory(prefix=selected + "-", dir=build) as temporary:
        app = Path(temporary) / "SessionTest.app"
        contents = app / "Contents"
        support = contents / "SharedSupport"
        for path in (contents / "MacOS", support / "scripts", support / "markers"):
            path.mkdir(parents=True)
        subprocess.run(["cp", "-cR", str(runtime), str(support / "runtime")], check=True)
        shutil.copy2(build / "Endfield", contents / "MacOS/Endfield")
        (support / "settings-window.conf").write_text("off\n")
        shutil.copy2(root / "scripts/wine.sh", support / "scripts/wine.sh")
        for name in ("Endfield.exe", "Games.exe", "QtWebEngineProcess.exe"):
            shutil.copy2(build / "fixture.exe", support / name)
        shutil.copy2(build / "Qt5Core.dll", support / "Qt5Core.dll")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Endfield", "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "local.zmdmac.wine-session-test", "LSUIElement": True,
        }))
        (contents / "MacOS/launch.sh").write_text('''#!/bin/bash
set -eu
support="$(cd "$(dirname "$0")/../SharedSupport" && pwd)"
cd "$support/markers"
export ZMD_SESSION_TEST_DIR="Z:$support/markers"
bash "$support/scripts/wine.sh" start.exe /wait /unix "$support/Endfield.exe" game &
game=$!
bash "$support/scripts/wine.sh" start.exe /wait /unix "$support/Games.exe" launcher &
launcher=$!
bash "$support/scripts/wine.sh" start.exe /wait /unix "$support/QtWebEngineProcess.exe" helper &
helper=$!
wait "$game"
wait "$launcher"
wait "$helper"
WINEPREFIX="$support/prefix" "$support/runtime/wine/bin/wineserver" -w
''')
        try:
            subprocess.run([str(build / "check"), str(app), selected], check=True, timeout=60)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            shutil.copytree(support / "logs", build / ("failure-" + Path(temporary).name))
            raise
        finally:
            # Only this newly generated test prefix; never the user's game.
            subprocess.run([str(support / "runtime/wine/bin/wineserver"), "-k"],
                           env={**os.environ, "WINEPREFIX": str(support / "prefix")})
            subprocess.run([str(build / "check"), str(app), "--cleanup"], timeout=10)
