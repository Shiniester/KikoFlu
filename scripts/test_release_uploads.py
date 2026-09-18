"""Exercise the release workflows' Bash upload loops with GitHub failures.

Run with python3 scripts/test_release_uploads.py. Requires Bash (Git Bash on Windows).
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH") or shutil.which("bash")

HARNESS = r'''
set -euo pipefail
TAG=v4.5.0
GH_REPO=fixture/release
GH_TOKEN=fixture-token
upload_url=https://fixture.invalid/assets
expected=(first.apk second.apk)
assets=(release-assets/first.apk release-assets/second.apk)
declare -A attempts states
trap 'echo CLEANUP' ERR

upload() {
  local name="$1" replace="$2"
  attempts[$name]=$(( ${attempts[$name]:-0} + 1 ))
  echo "ATTEMPT:$name:${attempts[$name]}"
  if [ "$SCENARIO" = forbidden ]; then
    echo 'HTTP 403: Forbidden' >&2
    return 1
  fi
  if [ -n "${states[$name]:-}" ]; then
    if [ "$replace" != true ]; then
      echo 'HTTP 422: already_exists' >&2
      return 22
    fi
    echo "REPLACE:$name:${states[$name]}"
    unset 'states[$name]'
  fi
  if [ "$name" = first.apk ] && [ "$SCENARIO" != success ] &&
     { [ "${attempts[$name]}" -eq 1 ] || [ "$SCENARIO" = persistent ]; }; then
    case "$SCENARIO" in
      starter) states[$name]=starter ;;
      response_lost) states[$name]=uploaded ;;
    esac
    echo 'HTTP 502: Bad Gateway' >&2
    return 22
  fi
  states[$name]=uploaded
}

gh() {
  [ "$1 $2 $3" = "release upload $TAG" ] || return 64
  [ -s "$4" ] || return 64
  local replace=false
  [[ " $* " != *' --clobber '* ]] || replace=true
  upload "$(basename "$4")" "$replace"
}

# Mock both upload clients at their network boundary.
curl() { upload "$asset_name" false; }
jq() { printf '%s\n' "$4"; }
sleep() { echo "BACKOFF:$1"; }
'''

VERIFY = r'''
for name in "${expected[@]}"; do
  [ "${states[$name]:-}" = uploaded ]
done
echo COMPLETE
'''


def upload_loop(workflow):
    source = (ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8")
    end = source.index('          remote_assets="')
    start = source.rindex("          for asset in ", 0, end)
    return textwrap.dedent(source[start:end])


class ReleaseUploadTests(unittest.TestCase):
    def run_scenario(self, scenario):
        self.assertIsNotNone(BASH, "Set BASH to the Bash executable")
        for workflow in ("build.yml", "build_android.yml"):
            with self.subTest(workflow=workflow), tempfile.TemporaryDirectory() as temp:
                assets = Path(temp) / "release-assets"
                assets.mkdir()
                for name in ("first.apk", "second.apk"):
                    (assets / name).write_bytes(b"release fixture")
                result = subprocess.run(
                    [BASH, "--noprofile", "--norc"],
                    input=HARNESS + upload_loop(workflow) + VERIFY,
                    text=True,
                    capture_output=True,
                    cwd=temp,
                    env={**os.environ, "SCENARIO": scenario},
                    timeout=15,
                )
                output = result.stdout + result.stderr
                if scenario in ("persistent", "forbidden"):
                    self.assertNotEqual(result.returncode, 0, output)
                    self.assertEqual(output.count("ATTEMPT:first.apk:"), 3, output)
                    self.assertIn("CLEANUP", output)
                    self.assertNotIn("COMPLETE", output)
                    self.assertNotIn("ATTEMPT:second.apk:", output)
                    self.assertEqual(output.count("BACKOFF:"), 2, output)
                else:
                    self.assertEqual(result.returncode, 0, output)
                    attempts = 1 if scenario == "success" else 2
                    self.assertEqual(output.count("ATTEMPT:first.apk:"), attempts, output)
                    self.assertEqual(output.count("ATTEMPT:second.apk:"), 1, output)
                    self.assertIn("COMPLETE", output)
                    self.assertNotIn("CLEANUP", output)
                    if scenario in ("starter", "response_lost"):
                        state = "starter" if scenario == "starter" else "uploaded"
                        self.assertIn(f"REPLACE:first.apk:{state}", output)

    def test_success(self):
        self.run_scenario("success")

    def test_transient_502(self):
        self.run_scenario("transient")

    def test_502_leaves_starter_asset(self):
        self.run_scenario("starter")

    def test_response_lost_after_upload(self):
        self.run_scenario("response_lost")

    def test_persistent_502_is_bounded(self):
        self.run_scenario("persistent")

    def test_permission_failure_does_not_continue(self):
        self.run_scenario("forbidden")


if __name__ == "__main__":
    unittest.main()
