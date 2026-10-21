#!/usr/bin/env python3
"""Exercise native Quit in isolated AppKit fixtures; never open the real game."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
build = root / "build/native-lifecycle"
build.mkdir(parents=True, exist_ok=True)
for source, output in (("native-launcher.swift", "Endfield"),
                       ("lifecycle-fixture.swift", "Fixture"),
                       ("check-native-launcher.swift", "check")):
    subprocess.run(["swiftc", "-O", "-module-cache-path", str(root / "build/swift-module-cache"),
                    "-D", "LIFECYCLE_TEST",
                    str(root / "scripts" / source),
                    *([str(root / "scripts/native-settings.swift"), str(root / "Sources/zmd/Core.swift")] if output == "Endfield" else []), "-o", str(build / output)], check=True)
with tempfile.TemporaryDirectory(prefix="session-", dir=build) as temporary:
    app = Path(temporary) / "LifecycleTest.app"
    contents = app / "Contents"
    support = contents / "SharedSupport"
    for folder in (contents / "MacOS", support / "logs", support / "prefix", support / "other-prefix"):
        folder.mkdir(parents=True, exist_ok=True)
    shutil.copy2(build / "Endfield", contents / "MacOS/Endfield")
    (support / "settings-window.conf").write_text("off\n")
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "Endfield", "CFBundleIdentifier": "local.zmdmac.endfield.lifecycle-test",
        "CFBundlePackageType": "APPL", "CFBundleName": "ZMD lifecycle test",
        "LSUIElement": False,
    }))
    (contents / "MacOS/launch.sh").write_text('''#!/bin/bash
set -eu
support="$(cd "$(dirname "$0")/../SharedSupport" && pwd)"
if [ -f "$support/ready" ]; then
    touch "$support/restarted"
    while [ ! -f "$support/session-ended" ]; do sleep 0.1; done
    exit 0
fi
touch "$support/ready"
while [ ! -f "$support/session-ended" ]; do
    if [ -f "$support/game-ended" ] && [ -f "$support/launcher-ended" ]; then exit 0; fi
    sleep 0.1
done
''')
    fixture = support / "runtime/Fixture.app/Contents"
    (fixture / "MacOS").mkdir(parents=True)
    shutil.copy2(build / "Fixture", fixture / "MacOS/Fixture")
    (fixture / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "local.zmdmac.endfield.lifecycle-fixture",
        "CFBundlePackageType": "APPL", "CFBundleName": "ZMD session fixture", "LSUIElement": True,
    }))
    try:
        subprocess.run([str(build / "check"), str(app)], check=True, timeout=180)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        saved = build / ("failure-" + Path(temporary).name)
        shutil.copytree(support, saved)
        print(f"Failure diagnostics: {saved}", flush=True)
        raise
    finally:
        subprocess.run([str(build / "check"), str(app), "--cleanup"], check=True, timeout=10)
        register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        for registered in (fixture.parent, app):
            subprocess.run([register, "-u", str(registered)], check=False)
