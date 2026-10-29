"""Exercise the real replacement/rollback script with disposable app folders.

Only codesign and Launch Services are replaced in the test copy. No installed
application is replaced, launched, or terminated by these tests.
"""
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apps/toccata-studio/Resources/install-update.sh"


@unittest.skipUnless(sys.platform == "darwin", "macOS installer")
class UpdateInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="update test ' 中文 ")
        self.root = Path(self.temp.name)
        self.target = self.root / "Toccata.app"
        self.staged = self.root / ".Toccata-update-test.app"
        self.backup = self.root / ".Toccata-backup-test.app"
        self.work = self.root / "work"
        self.work.mkdir()
        self.app(self.target, "0.1.1", "original")
        self.app(self.staged, "0.2.0", "replacement")
        stat = self.target.stat()
        self.identity = f"{stat.st_dev}:{stat.st_ino}"
        self.parent = subprocess.Popen(["/bin/sleep", "30"])
        self.process = None
        self.environment = dict(os.environ, UPDATE_TEST_ROOT=str(self.root), UPDATE_TEST_STAGED=str(self.staged))
        self.signer = self.stub("signer", 'test "${UPDATE_TEST_BAD_SIGNATURE:-0}" != 1\n')
        self.launcher = self.stub("launcher", '''
printf '%s\\n' "$@" >> "$UPDATE_TEST_ROOT/launched.txt"
case "$*" in *--update-failed*) exit 0 ;; esac
test "${UPDATE_TEST_LAUNCH_FAILURE:-0}" != 1
''')
        self.mover = self.stub("mover", '''
if [ "${UPDATE_TEST_MOVE_FAILURE:-0}" = 1 ] && [ "$1" = "$UPDATE_TEST_STAGED" ]; then exit 1; fi
exec /bin/mv "$@"
''')
        self.script = self.root / "install.sh"
        self.script.write_text(SOURCE.read_text().replace("/usr/bin/codesign", shlex.quote(str(self.signer)))
                               .replace("/usr/bin/open", shlex.quote(str(self.launcher)))
                               .replace("/bin/mv", shlex.quote(str(self.mover))))

    def tearDown(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        if self.parent.poll() is None:
            self.parent.terminate()
        self.parent.wait(timeout=5)
        self.temp.cleanup()

    def stub(self, name, body):
        path = self.root / name
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o700)
        return path

    def app(self, path, version, marker):
        (path / "Contents").mkdir(parents=True)
        with (path / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.toccata.studio", "CFBundleShortVersionString": version}, stream)
        (path / "marker").write_text(marker)

    def start(self):
        self.process = subprocess.Popen(["/bin/sh", str(self.script), str(self.parent.pid), str(self.target),
                                         str(self.staged), str(self.backup), str(self.work), self.identity, "0.2.0"],
                                        env=self.environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def ready(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if (self.work / "ready").exists():
                return
            if self.process.poll() is not None:
                break
            time.sleep(0.01)
        self.fail("Installer did not become ready")

    def finish(self):
        self.parent.terminate()
        self.parent.wait(timeout=5)
        return self.process.wait(timeout=5)

    def test_waits_for_parent_and_preserves_backup_until_new_app_starts(self):
        self.start()
        self.ready()
        self.assertEqual((self.target / "marker").read_text(), "original")
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.finish(), 0)
        self.assertEqual((self.target / "marker").read_text(), "replacement")
        self.assertEqual((self.backup / "marker").read_text(), "original")
        self.assertIn("--toccata-updated\n" + str(self.work), (self.root / "launched.txt").read_text())

    def test_failed_move_restores_old_app(self):
        self.environment["UPDATE_TEST_MOVE_FAILURE"] = "1"
        self.start()
        self.ready()
        self.assertNotEqual(self.finish(), 0)
        self.assertEqual((self.target / "marker").read_text(), "original")
        self.assertEqual((self.staged / "marker").read_text(), "replacement")
        self.assertIn("--update-failed", (self.root / "launched.txt").read_text())

    def test_failed_relaunch_restores_old_app(self):
        self.environment["UPDATE_TEST_LAUNCH_FAILURE"] = "1"
        self.start()
        self.ready()
        self.assertNotEqual(self.finish(), 0)
        self.assertEqual((self.target / "marker").read_text(), "original")
        self.assertFalse(self.backup.exists())

    def test_rejects_invalid_signature_before_app_quits(self):
        self.environment["UPDATE_TEST_BAD_SIGNATURE"] = "1"
        self.start()
        self.assertNotEqual(self.process.wait(timeout=5), 0)
        self.assertFalse((self.work / "ready").exists())
        self.assertEqual((self.target / "marker").read_text(), "original")
        self.assertIsNone(self.parent.poll())

    def test_concurrent_external_replacement_is_not_overwritten(self):
        self.start()
        self.ready()
        self.target.rename(self.root / "external-backup.app")
        self.app(self.target, "0.3.0", "external update")
        self.assertNotEqual(self.finish(), 0)
        self.assertEqual((self.target / "marker").read_text(), "external update")
        self.assertFalse(self.backup.exists())

    def test_wrong_version_is_not_offered_for_installation(self):
        with (self.staged / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.toccata.studio", "CFBundleShortVersionString": "0.1.0"}, stream)
        self.start()
        self.assertNotEqual(self.process.wait(timeout=5), 0)
        self.assertFalse((self.work / "ready").exists())
        self.assertFalse(self.backup.exists())


if __name__ == "__main__":
    unittest.main()
