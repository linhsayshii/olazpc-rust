"""Exercise the local gate with synthetic asar bytes; no official assets are copied."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check-client-version.py"


class ClientVersionDriftTests(unittest.TestCase):
    def test_fake_runtime_versions_and_missing_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = root / "identity.rs"
            identity.write_text('client_identity!("695", "23");')
            asar = root / "app.asar"
            for data, code, label in [
                (None, 0, "SKIP"),
                (b'header\x00getClientVersion:function(){return 695}\x00tail', 0, "PASS"),
                (b'getClientVersion: function () { return 695; }', 0, "PASS"),
                (b'getClientVersion:function(){return 696}', 1, "FAIL"),
                (b'getClientVersion:function(){return 695}getClientVersion:function(){return 696}', 1, "FAIL"),
                (b'no function here', 1, "FAIL"),
                (b'', 1, "FAIL"),
            ]:
                with self.subTest(data=data):
                    if data is not None:
                        asar.write_bytes(data)
                    result = subprocess.run([sys.executable, str(SCRIPT), "--asar", str(asar), "--identity", str(identity)], capture_output=True, text=True, check=False)
                    self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                    self.assertIn(label, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
