#!/usr/bin/env python3
"""Build a pinned, optional x86_64 MoltenVK; never replace the stable library."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from bootstrap import PROJECT, ROOT, digest, download


def build(runtime, jobs):
    lockfile = PROJECT / "moltenvk-experimental.lock.json"
    lock = json.loads(lockfile.read_text())
    target = runtime / "renderers/moltenvk-experimental"
    if target.exists():
        raise SystemExit(f"Refusing to replace an installed experiment: {target}")
    for tool in ("cmake", "ninja", "clang", "codesign"):
        if not shutil.which(tool):
            raise SystemExit(f"Missing developer tool: {tool}")
    # The key covers sources, patches and this build recipe. A changed recipe
    # gets a fresh directory instead of applying patches twice to old sources.
    key = digest(lockfile)[:12] + "-" + digest(Path(__file__))[:12]
    work = ROOT / "build/moltenvk-experimental" / key
    work.mkdir(parents=True, exist_ok=True)
    cache = ROOT / "downloads/moltenvk-experimental"
    source = work / "moltenvk"
    if not (work / "prepared.json").exists():
        for name, entry in lock.items():
            if name == "cpm":
                continue
            archive = cache / (name + "-" + entry["commit"] + ".tar.gz")
            download(entry["url"], archive, entry["sha256"])
            directory = work / name
            if directory.exists():
                shutil.rmtree(directory)
            directory.mkdir()
            subprocess.run(["tar", "-xzf", str(archive), "-C", str(directory),
                            "--strip-components=1"], check=True)
        patches = work / "finewine/patches/moltenvk"
        records = []
        for directory, patchset in [(source, sorted(patches.glob("*.patch"))),
                                    (work / "spirv-cross", sorted((patches / "spirv-cross").glob("*.patch")))]:
            if not patchset:
                raise SystemExit("Pinned FineWine archive has no expected patches.")
            for patch in patchset:
                subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch)],
                               cwd=directory, check=True)
                records.append({"file": str(patch.relative_to(patches)), "sha256": digest(patch)})
        # Archive builds otherwise discover zmd-mac's containing Git checkout,
        # which gives an incorrect driver revision / pipeline-cache UUID.
        cmake = source / "MoltenVK/CMakeLists.txt"
        contents = cmake.read_text()
        marker = "\tconfigure_file("
        if contents.count(marker) != 1:
            raise SystemExit("Upstream revision-header recipe changed; review before building.")
        contents = contents.replace(marker, '\tset(MVK_GIT_REV "' + lock["moltenvk"]["commit"] + '")\n' + marker)
        cmake.write_text(contents)
        (work / "prepared.json").write_text(json.dumps(records, indent=2) + "\n")
    cpm = cache / "CPM_0.40.8.cmake"
    download(lock["cpm"]["url"], cpm, lock["cpm"]["sha256"])
    cpm_cache = work / "cpm/cpm"
    cpm_cache.mkdir(parents=True, exist_ok=True)
    shutil.copy2(cpm, cpm_cache / cpm.name)
    obj = work / "obj"
    environment = dict(os.environ, GIT_CEILING_DIRECTORIES=str(work),
                       CPM_SOURCE_CACHE=str(work / "cpm"))
    command = ["cmake", "-S", str(source), "-B", str(obj), "-G", "Ninja",
               "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=x86_64",
               "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", "-DMOLTEN_VK_WITH_CCACHE=OFF",
               "-DMVK_EXCLUDE_SPIRV_TOOLS=ON", "-DMVK_EXCLUDE_CEREAL=OFF",
               "-DCPM_SOURCE_CACHE=" + str(work / "cpm")]
    for name, package in [("spirv-cross", "SPIRV-Cross"), ("vulkan-headers", "Vulkan-Headers"), ("cereal", "cereal")]:
        command.append(f"-DCPM_{package}_SOURCE={work / name}")
    with (work / "build.log").open("w") as log:
        print(f"Building; log: {work / 'build.log'}", flush=True)
        subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(["cmake", "--build", str(obj), "--target", "MoltenVK", "-j", str(jobs)],
                       env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    library = obj / "MoltenVK/libMoltenVK.dylib"
    architecture = subprocess.check_output(["lipo", "-archs", str(library)], text=True).strip()
    if architecture != "x86_64":
        raise SystemExit(f"Wrong library architecture: {architecture}")
    dependencies = subprocess.check_output(["otool", "-L", str(library)], text=True)
    for line in dependencies.splitlines()[2:]:
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"Non-system runtime dependency: {dependency}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".moltenvk-", dir=target.parent) as temporary:
        stage = Path(temporary) / "renderer"
        stage.mkdir()
        installed = stage / "libMoltenVK.dylib"
        shutil.copy2(library, installed)
        subprocess.run(["install_name_tool", "-id", "@rpath/libMoltenVK.dylib", str(installed)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(installed)], check=True)
        subprocess.run(["codesign", "--verify", str(installed)], check=True)
        for name, path in [("MoltenVK", source / "LICENSE"),
                           ("SPIRV-Cross", work / "spirv-cross/LICENSE"),
                           ("cereal", work / "cereal/LICENSE")]:
            shutil.copy2(path, stage / ("LICENSE." + name))
        shutil.copy2(lockfile, stage / "sources.lock.json")
        record = {"version": "1.4.3-dev", "channel": "experimental",
                  "source_commit": lock["moltenvk"]["commit"],
                  "spirv_cross_commit": lock["spirv-cross"]["commit"],
                  "finewine_commit": lock["finewine"]["commit"],
                  "patches": json.loads((work / "prepared.json").read_text()),
                  "library_sha256": digest(installed), "build_recipe_sha256": digest(Path(__file__)),
                  "architecture": architecture, "configuration": "Release",
                  "spirv_tools": False, "pipeline_cache": True,
                  "verification": "build and signature only; gameplay/performance not verified"}
        (stage / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
        stage.rename(target)
    print(f"Installed optional experiment: {target}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=ROOT / "runtime")
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    build(args.runtime.expanduser().resolve(), args.jobs)
