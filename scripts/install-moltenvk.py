#!/usr/bin/env python3
"""Import only the patched MoltenVK from the upstream release, with pinned hashes."""
import hashlib
import argparse
import json
from pathlib import Path
import shutil
import subprocess
from bootstrap import ROOT, download

URL = ("https://github.com/stoicswe/Endfield_FineWine/releases/download/1.2.4/"
       "endfield-wine-modules.tar.gz")
SHA = "c5955e0ca68e722e3043902615f1d219f8f36972906e62dd8564ba3107a57b04"
archive = ROOT / "downloads/finewine-1.2.4-modules.tar.gz"
download(URL, archive, SHA)
staging = ROOT / "build/moltenvk-import"
staging.mkdir(parents=True, exist_ok=True)
files = ("libMoltenVK.dylib", "LICENSE.MoltenVK", "SOURCE.txt")
subprocess.run(["tar", "-xzf", str(archive), "-C", str(staging), "--strip-components=1",
                *("endfield-wine-modules/" + f for f in files)], check=True)
library = staging / files[0]
subprocess.run(["codesign", "--verify", str(library)], check=True)
description = subprocess.check_output(["file", "-b", str(library)], text=True)
if "x86_64" not in description:
    raise SystemExit("Expected an x86_64 MoltenVK for the Rosetta Wine runtime.")
sha = hashlib.sha256(library.read_bytes()).hexdigest()
manifest = {
    "version": "1.4.2",
    "distribution": "FineWine 1.2.4",
    "archive_url": URL, "archive_sha256": SHA, "library_sha256": sha,
    "source_commit": "db66022459ffb663aa2b50f6b018bc2e124f5edf",
    "patches_commit": "ab8b9e909c5f5d87f166de0cf4ec00a1a8aa29da",
    "license": "Apache-2.0",
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime", type=Path, help="Install only into this runtime.")
args = parser.parse_args()
targets = (args.runtime.resolve(),) if args.runtime else (ROOT / "runtime",)
for runtime in targets:
    if not runtime.exists():
        continue
    target = runtime / "renderers/moltenvk"
    target.mkdir(parents=True, exist_ok=True)
    installed = target / files[0]
    if installed.exists() and hashlib.sha256(installed.read_bytes()).hexdigest() != sha:
        raise SystemExit(f"A different MoltenVK exists at {installed}; refusing to overwrite it.")
    for name in files:
        if not (target / name).exists():
            shutil.copy2(staging / name, target / name)
    (target / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(target)
