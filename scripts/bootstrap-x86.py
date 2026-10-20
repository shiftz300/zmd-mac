#!/usr/bin/env python3
"""Unpack official MacPorts x86_64 packages locally, without installing MacPorts."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request
from bootstrap import CACHE, ROOT, PROJECT, MACHO_MAGICS, download

BASE = ROOT / "tools/x86_64"
BASE.mkdir(parents=True, exist_ok=True)
LOCK = PROJECT / "macports.lock.json"
lock = json.loads(LOCK.read_text()) if LOCK.exists() else {}
done = set()


def version_key(s):
    return tuple(int(n) if n.isdigit() else n for n in re.split(r"(\d+)", s))


def install(name):
    if name in done:
        return
    done.add(name)
    if name not in lock:
        url = f"https://packages.macports.org/{name}/"
        with urllib.request.urlopen(url, timeout=45) as response:
            page = response.read().decode()
        names = set(re.findall(r'href="([^"]+\.darwin_23\.x86_64\.tbz2)"', page))
        if not names:
            names = set(re.findall(r'href="([^"]+\.any_any\.noarch\.tbz2)"', page))
        if not names:
            raise RuntimeError(f"No macOS 14 x86_64 package for {name}")
        filename = max(names, key=version_key)
        lock[name] = {"url": url + filename, "filename": filename}
    entry = lock[name]
    archive = CACHE / entry["filename"]
    print(f"Fetching {entry['filename']}", flush=True)
    download(entry["url"], archive, entry.get("sha256"))
    entry["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    metadata = subprocess.check_output(["tar", "-xOf", str(archive), "+CONTENTS"], text=True)
    entry["dependencies"] = [
        re.match(r"(.+)-[0-9][^-]*$", line.split(" ", 1)[1]).group(1)
        for line in metadata.splitlines() if line.startswith("@pkgdep ")
    ]
    LOCK.write_text(json.dumps(lock, indent=2) + "\n")
    for dependency in entry["dependencies"]:
        install(dependency)
    marker = BASE / ".packages" / entry["filename"]
    if not marker.exists():
        subprocess.run(["tar", "-xjf", str(archive), "-C", str(BASE),
                        "--strip-components=3", "opt/local"], check=True)
        marker.parent.mkdir(exist_ok=True)
        marker.touch()


def relocate():
    binaries = []
    for p in BASE.rglob("*"):
        if not p.is_file() or p.is_symlink():
            continue
        p.chmod(p.stat().st_mode | 0o200)
        with p.open("rb") as f:
            magic = f.read(4)
        if magic in MACHO_MAGICS:
            binaries.append(p)
        elif p.suffix in (".pc", ".la", ".cmake") or p.name.endswith("-config"):
            try:
                data = p.read_text()
            except UnicodeDecodeError:
                continue
            p.write_text(data.replace("/opt/local", str(BASE)))
    for p in binaries:
        deps = subprocess.check_output(["otool", "-L", str(p)], text=True)
        arguments = ["-id", "@rpath/" + p.name] if p.suffix == ".dylib" else []
        for line in deps.splitlines()[1:]:
            old = line.strip().split(" (", 1)[0]
            if old.startswith("/opt/local/"):
                new = BASE / old.removeprefix("/opt/local/")
                if not new.exists():
                    raise RuntimeError(f"Missing library {old} for {p}")
                arguments += ["-change", old, "@loader_path/" + os.path.relpath(new, p.parent)]
        if arguments:
            subprocess.run(["install_name_tool", *arguments, str(p)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            subprocess.run(["codesign", "--force", "--sign", "-", str(p)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    print(f"Relocated {len(binaries)} x86_64 binaries", flush=True)


for package in ("gnutls", "freetype", "libsdl2", "vulkan-loader", "libpcap"):
    install(package)
relocate()
