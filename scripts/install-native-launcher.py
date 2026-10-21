#!/usr/bin/env python3
"""Upgrade the app entry in place without copying or modifying live game data."""
from pathlib import Path
import os
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT / "dist/鹰角启动器.app"
if not DEFAULT_APP.exists():
    DEFAULT_APP = ROOT / "dist/终末地.app"  # Existing development bundle.
APP = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_APP
CONTENTS = APP / "Contents"
ENTRY = CONTENTS / "MacOS/Endfield"
if not ENTRY.is_file():
    raise SystemExit("An existing application is required.")
runtime_record = json.loads((CONTENTS / "SharedSupport/runtime/provenance.json").read_text())
session_patch = hashlib.sha256((ROOT / "scripts/patches/wine-session-dock.patch").read_bytes()).hexdigest()
if not any(p.get("sha256") == session_patch for p in runtime_record.get("wine", {}).get("local_patches", [])):
    raise SystemExit("Install the matching Wine Dock/session runtime patch before hiding the native entry.")
WORK = Path(os.environ.get("ZMD_WORK_DIR", ROOT)).expanduser().resolve()
BUILD = WORK / "build/native-launcher"
BUILD.mkdir(parents=True, exist_ok=True)
subprocess.run([
    "swiftc", "-O", "-target", "arm64-apple-macos14.0",
    "-module-cache-path", str(WORK / "build/swift-module-cache"),
    str(ROOT / "scripts/native-launcher.swift"), str(ROOT / "scripts/native-settings.swift"),
    str(ROOT / "Sources/zmd/Core.swift"), "-o", str(BUILD / "Endfield"),
], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(BUILD / "Endfield")], check=True)
subprocess.run(["codesign", "--verify", str(BUILD / "Endfield")], check=True)
backup = BUILD / f"backup-{time.time_ns()}"
backup.mkdir()
for name, original in (("Endfield", ENTRY), ("Info.plist", CONTENTS / "Info.plist"),
                       ("launch.sh", CONTENTS / "MacOS/launch.sh"),
                       ("app-quit.sh", CONTENTS / "SharedSupport/scripts/app-quit.sh"),
                       *[(name, CONTENTS / "SharedSupport/scripts" / name)
                         for name in ("wine.sh", "set-renderer.sh", "prepare-metalfx.sh")]):
    if original.exists():
        shutil.copy2(original, backup / name)
for source, target in (
    (ROOT / "scripts/app-launch.sh", CONTENTS / "MacOS/launch.sh"),
    (BUILD / "Endfield", ENTRY),
    *[(ROOT / "scripts" / name, CONTENTS / "SharedSupport/scripts" / name)
      for name in ("wine.sh", "set-renderer.sh", "prepare-metalfx.sh")],
):
    temporary = target.with_name(target.name + ".new")
    shutil.copy2(source, temporary)
    temporary.chmod(0o755)
    temporary.replace(target)
metadata = plistlib.loads((CONTENTS / "Info.plist").read_bytes())
metadata["CFBundleShortVersionString"] = "0.5.7"
metadata["CFBundleVersion"] = "5"
metadata["CFBundleName"] = APP.stem
metadata["CFBundleDisplayName"] = APP.stem
metadata["LSMultipleInstancesProhibited"] = True
metadata["LSUIElement"] = False
temporary = CONTENTS / "Info.plist.new"
temporary.write_bytes(plistlib.dumps(metadata))
temporary.replace(CONTENTS / "Info.plist")
(CONTENTS / "SharedSupport/scripts/app-quit.sh").unlink(missing_ok=True)
# Verify the executable only: this local bundle intentionally contains mutable
# game data and is not signed with a sealed bundle resource envelope.
subprocess.run(["codesign", "--verify", "--ignore-resources", str(ENTRY)], check=True)
registration = subprocess.run([
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    "-f", str(APP)], check=False)
if registration.returncode:
    print("Entry updated; system app registration needs to be retried outside the sandbox.")
print(f"Native launch/quit entry installed: {APP}")
print(f"Previous entry saved: {backup}")
