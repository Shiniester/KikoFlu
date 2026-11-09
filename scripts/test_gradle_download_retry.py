"""Exercise the Beta workflow's Gradle wrapper retry loop without network access."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build_android_beta.yml"
SOURCE = WORKFLOW.read_text(encoding="utf-8")
BASH = os.environ.get("BASH") or shutil.which("bash")
HARNESS = """
set -euo pipefail
flutter() {
  [ "$*" = 'build apk --config-only --no-pub' ] || return 64
  chmod +x android/gradlew
  echo CONFIGURED
}
sleep() { echo "BACKOFF:$1"; }
"""
MOCK_WRAPPER = r'''#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 1 ] && [ "$1" = "--version" ] || exit 64
attempt_file=../attempts
attempt=0
[ ! -f "$attempt_file" ] || attempt="$(cat "$attempt_file")"
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$attempt_file"
echo "ATTEMPT:$attempt"
case "$SCENARIO" in
  success) exit 0 ;;
  transient)
    if [ "$attempt" -eq 1 ]; then
      echo 'HTTP 504' >&2
      exit 1
    fi
    ;;
  persistent)
    echo 'HTTP 504' >&2
    exit 1
    ;;
  *) exit 64 ;;
esac
'''


def gradle_prepare_step():
    step = SOURCE.index("      - name: Prepare Gradle Wrapper\n")
    start = SOURCE.index("          set -euo pipefail", step)
    end = SOURCE.index("\n\n      - name: Build Android Beta APKs", start)
    return textwrap.dedent(SOURCE[start:end])


class GradleDownloadRetryTests(unittest.TestCase):
    def run_scenario(self, scenario):
        self.assertIsNotNone(BASH, "Set BASH to the Bash executable")
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            android = Path(temp) / "android"
            android.mkdir()
            wrapper = android / "gradlew"
            wrapper.write_text(MOCK_WRAPPER, encoding="utf-8", newline="\n")
            wrapper.chmod(0o755)
            result = subprocess.run(
                [BASH, "--noprofile", "--norc"],
                input=HARNESS + gradle_prepare_step(),
                text=True,
                capture_output=True,
                cwd=temp,
                env={**os.environ, "SCENARIO": scenario},
                timeout=15,
            )
            self.assertIn("CONFIGURED", result.stdout, result.stderr)
            self.assertLess(
                result.stdout.index("CONFIGURED"), result.stdout.index("ATTEMPT:")
            )
            return result

    def test_wrapper_succeeds_without_retry(self):
        result = self.run_scenario("success")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(output.count("ATTEMPT:"), 1, output)
        self.assertNotIn("BACKOFF:", output)

    def test_transient_failure_recovers(self):
        result = self.run_scenario("transient")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(output.count("ATTEMPT:"), 2, output)
        self.assertIn("BACKOFF:5", output)

    def test_persistent_failure_is_bounded(self):
        result = self.run_scenario("persistent")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(output.count("ATTEMPT:"), 3, output)
        self.assertIn("BACKOFF:5", output)
        self.assertIn("BACKOFF:10", output)
        self.assertIn("Gradle wrapper failed after 3 attempts", output)


if __name__ == "__main__":
    unittest.main()
