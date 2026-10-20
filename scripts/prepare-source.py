#!/usr/bin/env python3
"""Extract the pinned LGPL Wine source and apply the pinned compatibility series."""
import hashlib
import json
from pathlib import Path
import subprocess
from bootstrap import ROOT
from build_support import apply_git_patch

SOURCE_SHA = "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
PATCH_COMMIT = "a62d906c18e790acad3603ea639a3baba4e201ad"
ARCHIVE = ROOT / "downloads/crossover-sources-26.3.0.tar.gz"
SOURCE = ROOT / "build/wine-src"
PATCHES = ROOT / f"vendor/Endfield_FineWine-{PATCH_COMMIT}/patches"
STAMP = ROOT / "build/source-patches.json"

if STAMP.exists():
    print("Patched source already prepared.")
    raise SystemExit()
if SOURCE.exists() and any(SOURCE.iterdir()):
    raise SystemExit("Partial source tree exists; inspect it before retrying.")
if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != SOURCE_SHA:
    raise SystemExit("Wine source checksum mismatch.")
SOURCE.mkdir(parents=True, exist_ok=True)
subprocess.run(["tar", "-xzf", str(ARCHIVE), "-C", str(SOURCE),
                "--strip-components=2", "sources/wine"], check=True)
series = [
    "highball", "stage2-dwproton/em-backports", "stage2-dwproton/misc",
    "stage2-dwproton/ace-core", "stage1-macos", "sikarugir",
]
applied = []
for folder in series:
    for patch in sorted((PATCHES / folder).glob("*.patch")):
        print(patch.relative_to(PATCHES), flush=True)
        if folder == "highball":
            with patch.open("rb") as f:
                subprocess.run(["patch", "-p1", "-s", "--no-backup-if-mismatch"],
                               cwd=SOURCE, stdin=f, check=True)
        else:
            apply_git_patch(patch, SOURCE)
        applied.append({
            "path": str(patch.relative_to(PATCHES)),
            "sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
        })
STAMP.write_text(json.dumps({
    "wine_version": "26.3.0", "wine_source_sha256": SOURCE_SHA,
    "finewine_commit": PATCH_COMMIT, "patches": applied,
}, indent=2) + "\n")
print(f"Applied {len(applied)} patches.")
