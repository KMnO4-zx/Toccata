"""Reject SDK drift before building or reusing a packaged app."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "macos-toolchain.sh"


class MacOSToolchainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="toccata-sdk-test-")
        self.addCleanup(self.temp.cleanup)
        self.bin = Path(self.temp.name)
        xcrun = self.bin / "xcrun"
        xcrun.write_text(f"#!{Path(sys.executable).resolve()}\n" + '''
import os, sys
args = sys.argv[1:]
if args == ["--sdk", "macosx", "--show-sdk-version"]:
    print(os.environ.get("TEST_ACTIVE_SDK", "26.5"))
elif args == ["--sdk", "macosx26.5", "--show-sdk-path"]:
    print("/Toolchain With Spaces/MacOSX26.5.sdk")
elif args[:2] == ["vtool", "-show-build"]:
    name = args[2]
    if name == "unreadable": sys.exit(1)
    for sdk in {"current": ["26.5"], "old": ["15.5"],
                "mixed": ["26.5", "15.5"], "unknown": []}[name]:
        print("      sdk " + sdk)
else:
    sys.exit(2)
''')
        xcrun.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")

    def run_guard(self, body='printf "%s" "$SDKROOT"', **env):
        return subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$1"; ' + body, "test", str(SCRIPT)],
            env=dict(self.env, **env), capture_output=True, text=True)

    def test_exports_the_exact_sdk_path(self):
        result = self.run_guard(SDKROOT="/Unrelated/MacOSX15.5.sdk")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/Toolchain With Spaces/MacOSX26.5.sdk")

    def test_wrong_active_sdk_stops_before_building(self):
        for sdk in ["15.5", "26.4", "26.6"]:
            with self.subTest(sdk=sdk):
                result = self.run_guard('printf "BUILD_STARTED"', TEST_ACTIVE_SDK=sdk)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("BUILD_STARTED", result.stdout)

    def test_both_binaries_must_match(self):
        result = self.run_guard('verify_toccata_macos_sdk current current')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_guard('verify_toccata_macos_sdk current old')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("old", result.stderr)

    def test_a_stale_cached_binary_is_rejected(self):
        result = self.run_guard('verify_toccata_macos_sdk old')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("15.5", result.stderr)

    def test_mixed_architecture_sdks_are_rejected(self):
        result = self.run_guard('verify_toccata_macos_sdk mixed')
        self.assertNotEqual(result.returncode, 0)

    def test_missing_build_version_is_rejected(self):
        result = self.run_guard('verify_toccata_macos_sdk unknown')
        self.assertNotEqual(result.returncode, 0)

    def test_unreadable_binary_is_rejected(self):
        result = self.run_guard('verify_toccata_macos_sdk unreadable')
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
