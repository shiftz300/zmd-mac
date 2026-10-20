#!/usr/bin/env python3
"""Inspect PKG contents and evaluated choices without installing on the host."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

package = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="zmd-pkg-test-") as temporary:
    root = Path(temporary)
    expanded = root / "expanded"
    subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True)
    distribution = ET.parse(expanded / "Distribution").getroot()
    assert distribution.find("options").get("customize") == "always"
    choices = {c.get("id"): c for c in distribution.findall("choice")}
    assert set(choices) == {"runtime", "cn", "global"}
    assert choices["cn"].get("start_selected") == "true"
    assert choices["global"].get("start_selected") == "false"
    assert choices["runtime"].get("selected") == "true"
    for region in ("cn", "global"):
        component = expanded / (region + ".pkg")
        info = ET.parse(component / "PackageInfo").getroot()
        post = info.find("scripts/postinstall")
        assert post is not None and post.get("timeout") == "1800", ET.tostring(info)
        script = component / "Scripts" / post.get("file")
        text = script.read_text()
        assert "zmd_as_user" in text and "install --region " + region + " --desktop" in text
        helper = (component / "Scripts/pkg-user.sh").read_text()
        assert "launchctl asuser" in helper and "sudo -H -u" in helper and "env -i" in helper
        subprocess.run(["bash", "-n", str(script)], check=True)
    payload = expanded / "runtime.pkg/Payload/payload"
    manifest = json.loads((payload / "manifest.json").read_text())
    for name, expected in manifest["files"].items():
        assert not name.endswith(".py") and "prefix" not in Path(name).parts, name
        assert hashlib.sha256((payload / name).read_bytes()).hexdigest() == expected, name
    print("PASS: native choices, user-context scripts, 30 minute timeout and payload hashes")
    for cn, global_ in ((1, 0), (0, 1), (1, 1)):
        changes = root / "choices.plist"
        changes.write_bytes(plistlib.dumps([
            {"choiceIdentifier": "cn", "choiceAttribute": "selected", "attributeSetting": cn},
            {"choiceIdentifier": "global", "choiceAttribute": "selected", "attributeSetting": global_},
        ]))
        result = subprocess.check_output(["/usr/sbin/installer", "-pkg", str(package), "-target", "/",
            "-showChoicesAfterApplyingChangesXML", str(changes)])
        values = {item["choiceIdentifier"]: item["attributeSetting"] for item in plistlib.loads(result)
                  if item["choiceAttribute"] == "selected"}
        assert bool(values["cn"]) == bool(cn) and bool(values["global"]) == bool(global_), values
        assert values["runtime"], values
    print("PASS: Installer evaluates CN-only, global-only and both; shared runtime stays selected")
