#!/usr/bin/env python3
"""Validate monitor handles and invisible-window mapping in an isolated prefix."""
from pathlib import Path
import os
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
build = root / "build/display-tests"
build.mkdir(parents=True, exist_ok=True)
subprocess.run([str(root / "tools/native/opt/mingw-w64/bin/x86_64-w64-mingw32-gcc"),
                "-O2", "-static", str(root / "Tests/display-monitor.c"), "-luser32",
                "-o", str(build / "probe.exe")], check=True)
with tempfile.TemporaryDirectory(prefix="prefix-", dir=build) as temporary:
    env = dict(os.environ, ZMD_PREFIX=temporary, WINEDEBUG="-all,err+all")
    subprocess.run(["bash", str(root / "scripts/wine.sh"), str(build / "probe.exe")],
                   env=env, check=True, timeout=120)
    subprocess.run([str(root / "runtime/wine/bin/wineserver"), "-w"],
                   env=dict(env, WINEPREFIX=temporary), check=True, timeout=20)
print("PASS: nonzero monitor handles and per-screen window mapping; game fullscreen requires manual acceptance")
