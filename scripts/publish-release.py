#!/usr/bin/env python3
"""Publish verified CI artifacts, keeping incomplete uploads in a draft release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile

ASSETS = ("zmd-mac-macos-arm64.pkg", "zmd-mac-macos-arm64.zip",
          "zmd-mac-source.zip", "third-party-sources.tar.gz")


def verify(tag, directory):
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)(-[0-9A-Za-z][0-9A-Za-z.-]*)?", tag)
    if not match:
        raise ValueError("Expected a version tag such as v0.5.0 or v0.5.0-rc.1")
    files = []
    for name in ASSETS:
        asset = directory / name
        checksum = directory / (name + ".sha256")
        if not asset.is_file() or asset.is_symlink() or asset.stat().st_size == 0:
            raise ValueError(f"Missing or invalid asset: {name}")
        expected = hashlib.sha256()
        with asset.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                expected.update(chunk)
        if checksum.is_symlink() or checksum.read_text().strip() != expected.hexdigest() + "  " + name:
            raise ValueError(f"Checksum mismatch: {name}")
        files += [asset, checksum]
    with zipfile.ZipFile(directory / "zmd-mac-macos-arm64.zip") as archive:
        metadata = plistlib.loads(archive.read("zmd-mac/payload/AppTemplate.app/Contents/Info.plist"))
    if metadata.get("CFBundleShortVersionString") != match[1]:
        raise ValueError("Tag version does not match the packaged app version")
    return files, bool(match[2])


def publish(tag, directory, check_only=False):
    files, prerelease = verify(tag, directory)
    if check_only:
        print("PASS: all 8 release assets and the packaged version verified")
        return
    repository = os.environ["GITHUB_REPOSITORY"]
    commit = os.environ["GITHUB_SHA"]
    command = ["gh", "release"]
    view = subprocess.run(command + ["view", tag, "--repo", repository,
                          "--json", "isDraft,targetCommitish"], text=True, capture_output=True)
    if view.returncode == 0:
        existing = json.loads(view.stdout)
        if not existing["isDraft"] or existing["targetCommitish"] != commit:
            raise ValueError("Refusing to modify a published release or a draft from another commit")
    else:
        arguments = ["create", tag, "--repo", repository, "--verify-tag", "--target", commit,
                     "--title", "zmd-mac " + tag, "--draft", "--generate-notes",
                     "--notes", "Apple Silicon / macOS 27 / Rosetta 2。PKG 可选择国服或 Global。\n"
                     "包含 CLI、项目源码及第三方源码；安装包尚未进行 Developer ID 公证。"]
        if prerelease:
            arguments.append("--prerelease")
        subprocess.run(command + arguments, check=True)
    # --clobber is restricted to this commit's unpublished draft, allowing a
    # failed upload to resume without modifying any published assets.
    subprocess.run(command + ["upload", tag, "--repo", repository, "--clobber", *map(str, files)], check=True)
    uploaded = json.loads(subprocess.check_output(command + ["view", tag, "--repo", repository,
                           "--json", "assets"], text=True))
    remote = {asset["name"]: asset["size"] for asset in uploaded["assets"]}
    expected = {asset.name: asset.stat().st_size for asset in files}
    if remote != expected:
        raise ValueError("Draft assets are incomplete or unexpected; leaving the release unpublished")
    subprocess.run(command + ["edit", tag, "--repo", repository, "--draft=false",
                   "--prerelease=" + str(prerelease).lower(),
                   "--latest=" + str(not prerelease).lower()], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, default=Path("release"))
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    publish(args.tag, args.directory.resolve(), args.check_only)
