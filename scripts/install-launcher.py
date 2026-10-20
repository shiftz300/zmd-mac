#!/usr/bin/env python3
"""Unpack the verified official CN launcher, preserving its bootstrap layout."""
import json
import shutil
import subprocess
from bootstrap import ROOT, download

URL = ("https://launcher.hypergryph.com/launcher/get_latest_launcher"
       "?appcode=abYeZZ16BPluCFyT&ta=endfield&channel=1&sub_channel=1")
SHA = "31a30b21c7b9af8f5d65f38510e9e23c494f8584b594d1c816e12da49ac5cc59"
archive = ROOT / "downloads/HypergryphLauncher.exe"
unpacked = ROOT / "downloads/launcher-unpacked"
destination = ROOT / "prefix/drive_c/EndfieldLauncher"
if (destination / "Launcher.exe").exists():
    raise SystemExit("Official launcher already installed; leave updates to its own updater.")
if destination.exists():
    raise SystemExit("Partial launcher installation exists; inspect it before retrying.")
download(URL, archive, SHA)
if not unpacked.exists():
    subprocess.run([str(ROOT / "tools/native/opt/sevenzip/bin/7zz"),
                    "x", "-y", f"-o{unpacked}", str(archive)], check=True)
versions = list((unpacked / "$0").glob("*/Games.exe"))
if len(versions) != 1:
    raise SystemExit("Unexpected installer layout; refusing to guess the bootstrap location.")
shutil.copytree(unpacked / "$0", destination)
# The bootstrap appends the version directory when locating Games.exe.
shutil.copy2(versions[0].parent / "Launcher.exe", destination / "Launcher.exe")
(destination / "download-origin.json").write_text(json.dumps({
    "url": URL, "sha256": SHA, "version": versions[0].parent.name,
    "retrieved": "2026-10-20",
}, indent=2) + "\n")
print(destination / "Launcher.exe")
