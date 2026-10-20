#!/usr/bin/env python3
"""Rebuild DXMT 0.80 NGX and NVAPI for MetalFX, in a separate backend."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from bootstrap import PROJECT, ROOT, digest, download

SOURCE_URL = "https://codeload.github.com/3Shain/dxmt/tar.gz/refs/tags/v0.80"
SOURCE_SHA = "79cd3a2b32749fc3890b6c2a9337f45de26fdb750014f3457bb7ebafa679492d"
PATCH_COMMIT = "50102f994b406f58f56d5d09f2ad20f9b90390a2"
PATCH_SHA = "b77aad68fa862f57a43f192d8a80743c5439d633a979b3704dabe6fd31ee9a8f"
NVAPI_COMMIT = "d08488fcc82eef313b0464db37d2955709691e94"
NVAPI_URL = f"https://codeload.github.com/NVIDIA/nvapi/tar.gz/{NVAPI_COMMIT}"
NVAPI_SHA = "436936c965f711f743c8606cb7c2621736cecf41e0fd6557555b2f1903b0350f"
NVAPI_PATCH_SHA = "83b67c1b2074a2918314dc6cbbb1635b52f6c6995343b9ce2bf0a088621d334a"


def ngx_exports(objdump, dll):
    output = subprocess.check_output([str(objdump), "-p", str(dll)], text=True)
    return set(re.findall(r"\bNVSDK_NGX_[A-Za-z0-9_]+", output))


def build(runtime):
    base = runtime / "renderers/dxmt"
    original = base / "x86_64-windows/nvngx.dll"
    patch = PROJECT / "scripts/patches/dxmt-235-ngx-resource-pointer.patch"
    nvapi_patch = PROJECT / "scripts/patches/dxmt-nvapi-logical-gpu.patch"
    compiler = ROOT / "tools/native/opt/mingw-w64/bin/x86_64-w64-mingw32-g++"
    objdump = compiler.with_name("x86_64-w64-mingw32-objdump")
    winebuild = ROOT / "build/wine/tools/winebuild/winebuild"
    for path in (original, compiler, objdump, winebuild):
        if not path.is_file():
            raise SystemExit(f"Missing build input: {path}")
    if digest(patch) != PATCH_SHA:
        raise SystemExit("NGX patch checksum mismatch.")
    if digest(nvapi_patch) != NVAPI_PATCH_SHA:
        raise SystemExit("NVAPI patch checksum mismatch.")
    provenance = json.loads((runtime / "provenance.json").read_text())
    if provenance["dxmt"]["version"] != "0.80":
        raise SystemExit("This backport is only built against DXMT 0.80.")
    archive = ROOT / "downloads/license-sources/dxmt-v0.80-source.tar.gz"
    download(SOURCE_URL, archive, SOURCE_SHA)
    nvapi_archive = ROOT / f"downloads/license-sources/nvapi-{NVAPI_COMMIT}.tar.gz"
    download(NVAPI_URL, nvapi_archive, NVAPI_SHA)
    work = ROOT / "build/dxmt-metalfx"
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="build-", dir=work) as directory:
        stage = Path(directory)
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(stage)], check=True)
        source = stage / "dxmt-0.80"
        subprocess.run(["tar", "-xzf", str(nvapi_archive), "-C", str(stage)], check=True)
        subprocess.run(["patch", "-p1", "--batch", "--fuzz=0", "-i", str(patch)],
                       cwd=source, check=True)
        subprocess.run(["patch", "-p1", "--batch", "--fuzz=0", "-i", str(nvapi_patch)],
                       cwd=source, check=True)
        dll = stage / "nvngx.dll"
        # Rendering/shader conversion stays in the base DXMT; only its NGX
        # bridge and NVAPI capability discovery are rebuilt.
        # -include iomanip supplies an upstream transitive-header omission with
        # modern GCC. Static libstdc++/libgcc avoid adding runtime dependencies.
        command = [
            str(compiler), "-std=c++20", "-O2", "-DNDEBUG", "-DNOMINMAX",
            "-D_WIN32_WINNT=0xa00", "-DDXMT_PAGE_SIZE=4096", "-include", "iomanip",
            "-fmacro-prefix-map=" + str(source) + "=dxmt-0.80",
            "-shared", "-static", "-s", "-Wl,--file-alignment=4096",
            "-Wl,--no-insert-timestamp", "-o", str(dll),
        ]
        command += ["-I" + str(source / p) for p in
                    ("include", "libs", "src/util", "src/dxgi", "src/winemetal")]
        command += [str(source / "src" / p) for p in (
            "nvngx/nvngx.cpp", "util/log/log.cpp", "util/util_env.cpp",
            "util/util_string.cpp", "util/thread.cpp", "util/com/com_guid.cpp",
        )]
        command += ["-ldxgi", "-luuid"]
        subprocess.run(command, check=True)
        subprocess.run([str(winebuild), "--builtin", str(dll)], check=True)
        expected = ngx_exports(objdump, original)
        if not expected or ngx_exports(objdump, dll) != expected:
            raise SystemExit("The rebuilt NGX API exports do not match DXMT 0.80.")
        nvapi_dll = stage / "nvapi64.dll"
        # Reuse the compiler flags/includes, replacing only the module sources.
        nvapi_command = command[:command.index("-o")] + ["-o", str(nvapi_dll)]
        nvapi_command += ["-include", "format"]
        nvapi_command += ["-I" + str(source / p) for p in
                         ("include", "libs", "src/util", "src/dxgi", "src/winemetal")]
        nvapi_command += ["-I" + str(stage / f"nvapi-{NVAPI_COMMIT}")]
        nvapi_command += [str(source / "src" / p) for p in (
            "nvapi/nvapi.cpp", "nvapi/nvapi64.def", "util/log/log.cpp",
            "util/util_env.cpp", "util/util_string.cpp", "util/thread.cpp",
            "util/com/com_guid.cpp", "util/wsi_monitor_win32.cpp",
        )]
        nvapi_command += [str(base / "x86_64-windows/winemetal.dll"), "-ldxgi", "-luuid"]
        subprocess.run(nvapi_command, check=True)
        subprocess.run([str(winebuild), "--builtin", str(nvapi_dll)], check=True)
        if not re.search(r"\bnvapi_QueryInterface\b", subprocess.check_output(
                [str(objdump), "-p", str(nvapi_dll)], text=True)):
            raise SystemExit("The rebuilt NVAPI DLL has no query interface.")
        record = {
            "version": "0.80+ngx235+nvapi-logical-gpu", "base_version": "0.80",
            "source_url": SOURCE_URL, "source_sha256": SOURCE_SHA,
            "patch_commit": PATCH_COMMIT, "patch_sha256": PATCH_SHA,
            "module": "x86_64-windows/nvngx.dll", "module_sha256": digest(dll),
            "nvapi_module": "x86_64-windows/nvapi64.dll",
            "nvapi_module_sha256": digest(nvapi_dll),
            "nvapi_headers_commit": NVAPI_COMMIT, "nvapi_headers_url": NVAPI_URL,
            "nvapi_headers_sha256": NVAPI_SHA, "nvapi_patch_sha256": NVAPI_PATCH_SHA,
            "compiler": subprocess.check_output([str(compiler), "-dumpfullversion"],
                                                text=True).strip(),
            "license": "MIT base; LGPL-2.1-or-later NGX backport",
            "upscaler": "MetalFX Temporal via NGX/DLSS", "nvext": True,
        }
        target = runtime / "renderers/dxmt-metalfx"
        if target.exists():
            existing = target / "provenance.json"
            if not existing.is_file() or json.loads(existing.read_text()) != record:
                raise SystemExit(f"A different MetalFX backend exists; preserve it before rebuilding: {target}")
            if (digest(target / record["module"]) != record["module_sha256"] or
                    digest(target / record["nvapi_module"]) != record["nvapi_module_sha256"]):
                raise SystemExit("Installed MetalFX module checksum mismatch.")
            print(f"Verified existing backend: {target}")
            return
        # Publish only after compilation and export validation; the source DXMT
        # and Vulkan directories are never overwritten.
        candidate = stage / "backend"
        shutil.copytree(base, candidate, symlinks=True)
        shutil.copy2(dll, candidate / record["module"])
        shutil.copy2(nvapi_dll, candidate / record["nvapi_module"])
        shutil.copy2(patch, candidate / patch.name)
        shutil.copy2(nvapi_patch, candidate / nvapi_patch.name)
        for license_file in ("DXMT-0.80.txt", "DXMT-NGX-patch.txt", "Wine-LGPL-2.1.txt", "NVAPI-headers.txt"):
            shutil.copy2(PROJECT / "licenses" / license_file, candidate / license_file)
        (candidate / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
        candidate.rename(target)
        print(f"Built MetalFX backend: {target}\nNGX SHA-256: {record['module_sha256']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=ROOT / "runtime")
    build(parser.parse_args().runtime.resolve())
