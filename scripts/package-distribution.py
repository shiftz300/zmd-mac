#!/usr/bin/env python3
"""Build a consumer distribution containing no Python, game files or user prefix."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
WORK = Path(os.environ.get("ZMD_WORK_DIR", PROJECT / ".work")).resolve()


def copy_tree(source, target):
    # Both sources are explicitly selected runtime/tool folders, never a prefix.
    subprocess.run(["cp", "-cR", str(source), str(target)], check=True)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def build(args):
    output = args.output.expanduser().absolute()
    runtime = args.runtime.expanduser().resolve()
    sevenzip = args.sevenzip.expanduser().resolve()
    if output.exists() or output.is_symlink():
        raise SystemExit(f"Output already exists; refusing to overwrite: {output}")
    archive = output.with_name(output.name + "-macos-arm64.zip")
    if archive.exists() or archive.with_suffix(archive.suffix + ".sha256").exists():
        raise SystemExit(f"Archive already exists: {archive}")
    for name in ("wine/bin/wine", "wine/bin/wineserver", "provenance.json",
                 "renderers/moltenvk/libMoltenVK.dylib",
                 "renderers/dxmt/x86_64-windows/d3d11.dll",
                 "renderers/dxmt-metalfx/x86_64-windows/nvngx.dll",
                 "renderers/dxmt-metalfx/x86_64-windows/nvapi64.dll",
                 "renderers/dxmt-metalfx/provenance.json"):
        if not (runtime / name).is_file():
            raise SystemExit(f"Missing runtime component: {name}")
    if (runtime / "prefix").exists():
        raise SystemExit("Runtime must not contain a user prefix.")
    provenance = json.loads((runtime / "provenance.json").read_text())
    session_patch_hash = digest(PROJECT / "scripts/patches/wine-session-dock.patch")
    if not any(p.get("sha256") == session_patch_hash for p in
               provenance.get("wine", {}).get("local_patches", [])):
        raise SystemExit("Runtime needs the Wine Dock/session patch before packaging the hidden launcher.")
    for name, expected in provenance.get("session_modules", {}).items():
        if digest(runtime / name) != expected:
            raise SystemExit(f"Wine session module checksum mismatch: {name}")
    output.parent.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".zmd-release-", dir=output.parent) as temporary:
        staging = Path(temporary) / output.name
        payload = staging / "payload"
        app = payload / "AppTemplate.app"
        contents = app / "Contents"
        support = contents / "SharedSupport"
        (contents / "MacOS").mkdir(parents=True)
        (support / "scripts").mkdir(parents=True)
        (support / "logs").mkdir()
        for name in ("wine.sh", "set-renderer.sh", "prepare-metalfx.sh", "prefix-settings.reg"):
            shutil.copy2(PROJECT / "scripts" / name, support / "scripts" / name)
        shutil.copy2(PROJECT / "scripts/app-launch.sh", contents / "MacOS/launch.sh")
        for sources, target in (
            ([PROJECT / "Sources/zmd/Core.swift", PROJECT / "Sources/zmd/main.swift"], staging / "zmd"),
            ([PROJECT / "scripts/native-launcher.swift", PROJECT / "scripts/native-settings.swift", PROJECT / "Sources/zmd/Core.swift"], contents / "MacOS/Endfield"),
        ):
            subprocess.run(["swiftc", "-O", "-target", "arm64-apple-macos27.0",
                            "-module-cache-path", str(WORK / "build/swift-module-cache"),
                            *map(str, sources), "-o", str(target)], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
        metadata = {
            "CFBundleDevelopmentRegion": "zh_CN", "CFBundleDisplayName": "鹰角启动器",
            "CFBundleName": "鹰角启动器", "CFBundleIdentifier": "local.zmdmac.endfield.template",
            "CFBundleExecutable": "Endfield", "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": "0.5.7",
            "CFBundleVersion": "5", "LSMinimumSystemVersion": "27.0",
            "LSMultipleInstancesProhibited": True, "NSHighResolutionCapable": True,
            # The payload is not an installed app. Installation makes its copy discoverable.
            "LSUIElement": True,
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
        copy_tree(runtime, payload / "runtime")
        (payload / "sevenzip/bin").mkdir(parents=True)
        (payload / "sevenzip/lib").mkdir()
        shutil.copy2(sevenzip / "bin/7zz", payload / "sevenzip/bin/7zz")
        shutil.copy2(sevenzip / "lib/7z.so", payload / "sevenzip/lib/7z.so")
        # A Homebrew tool must not keep references to the build machine.
        for binary in (payload / "sevenzip/bin/7zz", payload / "sevenzip/lib/7z.so"):
            commands = subprocess.check_output(["otool", "-l", str(binary)], text=True).splitlines()
            for i, line in enumerate(commands):
                if line.strip() == "cmd LC_RPATH":
                    path = commands[i + 2].strip().split(" ", 2)[1]
                    subprocess.run(["install_name_tool", "-delete_rpath", path, str(binary)], check=True)
            if binary.suffix == ".so":
                subprocess.run(["install_name_tool", "-id", "@loader_path/7z.so", str(binary)], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True)
        for name in ("README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(PROJECT / name, staging / name)
            shutil.copy2(PROJECT / name, support / name)
        shutil.copytree(PROJECT / "docs", staging / "docs")
        shutil.copytree(PROJECT / "docs", support / "docs")
        shutil.copytree(PROJECT / "licenses", staging / "licenses")
        shutil.copytree(PROJECT / "licenses", support / "licenses")
        for name in ("dependencies.lock.json", "macports.lock.json"):
            shutil.copy2(PROJECT / name, support / name)
            shutil.copy2(PROJECT / name, staging / name)
        start = staging / "安装终末地.command"
        start.write_text('''#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./zmd setup || printf '\\n安装未完成，请查看上方错误。\\n'
printf '\\n按回车关闭此窗口。'
IFS= read -r _
''')
        start.chmod(0o755)
        files, links = {}, {}
        for path in sorted(payload.rglob("*")):
            name = path.relative_to(payload).as_posix()
            if path.is_symlink():
                if not path.resolve().is_relative_to(payload):
                    raise RuntimeError(f"Non-relocatable runtime symlink: {name}")
                links[name] = os.readlink(path)
            elif path.is_file():
                files[name] = digest(path)
        (payload / "manifest.json").write_text(json.dumps(
            {"format": 1, "files": files, "links": links}, indent=2, sort_keys=True) + "\n")
        # All retained files come from a runtime-only directory, fixed scripts and
        # fresh template. No existing app or Windows prefix is ever included.
        staging.rename(output)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", "--norsrc",
                    str(output), str(archive)], check=True)
    archive.with_suffix(archive.suffix + ".sha256").write_text(
        digest(archive) + "  " + archive.name + "\n")
    print(f"Distribution: {output}")
    print(f"Archive: {archive}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--sevenzip", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    build(parser.parse_args())
