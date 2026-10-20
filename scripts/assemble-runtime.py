#!/usr/bin/env python3
"""Copy the runtime library closure and remove build-directory loader paths."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from bootstrap import ROOT, MACHO_MAGICS

SDK = ROOT / "tools/x86_64"
RUNTIME = ROOT / "runtime"
LIB = RUNTIME / "wine/lib"
LIB.mkdir(parents=True, exist_ok=True)
UNIX = LIB / "wine/x86_64-unix"
copied = set()


def dependencies(path):
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    return [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:]
            if line.startswith("\t")]


def library_source(dependency, source):
    if dependency.startswith("@loader_path/"):
        return (source.parent / dependency.removeprefix("@loader_path/")).resolve()
    if dependency.startswith("@rpath/"):
        candidate = SDK / "lib" / dependency.removeprefix("@rpath/")
        return candidate.resolve() if candidate.exists() else None
    if dependency.startswith(str(SDK) + "/"):
        return Path(dependency).resolve()
    return None


def copy_library(source):
    source = source.resolve()
    destination = LIB / source.name
    if source.name in copied:
        return
    copied.add(source.name)
    shutil.copy2(source, destination)
    destination.chmod(destination.stat().st_mode | 0o200)
    changes = []
    for old in dependencies(source):
        child = library_source(old, source)
        if child is not None and child != source:
            if not child.is_file() or not child.is_relative_to(SDK):
                raise RuntimeError(f"Unexpected library: {old}")
            copy_library(child)
            changes += ["-change", old, "@rpath/" + child.name]
    subprocess.run(["install_name_tool", "-id", "@rpath/" + source.name,
                    *changes, str(destination)], check=True)


for name in ("libgnutls.30.dylib", "libfreetype.6.dylib",
             "libSDL2-2.0.0.dylib", "libvulkan.1.dylib", "libpcap.A.dylib"):
    source = SDK / "lib" / name
    copy_library(source)
    if name != source.resolve().name:
        link = LIB / name
        if not link.exists():
            link.symlink_to(source.resolve().name)

# DXMT requires the built-in winemetal module to be present during prefix creation.
for architecture in ("i386-windows", "x86_64-windows"):
    shutil.copy2(RUNTIME / "renderers/dxmt" / architecture / "winemetal.dll",
                 LIB / "wine" / architecture / "winemetal.dll")

for path in RUNTIME.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open("rb") as f:
        if f.read(4) not in MACHO_MAGICS:
            continue
    path.chmod(path.stat().st_mode | 0o200)
    changes = []
    for old in dependencies(path):
        if old.startswith(str(SDK) + "/"):
            changes += ["-change", old, "@rpath/" + Path(old).name]
    commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
    if f"path {SDK / 'lib'} " in commands:
        changes += ["-delete_rpath", str(SDK / "lib")]
    for target in (LIB, UNIX):
        value = "@loader_path/" + os.path.relpath(target, path.parent)
        if f"path {value} " not in commands:
            changes += ["-add_rpath", value]
    if changes:
        subprocess.run(["install_name_tool", *changes, str(path)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

shutil.copy2(SDK / "share/curl/curl-ca-bundle.crt", RUNTIME / "ca-bundle.crt")
manifest = {
    "wine": json.loads((ROOT / "build/source-patches.json").read_text()),
    "dxmt": {
        "version": "0.80",
        "url": "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
        "sha256": hashlib.sha256((ROOT / "downloads/dxmt-v0.80-builtin.tar.gz").read_bytes()).hexdigest(),
    },
    "libraries": sorted(copied),
    "session_modules": {
        name: hashlib.sha256((RUNTIME / name).read_bytes()).hexdigest()
        for name in (
            "wine/lib/wine/x86_64-unix/ntdll.so",
            "wine/lib/wine/x86_64-unix/winemac.so",
            "wine/lib/wine/x86_64-windows/winemac.drv",
            "wine/lib/wine/i386-windows/winemac.drv",
        )
    },
}
(RUNTIME / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Bundled {len(copied)} runtime libraries.")
