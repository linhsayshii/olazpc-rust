"""Exercise scripts/check-e2ee-group-flag.py with synthetic asar byte strings."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check-e2ee-group-flag.py"
REOPEN_MSG = "group E2EE enabled in this Zalo build: reopen U17"


class E2EEGroupFlagTests(unittest.TestCase):
    def _run(self, data: bytes | None, *, use_flag: bool = False) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            asar = Path(directory) / "app.asar"
            if data is not None:
                asar.write_bytes(data)
            args = [sys.executable, str(SCRIPT)]
            if use_flag:
                args.extend(["--asar", str(asar)])
            else:
                args.append(str(asar))
            return subprocess.run(args, capture_output=True, text=True, check=False)

    def test_missing_explicit_asar_fails(self):
        for use_flag in (False, True):
            result = self._run(None, use_flag=use_flag)
            combined = result.stdout + result.stderr
            self.assertEqual(result.returncode, 1, combined)
            self.assertIn("does not exist", combined)

    def test_missing_default_asar_skips(self):
        with tempfile.TemporaryDirectory() as home:
            env = {"HOME": home, "PATH": "/usr/bin:/bin"}
            result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False, env=env)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("SKIP", combined)

    def test_single_deactivated_passes(self):
        result = self._run(b"\x00header\x00SECRET_BUNDLE_CONTEXT={DEACTIVATE_E2EE_GROUP:!0,FOO:1}\x00tail")
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("OK", combined)
        self.assertNotIn("SECRET_BUNDLE_CONTEXT", combined)

    def test_multiple_deactivated_with_flag_option_passes(self):
        result = self._run(
            b"a={DEACTIVATE_E2EE_GROUP: !0};b={DEACTIVATE_E2EE_GROUP:!0}",
            use_flag=True,
        )
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("OK", combined)

    def test_bang_one_fails_without_leaking_context(self):
        result = self._run(b"SECRET_BUNDLE_CONTEXT={DEACTIVATE_E2EE_GROUP:!1,BAR:2}")
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn(REOPEN_MSG, combined)
        self.assertNotIn("SECRET_BUNDLE_CONTEXT", combined)

    def test_false_literal_fails(self):
        result = self._run(b"const flags={DEACTIVATE_E2EE_GROUP: false};", use_flag=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn(REOPEN_MSG, combined)

    def test_mixed_deactivated_and_enabled_fails(self):
        result = self._run(b"{DEACTIVATE_E2EE_GROUP:!0}and{DEACTIVATE_E2EE_GROUP:!1}")
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn(REOPEN_MSG, combined)

    def test_no_constant_found_fails(self):
        result = self._run(b"SECRET_BUNDLE_CONTEXT=no_matching_flag")
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn(REOPEN_MSG, combined)
        self.assertNotIn("SECRET_BUNDLE_CONTEXT", combined)

    def test_empty_asar_fails(self):
        result = self._run(b"")
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn(REOPEN_MSG, combined)


if __name__ == "__main__":
    unittest.main()
