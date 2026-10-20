#!/usr/bin/env python3
"""Fetch isolated build dependencies. Does not run brew install or modify /opt."""
import concurrent.futures
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("ZMD_WORK_DIR", PROJECT)).expanduser().resolve()
CACHE = ROOT / "downloads"
CACHE.mkdir(parents=True, exist_ok=True)
LOCK = PROJECT / "dependencies.lock.json"
lock = json.loads(LOCK.read_text()) if LOCK.exists() else {}


def request(url):
    return urllib.request.Request(url, headers={"User-Agent": "zmd-mac-build"})


def json_url(url):
    with urllib.request.urlopen(request(url), timeout=60) as response:
        return json.load(response)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def download(url, target, sha256=None, headers=None):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and (sha256 is None or digest(target) == sha256):
        return
    temporary = target.with_suffix(target.suffix + ".part")
    cmd = ["curl", "-fLsS", "--proto", "=https", "--proto-redir", "=https",
           "--retry", "3", "--connect-timeout", "30"]
    for key, value in (headers or {}).items():
        cmd += ["-H", f"{key}: {value}"]
    subprocess.run(cmd + ["-o", str(temporary), url], check=True)
    if sha256 and digest(temporary) != sha256:
        raise RuntimeError(f"Checksum mismatch: {target.name}")
    temporary.replace(target)


def resolve_bottles(name, arch):
    key = f"{arch}/{name}"
    if key in lock:
        entry = lock[key]
    else:
        formula = json_url(f"https://formulae.brew.sh/api/formula/{name}.json")
        files = formula["bottle"]["stable"]["files"]
        candidates = (
            ["arm64_golden_gate", "arm64_tahoe", "arm64_sequoia", "arm64_sonoma", "all"]
            if arch == "native" else ["golden_gate", "tahoe", "sequoia", "sonoma", "ventura", "monterey", "all"]
        )
        tag = next((tag for tag in candidates if tag in files), None)
        if tag is None:
            raise RuntimeError(f"No suitable {arch} bottle for {name}")
        entry = {
            "name": formula["name"], "version": formula["versions"]["stable"],
            "tag": tag, "dependencies": formula["dependencies"],
            **files[tag],
        }
        lock[key] = entry
        LOCK.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + "\n")
    for dependency in entry["dependencies"]:
        resolve_bottles(dependency, arch)


def fetch_bottle(item):
    key, entry = item
    arch, _ = key.split("/", 1)
    base = ROOT / "tools" / arch
    cellar = base / "Cellar"
    opt = base / "opt" / entry["name"]
    if opt.exists():
        return
    print(f"Fetching {key} {entry['version']}", flush=True)
    filename = entry["name"].replace("@", "-") + "-" + entry["sha256"][:16] + ".tar.gz"
    archive = CACHE / filename
    name = entry["name"].replace("@", "/")
    token = json_url(
        "https://ghcr.io/token?service=ghcr.io&scope="
        + urllib.parse.quote(f"repository:homebrew/core/{name}:pull", safe="")
    )["token"]
    download(entry["url"], archive, entry["sha256"], {"Authorization": f"Bearer {token}"})
    cellar.mkdir(parents=True, exist_ok=True)
    subprocess.run(["tar", "-xzf", str(archive), "-C", str(cellar)], check=True)
    versions = [p for p in (cellar / entry["name"]).iterdir() if p.is_dir()]
    if len(versions) != 1:
        raise RuntimeError(f"Ambiguous package root: {entry['name']}")
    opt.parent.mkdir(parents=True, exist_ok=True)
    opt.symlink_to(os.path.relpath(versions[0], opt.parent))


MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
    b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca",
}


def relocate(arch):
    base = ROOT / "tools" / arch
    lib = base / "lib"
    lib.mkdir(exist_ok=True)
    for package in (base / "opt").iterdir():
        package_lib = package / "lib"
        if package_lib.is_dir():
            for p in package_lib.rglob("*.dylib"):
                target = lib / p.name
                if not target.exists():
                    target.symlink_to(os.path.relpath(p, lib))
    binaries = []
    for p in (base / "Cellar").rglob("*"):
        if not p.is_file() or p.is_symlink():
            continue
        p.chmod(p.stat().st_mode | 0o200)
        with p.open("rb") as f:
            magic = f.read(4)
        if magic in MACHO_MAGICS:
            binaries.append(p)
        elif p.suffix in (".o", ".a"):
            # Homebrew replaces paths even inside COFF debug records when bottling.
            # Restore their original byte lengths so symbol/archive offsets stay valid.
            data = p.read_bytes()
            restored = data.replace(b"@@HOMEBREW_CELLAR@@", b"/opt/homebrew/Cellar")
            restored = restored.replace(b"@@HOMEBREW_PREFIX@@", b"/opt/homebrew")
            if restored != data:
                p.write_bytes(restored)
        elif p.suffix in (".pc", ".la", ".cmake") or p.name.endswith("-config"):
            try:
                data = p.read_text()
            except UnicodeDecodeError:
                continue
            for old in ("@@HOMEBREW_CELLAR@@", "/opt/homebrew/Cellar", "/usr/local/Cellar"):
                data = data.replace(old, str(base / "Cellar"))
            for old in ("@@HOMEBREW_PREFIX@@", "/opt/homebrew", "/usr/local"):
                data = data.replace(old, str(base))
            p.write_text(data)
    for p in binaries:
        deps = subprocess.check_output(["otool", "-L", str(p)], text=True)
        arguments = []
        for line in deps.splitlines()[1:]:
            old = line.strip().split(" (", 1)[0]
            if any(x in old for x in ("HOMEBREW", "/opt/homebrew/", "/usr/local/")):
                name = Path(old).name
                if not (lib / name).exists():
                    # Some compiler-private libraries live outside the top-level lib directory.
                    matches = list((base / "Cellar").rglob(name))
                    if not matches:
                        raise RuntimeError(f"Missing dependency {old} for {p}")
                    (lib / name).symlink_to(os.path.relpath(matches[0], lib))
                arguments += ["-change", old, "@rpath/" + name]
        rpath = "@loader_path/" + os.path.relpath(lib, p.parent)
        load_commands = subprocess.check_output(["otool", "-l", str(p)], text=True)
        if rpath not in load_commands:
            arguments += ["-add_rpath", rpath]
        if arguments:
            subprocess.run(["install_name_tool", *arguments, str(p)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            subprocess.run(["codesign", "--force", "--sign", "-", str(p)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    print(f"Relocated {len(binaries)} {arch} binaries", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=("sevenzip",))
    args = parser.parse_args()
    packages = ("sevenzip",) if args.only else ("bison", "mingw-w64", "sevenzip", "pkgconf")
    for package in packages:
        resolve_bottles(package, "native")
    LOCK.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + "\n")
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(fetch_bottle, ((k, v) for k, v in lock.items()
                                    if k.startswith("native/") and
                                    (not args.only or v["name"] == args.only))))
    relocate("native")


if __name__ == "__main__":
    main()
