#!/usr/bin/env python3
"""Apply the opt-in Dock/session patch after the fixed FineWine patch series."""
import json
from bootstrap import ROOT, PROJECT, digest
from build_support import ensure_git_patch

patch = PROJECT / "scripts/patches/wine-session-dock.patch"
expected = "39e6e744c238949ebecaa9ba661502c1eeae5cf9f8656dc06ffa268c4486daa9"
if digest(patch) != expected:
    raise SystemExit("Wine session patch checksum mismatch.")
source = ROOT / "build/wine-src"
stamp = ROOT / "build/source-patches.json"
record = json.loads(stamp.read_text())
ensure_git_patch(patch, source)
record["local_patches"] = [{"path": "scripts/patches/" + patch.name, "sha256": expected}]
stamp.write_text(json.dumps(record, indent=2) + "\n")
print("Verified opt-in Wine Dock/session patch.")
