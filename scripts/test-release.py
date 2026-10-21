#!/usr/bin/env python3
"""Exercise release failure boundaries without contacting GitHub."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-release.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zmd-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        for name in publisher.ASSETS:
            (self.directory / name).write_bytes(b"fixture")
        with zipfile.ZipFile(self.directory / "zmd-mac-macos-arm64.zip", "w") as archive:
            archive.writestr("zmd-mac/payload/AppTemplate.app/Contents/Info.plist",
                             plistlib.dumps({"CFBundleShortVersionString": "0.5.0"}))
        for name in publisher.ASSETS:
            digest = hashlib.sha256((self.directory / name).read_bytes()).hexdigest()
            (self.directory / (name + ".sha256")).write_text(digest + "  " + name + "\n")

    def test_preflight(self):
        self.assertEqual([p.name for p in publisher.verify("v0.5.0", self.directory)[0]],
                         ["zmd-mac-macos-arm64.pkg", "zmd-mac-macos-arm64.zip", "third-party-sources.tar.gz"])
        self.assertTrue(publisher.verify("v0.5.0-rc.1", self.directory)[1])
        for tag in ("main", "v0.6.0", "v0.5.0;echo"):
            with self.assertRaises(ValueError):
                publisher.verify(tag, self.directory)
        (self.directory / publisher.ASSETS[0]).write_bytes(b"corrupt")
        with self.assertRaises(ValueError):
            publisher.verify("v0.5.0", self.directory)
        (self.directory / publisher.ASSETS[0]).unlink()
        with self.assertRaises(ValueError):
            publisher.verify("v0.5.0", self.directory)

    def simulate(self, *, existing=None, fail_upload=False, incomplete=False, tag="v0.5.0"):
        commands = []
        def run(command, **kwargs):
            commands.append(command)
            if command[2] == "view":
                return subprocess.CompletedProcess(command, 1 if existing is None else 0,
                                                    stdout=json.dumps(existing))
            if command[2] == "upload" and fail_upload:
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)
        files = publisher.verify(tag, self.directory)[0]
        assets = [{"name": file.name, "size": file.stat().st_size} for file in files]
        if incomplete:
            assets.pop()
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_SHA": "abc123"}), \
             patch.object(publisher.subprocess, "run", side_effect=run), \
             patch.object(publisher.subprocess, "check_output", return_value=json.dumps({"assets": assets})):
            error = None
            try:
                publisher.publish(tag, self.directory)
            except (ValueError, subprocess.CalledProcessError) as caught:
                error = caught
        return commands, error

    def test_publish_and_resume(self):
        commands, error = self.simulate(tag="v0.5.0-rc.1")
        self.assertIsNone(error)
        self.assertIn("--draft", commands[1])
        self.assertIn("--latest=false", commands[-1])
        self.assertIn("--prerelease=true", commands[-1])
        upload = next(command for command in commands if command[2] == "upload")
        self.assertFalse(any(item.endswith(".sha256") or item.endswith("zmd-mac-source.zip") for item in upload))
        commands, error = self.simulate(existing={"isDraft": True, "targetCommitish": "abc123"})
        self.assertIsNone(error)
        self.assertNotIn("create", [command[2] for command in commands])
        self.assertEqual(commands[-1][2], "edit")

    def test_failures_never_publish(self):
        for options in ({"fail_upload": True}, {"incomplete": True},
                        {"existing": {"isDraft": False, "targetCommitish": "abc123"}},
                        {"existing": {"isDraft": True, "targetCommitish": "another"}}):
            commands, error = self.simulate(**options)
            self.assertIsNotNone(error)
            self.assertNotIn("edit", [command[2] for command in commands])


unittest.main()
