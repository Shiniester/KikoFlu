import subprocess
import sys
import unittest
from pathlib import Path
from uuid import uuid4


SCRIPT = Path(__file__).with_name("probe_audio_effects.py")


class AudioEffectsProbeCliTests(unittest.TestCase):
    def test_missing_library_path_returns_actionable_error(self):
        missing = Path.cwd() / f"missing-libmpv-{uuid4().hex}.dll"

        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--libmpv", str(missing)],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(missing), result.stderr)
        self.assertIn("does not exist", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_non_library_file_returns_load_error_without_traceback(self):
        not_a_library = Path(__file__).parents[1] / "README.md"

        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--libmpv", str(not_a_library)],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not load libmpv", result.stderr)
        self.assertIn(str(not_a_library), result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
