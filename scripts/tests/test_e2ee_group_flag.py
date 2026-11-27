"""Exercise scripts/check-e2ee-group-flag.py with synthetic asar byte strings."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check-e2ee-group-flag.py"
REOPEN_MSG = "group E2EE enabled in this Zalo build: reopen U17"


class E2EEGroupFlagTests(unittest.TestCase):
    def test_synthetic_asar_flags_and_missing_asar(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = root / "missing.asar"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(missing)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("SKIP", result.stdout + result.stderr)

            asar = root / "app.asar"
            cases = [
                (
                    b"\x00header\x00SECRET_BUNDLE_CONTEXT={DEACTIVATE_E2EE_GROUP:!0,FOO:1}\x00tail",
                    0,
                    "OK",
                ),
                (
                    b"a={DEACTIVATE_E2EE_GROUP: !0};b={DEACTIVATE_E2EE_GROUP:!0}",
                    0,
                    "OK",
                ),
                (
                    b"SECRET_BUNDLE_CONTEXT={DEACTIVATE_E2EE_GROUP:!1,BAR:2}",
                    1,
                    REOPEN_MSG,
                ),
                (
                    b"const flags={DEACTIVATE_E2EE_GROUP: false};",
                    1,
                    REOPEN_MSG,
                ),
                (
                    b"{DEACTIVATE_E2EE_GROUP:!0}and{DEACTIVATE_E2EE_GROUP:!1}",
                    1,
                    REOPEN_MSG,
                ),
                (b"SECRET_BUNDLE_CONTEXT=no_matching_flag", 1, REOPEN_MSG),
                (b"", 1, REOPEN_MSG),
            ]
            for data, code, expected in cases:
                for flag_args in ([str(asar)], ["--asar", str(asar)]):
                    with self.subTest(data=data, flag_args=flag_args):
                        asar.write_bytes(data)
                        result = subprocess.run(
                            [sys.executable, str(SCRIPT), *flag_args],
                            capture_output=True,
                            text=True,
                            check=False,
                        )
                        combined = result.stdout + result.stderr
                        self.assertEqual(result.returncode, code, combined)
                        self.assertIn(expected, combined)
                        self.assertNotIn("SECRET_BUNDLE_CONTEXT", combined)


if __name__ == "__main__":
    unittest.main()
