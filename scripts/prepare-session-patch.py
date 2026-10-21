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
display_patch = PROJECT / "scripts/patches/wine-display-monitors.patch"
display_hash = "ce42fd397f03533a5e70c4599fa91ae6d10ccc4c86bbc4cc04fa61bd472ac379"
if digest(display_patch) != display_hash:
    raise SystemExit("Wine display patch checksum mismatch.")
ensure_git_patch(display_patch, source)
record["local_patches"].append({"path": "scripts/patches/" + display_patch.name, "sha256": display_hash})
stamp.write_text(json.dumps(record, indent=2) + "\n")
print("Verified opt-in Wine Dock/session patch.")
