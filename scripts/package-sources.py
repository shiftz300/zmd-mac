#!/usr/bin/env python3
"""Retain pinned source inputs alongside a redistributable runtime artifact."""
import json
import os
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
    (PROJECT / "moltenvk-experimental.lock.json", "moltenvk-experimental.lock.json"),
])
# Optional experiment sources travel with a distribution that includes it.
runtime = Path(os.environ.get("ZMD_RUNTIME_SOURCE", ROOT / "runtime")).expanduser().resolve()
if (runtime / "renderers/moltenvk-experimental/provenance.json").is_file():
    experimental = json.loads((PROJECT / "moltenvk-experimental.lock.json").read_text())
    for name, entry in experimental.items():
        filename = "CPM_0.40.8.cmake" if name == "cpm" else name + "-" + entry["commit"] + ".tar.gz"
        source = ROOT / "downloads/moltenvk-experimental" / filename
        download(entry["url"], source, entry["sha256"])
        inputs.append((source, "moltenvk-experimental/" + filename))
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
