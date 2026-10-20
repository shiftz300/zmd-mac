#!/usr/bin/env python3
"""Retain pinned source inputs alongside a redistributable runtime artifact."""
import json
import tarfile
from pathlib import Path
from bootstrap import ROOT, PROJECT, download, digest

output = PROJECT / "release/third-party-sources.tar.gz"
if output.exists():
    raise SystemExit(f"Refusing to overwrite: {output}")
inputs = []
entries = json.loads((PROJECT / "licenses/sources.json").read_text())
for name, entry in entries.items():
    source = ROOT / "downloads/license-sources" / entry["file"]
    download(entry["url"], source, entry["sha256"])
    inputs.append((source, "upstream/" + entry["file"]))

for name in ("crossover-sources-26.3.0.tar.gz", "finewine-a62d906c.tar.gz"):
    path = ROOT / "downloads" / name
    if not path.is_file():
        raise SystemExit(f"Run the source download step first: {path}")
    inputs.append((path, "upstream/" + name))
inputs.extend([
    (PROJECT / "licenses", "licenses"),
    (PROJECT / "scripts", "build-scripts"),
    (PROJECT / "dependencies.lock.json", "dependencies.lock.json"),
    (PROJECT / "macports.lock.json", "macports.lock.json"),
])
stamp = ROOT / "build/source-patches.json"
if stamp.exists():
    inputs.append((stamp, "source-patches.json"))
output.parent.mkdir(exist_ok=True)
with tarfile.open(output, "w:gz") as archive:
    for source, name in inputs:
        archive.add(source, arcname=name, filter=lambda info: None
                    if "__pycache__" in Path(info.name).parts else info)
output.with_name(output.name + ".sha256").write_text(digest(output) + "  " + output.name + "\n")
print(output)
