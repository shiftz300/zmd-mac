#!/usr/bin/env python3
"""Use the installed official launcher's icon for the macOS application."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

APP = Path(sys.argv[1]).resolve()
CONTENTS = APP / "Contents"
launcher = CONTENTS / "SharedSupport/prefix/drive_c/EndfieldLauncher"
icons = sorted(launcher.glob("*/res/icons/app.ico"))
if not icons:
    raise SystemExit("Official launcher icon not found.")
resources = CONTENTS / "Resources"
resources.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="endfield-icon-") as temporary:
    temporary = Path(temporary)
    original = temporary / "original.png"
    subprocess.run(
        ["sips", "-s", "format", "png", str(icons[-1]), "--out", str(original)],
        check=True, stdout=subprocess.DEVNULL,
    )
    iconset = temporary / "Endfield.iconset"
    iconset.mkdir()
    # The source is 256 px; provide the complete macOS iconset size family.
    for name, size in (
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ):
        subprocess.run(
            ["sips", "-z", str(size), str(size), str(original),
             "--out", str(iconset / f"{name}.png")],
            check=True, stdout=subprocess.DEVNULL,
        )
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset),
         "-o", str(resources / "Endfield.icns")],
        check=True,
    )
plist = CONTENTS / "Info.plist"
metadata = plistlib.loads(plist.read_bytes())
metadata["CFBundleIconFile"] = "Endfield.icns"
updated = plist.with_suffix(".plist.new")
updated.write_bytes(plistlib.dumps(metadata))
updated.replace(plist)
print(f"Official launcher icon installed: {APP}")
