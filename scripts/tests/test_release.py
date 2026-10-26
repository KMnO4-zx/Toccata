"""Exercise release guards without network access, tags, or real GitHub writes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHA = "a" * 40


class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="toccata-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for folder in ["scripts", "shared", "docs/releases", "dist", "bin"]:
            (self.root / folder).mkdir(parents=True)
        shutil.copy(ROOT / "scripts/create-github-release.sh", self.root / "scripts")
        (self.root / "shared/app-version.json").write_text('{"version":"0.0.1","build":"4"}')
        (self.root / "docs/releases/v0.0.1.md").write_text("Release notes\n")
        dmg = self.root / "dist/Toccata-0.0.1-arm64.dmg"
        dmg.write_bytes(b"fixture package")
        self.checksum = self.root / f"dist/{dmg.name}.sha256"
        self.checksum.write_text(f"{hashlib.sha256(dmg.read_bytes()).hexdigest()}  {dmg.name}\n")
        self.log = self.root / "gh-calls.jsonl"
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        GH_REPO="fixture/repo", RELEASE_TAG="v0.0.1", RELEASE_MODE="draft",
                        RELEASE_COMMIT=SHA, TEST_GH_LOG=str(self.log), TEST_GH_BEHAVIOR="")
        self.tool("git", f"#!/bin/sh\nprintf '%s\\n' '{SHA}'\n")
        self.tool("gh", '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["TEST_GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
behavior = os.environ["TEST_GH_BEHAVIOR"]
if args[0] == "api":
    if behavior == "api-fails": sys.exit(1)
    if behavior == "existing-release" and "releases?" in args[2]: print("v0.0.1")
    if behavior == "existing-tag" and "matching-refs" in args[2]: print("refs/tags/v0.0.1")
if args[:2] == ["release", "create"] and behavior == "upload-fails": sys.exit(1)
''')

    def tool(self, name, content):
        path = self.root / "bin" / name
        path.write_text(content)
        path.chmod(0o755)

    def run_release(self, **changes):
        result = subprocess.run(["bash", str(self.root / "scripts/create-github-release.sh")],
                                env=dict(self.env, **changes), capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_draft_uploads_exact_package_without_publishing(self):
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in calls if c[:2] == ["release", "create"])
        self.assertIn("--draft", create)
        self.assertIn("dist/Toccata-0.0.1-arm64.dmg", create)
        self.assertIn("dist/Toccata-0.0.1-arm64.dmg.sha256", create)
        self.assertIn(SHA, create)
        self.assertFalse(any(c[:2] == ["release", "edit"] for c in calls))

    def test_explicit_publish_happens_only_after_draft_upload(self):
        result, calls = self.run_release(RELEASE_MODE="publish")
        self.assertEqual(result.returncode, 0, result.stderr)
        mutations = [c for c in calls if c[:2] in [["release", "create"], ["release", "edit"]]]
        self.assertEqual([c[1] for c in mutations], ["create", "edit"])
        self.assertIn("--draft", mutations[0])
        self.assertIn("--draft=false", mutations[1])
        self.assertIn("--latest", mutations[1])

    def test_invalid_or_missing_intent_stops_before_network(self):
        for change in [{"RELEASE_MODE": ""}, {"RELEASE_MODE": "yes"}, {"RELEASE_TAG": "v0.2.0"},
                       {"RELEASE_COMMIT": "b" * 40}, {"RELEASE_TAG": "$(touch injected)"}]:
            with self.subTest(change=change):
                result, calls = self.run_release(**change)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])
                self.assertFalse((self.root / "injected").exists())

    def test_corrupt_checksum_stops_before_network(self):
        self.checksum.write_text("0" * 64 + "  Toccata-0.0.1-arm64.dmg\n")
        result, calls = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_existing_release_tag_or_api_failure_never_mutates(self):
        for behavior in ["existing-release", "existing-tag", "api-fails"]:
            with self.subTest(behavior=behavior):
                if self.log.exists(): self.log.unlink()
                result, calls = self.run_release(TEST_GH_BEHAVIOR=behavior, RELEASE_MODE="publish")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[0] == "release" for c in calls))

    def test_upload_failure_never_publishes(self):
        result, calls = self.run_release(TEST_GH_BEHAVIOR="upload-fails", RELEASE_MODE="publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ["release", "edit"] for c in calls))


if __name__ == "__main__":
    unittest.main()
