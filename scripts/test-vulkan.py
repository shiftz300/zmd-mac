#!/usr/bin/env python3
"""Check both MoltenVK versions and queue modes in a disposable Wine prefix."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from bootstrap import PROJECT, ROOT

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime", type=Path, default=ROOT / "runtime")
runtime = parser.parse_args().runtime.resolve()
build = ROOT / "build/vulkan-tests"
build.mkdir(parents=True, exist_ok=True)
compiler = ROOT / "tools/native/opt/mingw-w64/bin/x86_64-w64-mingw32-gcc"
fixture = build / "vulkan-check.exe"
subprocess.run([str(compiler), "-O2", "-static", "-I" + str(ROOT / "build/wine-src/include/wine"),
                str(PROJECT / "scripts/vulkan-check.c"), "-luser32", "-o", str(fixture)], check=True)
results = []
with tempfile.TemporaryDirectory(prefix="prefix-", dir=build) as temporary:
    support = Path(temporary)
    (support / "scripts").mkdir()
    shutil.copy2(PROJECT / "scripts/wine.sh", support / "scripts/wine.sh")
    (support / "runtime").symlink_to(runtime, target_is_directory=True)
    environment = {**os.environ, "WINEPREFIX": str(support / "prefix"),
                   "ZMD_PREFIX": str(support / "prefix"), "ZMD_RENDERER": "vulkan",
                   "MTL_HUD_ENABLED": "0", "MTL_DEBUG_LAYER": "0", "MTL_SHADER_VALIDATION": "0"}
    environment.pop("ZMD_SESSION_ID", None)
    try:
        for channel in ("stable", "experimental"):
            directory = "moltenvk" if channel == "stable" else "moltenvk-experimental"
            provenance = json.loads((runtime / "renderers" / directory / "provenance.json").read_text())
            for mode in ("default", "async"):
                (support / "moltenvk.conf").write_text(channel + "\n")
                (support / "vulkan-queue.conf").write_text(mode + "\n")
                logpath = build / (channel + "-" + mode + ".log")
                with logpath.open("w") as log:
                    result = subprocess.run(["bash", str(support / "scripts/wine.sh"), str(fixture)],
                                            env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=90)
                text = logpath.read_text(errors="replace")
                if result.returncode or "Windowed surface, GPU clear and present: PASS" not in text:
                    raise SystemExit(f"FAIL {channel}/{mode}; see {logpath}")
                subprocess.run([str(runtime / "wine/bin/wineserver"), "-w"], env=environment, check=True, timeout=30)
                results.append({"channel": channel, "queue": mode, "library_sha256": provenance["library_sha256"],
                                "result": "window, GPU clear, presentation, idle and teardown passed"})
                print(f"PASS: {channel}/{mode}", flush=True)
    finally:
        # Only the temporary test prefix. Never terminate an installed game.
        subprocess.run([str(runtime / "wine/bin/wineserver"), "-k"], env=environment)
        subprocess.run([str(runtime / "wine/bin/wineserver"), "-w"], env=environment, timeout=30)
(build / "results.json").write_text(json.dumps(results, indent=2) + "\n")
print("These checks do not validate Endfield, FSR, frame generation or performance.")
