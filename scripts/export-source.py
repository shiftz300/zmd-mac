#!/usr/bin/env python3
"""Export only the project's public source, never local game/install data."""
import hashlib
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
files = [root / name for name in (
    "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", ".gitignore",
    "dependencies.lock.json", "macports.lock.json", "moltenvk-experimental.lock.json",
)]
for directory in ("Sources", "Tests", "scripts", "docs", "licenses", ".github"):
    files.extend(path for path in (root / directory).rglob("*")
                 if path.is_file() and "__pycache__" not in path.parts and
                 path.name != ".DS_Store")
output = root / "release/zmd-mac-source.zip"
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(files):
        if path.is_symlink():
            raise RuntimeError(f"Source export rejects symlinks: {path}")
        archive.write(path, "zmd-mac/" + path.relative_to(root).as_posix())
output.with_suffix(".zip.sha256").write_text(
    hashlib.sha256(output.read_bytes()).hexdigest() + "  " + output.name + "\n")
print(output)
