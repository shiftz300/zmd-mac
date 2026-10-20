#!/usr/bin/env python3
"""Package an initialized prefix and the relocatable runtime; never overwrite a bundle."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "dist/终末地.app"
SUPPORT = APP / "Contents/SharedSupport"
PREFIX = ROOT / "prefix"

if APP.exists():
    raise SystemExit("Bundle already exists; refusing to overwrite game data.")
if not (PREFIX / "drive_c/EndfieldLauncher/Launcher.exe").is_file():
    raise SystemExit("The official launcher must be installed first.")
# Only wait for this prefix, never stop other Wine applications.
subprocess.run([str(ROOT / "runtime/wine/bin/wineserver"), "-w"],
               env={**os.environ, "WINEPREFIX": str(PREFIX)}, check=True)
(APP / "Contents/MacOS").mkdir(parents=True)
SUPPORT.mkdir()
for name in ("runtime", "prefix"):
    # APFS clones keep this local packaging step fast and avoid duplicate storage.
    subprocess.run(["cp", "-cR", str(ROOT / name), str(SUPPORT / name)], check=True)
(SUPPORT / "scripts").mkdir()
(SUPPORT / "logs").mkdir()
shutil.copy2(ROOT / "scripts/wine.sh", SUPPORT / "scripts/wine.sh")
shutil.copy2(ROOT / "scripts/set-renderer.sh", SUPPORT / "scripts/set-renderer.sh")
shutil.copy2(ROOT / "scripts/prepare-metalfx.sh", SUPPORT / "scripts/prepare-metalfx.sh")
shutil.copy2(ROOT / "scripts/prefix-settings.reg", SUPPORT / "scripts/prefix-settings.reg")
shutil.copy2(ROOT / "README.md", SUPPORT / "README.md")
entry = APP / "Contents/MacOS/Endfield"
shutil.copy2(ROOT / "scripts/app-launch.sh", entry)
entry.chmod(0o755)
metadata = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "终末地",
    "CFBundleName": "终末地",
    "CFBundleIdentifier": "local.zmdmac.endfield",
    "CFBundleExecutable": "Endfield",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": True,
}
(APP / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
subprocess.run([sys.executable, str(ROOT / "scripts/set-app-icon.py"), str(APP)], check=True)
subprocess.run([sys.executable, str(ROOT / "scripts/install-native-launcher.py"), str(APP)], check=True)
print(APP)
print("The bundle contains mutable game data. Do not overwrite it when rebuilding.")
