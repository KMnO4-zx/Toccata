"""Verify build revision metadata using disposable repositories, without builds."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RESOURCE = Path("apps/toccata-studio/Resources/build-info.json")


class BuildInfoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="toccata-build-info-test-")
        self.root = Path(self.temp.name) / "source"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/write-build-info.sh", self.root / "scripts")
        shutil.copy(ROOT / ".gitignore", self.root / ".gitignore")
        (self.root / "source.txt").write_text("committed source\n")
        self.env = os.environ.copy()
        self.env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args, cwd=None):
        return subprocess.run(["git", "-C", str(cwd or self.root), *args],
                              env=self.env, capture_output=True, text=True, check=True).stdout.strip()

    def initialize(self):
        self.git("init", "-q")
        self.git("config", "user.name", "Build metadata test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Initial source")
        return self.git("rev-parse", "HEAD")

    def metadata(self):
        subprocess.run(["bash", str(self.root / "scripts/write-build-info.sh")],
                       env=self.env, capture_output=True, text=True, check=True)
        return json.loads((self.root / RESOURCE).read_text())

    def test_clean_revision_is_exact_and_generated_resource_stays_ignored(self):
        commit = self.initialize()
        self.assertEqual(self.metadata(), {"commit": commit, "isDirty": False})
        first_modified = (self.root / RESOURCE).stat().st_mtime_ns
        self.assertEqual(self.metadata(), {"commit": commit, "isDirty": False})
        self.assertEqual((self.root / RESOURCE).stat().st_mtime_ns, first_modified)
        self.assertEqual((self.root / RESOURCE).stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("check-ignore", str(RESOURCE)), str(RESOURCE))

    def test_local_source_edits_and_staged_edits_are_dirty(self):
        commit = self.initialize()
        (self.root / "source.txt").write_text("local source\n")
        self.assertEqual(self.metadata(), {"commit": commit, "isDirty": True})
        self.git("add", "source.txt")
        self.assertEqual(self.metadata(), {"commit": commit, "isDirty": True})

    def test_untracked_source_is_dirty_but_build_outputs_are_not(self):
        commit = self.initialize()
        for folder in ["dist", "target", ".build"]:
            (self.root / folder).mkdir()
            (self.root / folder / "output").write_text("generated")
        self.assertEqual(self.metadata(), {"commit": commit, "isDirty": False})
        (self.root / "new-source.swift").write_text("// uncommitted source\n")
        self.assertEqual(self.metadata(), {"commit": commit, "isDirty": True})

    def test_new_commit_refreshes_metadata_and_clears_dirty_state(self):
        initial = self.initialize()
        (self.root / "source.txt").write_text("changed source\n")
        self.assertTrue(self.metadata()["isDirty"])
        self.git("add", "source.txt")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Changed source")
        current = self.git("rev-parse", "HEAD")
        self.assertNotEqual(initial, current)
        self.assertEqual(self.metadata(), {"commit": current, "isDirty": False})

    def test_source_archive_replaces_stale_metadata_with_unknown_revision(self):
        (self.root / RESOURCE).parent.mkdir(parents=True)
        (self.root / RESOURCE).write_text('{"commit":"stale","isDirty":true}')
        self.assertEqual(self.metadata(), {"commit": None, "isDirty": False})

    def test_source_archive_does_not_inherit_parent_repository_revision(self):
        parent = self.root.parent
        self.git("init", "-q", cwd=parent)
        self.git("config", "user.name", "Build metadata test", cwd=parent)
        self.git("config", "user.email", "test@example.invalid", cwd=parent)
        (parent / "parent.txt").write_text("unrelated repository\n")
        self.git("add", "parent.txt", cwd=parent)
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Parent source", cwd=parent)
        self.assertEqual(self.metadata(), {"commit": None, "isDirty": False})


if __name__ == "__main__":
    unittest.main()
