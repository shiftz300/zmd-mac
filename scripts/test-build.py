#!/usr/bin/env python3
"""Prove patches are actually applied inside a containing Git checkout."""
import subprocess
import tempfile
from pathlib import Path
from build_support import apply_git_patch, ensure_git_patch

with tempfile.TemporaryDirectory(prefix="zmd-nested-repository-") as temporary:
    root = Path(temporary)
    source = root / ".work/build/wine-src"
    source.mkdir(parents=True)
    file = source / "sample"
    file.write_text("before\n")
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    patch = root / "sample.patch"
    patch.write_text("diff --git a/sample b/sample\n--- a/sample\n+++ b/sample\n"
                     "@@ -1 +1 @@\n-before\n+after\n")
    apply_git_patch(patch, source)
    assert file.read_text() == "after\n", "Wine patch silently skipped"
    file.write_text("before\n")
    ensure_git_patch(patch, source)
    assert file.read_text() == "after\n", "Idempotent patch check skipped fresh source"
    ensure_git_patch(patch, source)
    assert file.read_text() == "after\n", "Idempotent patch check reversed the patch"
print("PASS: Wine patch is applied inside a containing Git checkout")
