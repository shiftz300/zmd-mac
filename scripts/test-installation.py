#!/usr/bin/env python3
"""Install official EXEs into isolated apps and check application discovery."""
import argparse
import plistlib
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("distribution", type=Path)
parser.add_argument("--cn-exe", type=Path, required=True)
parser.add_argument("--global-exe", type=Path, required=True)
args = parser.parse_args()
distribution = args.distribution.resolve()
register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
template = plistlib.loads((distribution / "payload/AppTemplate.app/Contents/Info.plist").read_bytes())
assert template["LSUIElement"] is True

with tempfile.TemporaryDirectory(prefix="zmd-install-check-", suffix=".noindex") as temporary:
    root = Path(temporary)
    for region, name, exe in (("cn", "鹰角启动器", args.cn_exe), ("global", "GRYPHLINK", args.global_exe)):
        app = root / (name + ".app")
        try:
            subprocess.run([str(distribution / "zmd"), "install", "--region", region,
                            "--exe", str(exe.resolve()), "--output", str(app)], check=True, timeout=300)
            assert app.is_dir() and not app.is_symlink()
            contents = app / "Contents"
            metadata = plistlib.loads((contents / "Info.plist").read_bytes())
            assert metadata["CFBundleName"] == metadata["CFBundleDisplayName"] == name
            assert metadata["LSUIElement"] is False
            assert metadata["CFBundleShortVersionString"] == template["CFBundleShortVersionString"]
            icon = contents / "Resources" / metadata["CFBundleIconFile"]
            assert icon.read_bytes().startswith(b"icns")
            subprocess.run(["sips", "-s", "format", "png", str(icon), "--out", str(root / (region + ".png"))],
                           check=True, stdout=subprocess.DEVNULL)
            records = subprocess.check_output([register, "-dump"], text=True)
            assert any(str(app) in record and metadata["CFBundleIdentifier"] in record
                       for record in records.split("--------------------------------------------------------------------------------")), "App not registered"
            assert sorted(p.name for p in root.glob("*.app")) == ([name + ".app"] if region == "cn" else ["GRYPHLINK.app", "鹰角启动器.app"])
            print(f"PASS: {region} real app, official icon, visible metadata and system registration", flush=True)
        finally:
            # Tests must not leave phantom icons behind after removing fixtures.
            if app.exists():
                subprocess.run([register, "-u", str(app)], check=True)
