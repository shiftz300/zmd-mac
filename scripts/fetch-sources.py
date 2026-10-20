#!/usr/bin/env python3
"""Download and verify the exact source and renderer inputs used for this build."""
import subprocess
from bootstrap import ROOT, download

inputs = (
    ("crossover-sources-26.3.0.tar.gz",
     "https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz",
     "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"),
    ("finewine-a62d906c.tar.gz",
     "https://codeload.github.com/Lunarchy107/Endfield_FineWine/tar.gz/a62d906c18e790acad3603ea639a3baba4e201ad",
     "5f5260628591599219dbe3ea8d14e9c3962d24f14817fe5f60616559385a859d"),
    ("dxmt-v0.80-builtin.tar.gz",
     "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
     "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"),
)
for name, url, sha in inputs:
    download(url, ROOT / "downloads" / name, sha)
    print(f"Verified {name}")

patch_dir = ROOT / "vendor/Endfield_FineWine-a62d906c18e790acad3603ea639a3baba4e201ad"
if not patch_dir.exists():
    patch_dir.parent.mkdir(exist_ok=True)
    subprocess.run(["tar", "-xzf", str(ROOT / "downloads/finewine-a62d906c.tar.gz"),
                    "-C", str(patch_dir.parent)], check=True)
renderer = ROOT / "runtime/renderers/dxmt"
if not renderer.exists():
    renderer.mkdir(parents=True)
    subprocess.run(["tar", "-xzf", str(ROOT / "downloads/dxmt-v0.80-builtin.tar.gz"),
                    "-C", str(renderer), "--strip-components=1"], check=True)
