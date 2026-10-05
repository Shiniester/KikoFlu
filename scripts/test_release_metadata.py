"""Check the Beta workflow's shared versionCode sequence and Android SHA wiring."""

from pathlib import Path
import subprocess
import sys
import textwrap


ROOT = Path(__file__).resolve().parents[1]
beta = (ROOT / ".github/workflows/build_android_beta.yml").read_text(encoding="utf-8")
code = textwrap.dedent(beta.split('python3 - "$version" <<\'PY\'\n', 1)[1].split("          PY\n", 1)[0])


def build_number(version):
    return subprocess.run([sys.executable, "-", version], input=code,
                          text=True, capture_output=True, check=False)


versions = ["4.8.2-beta.999", "4.9.1-beta.1", "4.9.1-beta.2", "4.9.2-beta.1",
            "4.10.0-beta.1", "5.0.0-beta.1"]
numbers = []
for version in versions:
    result = build_number(version)
    assert result.returncode == 0, result.stderr
    number = int(result.stdout)
    assert int(build_number(version).stdout) == number  # Both entry points use the same version.
    numbers.append(number)
assert numbers == sorted(set(numbers))
assert numbers[1] == 409001001
assert numbers[1] > 2000  # Upgrade from the former workflow run-number scheme.
for version in ["4.100.0-beta.1", "4.9.1000-beta.1", "4.9.1-beta.1000", "21.0.0-beta.1"]:
    assert build_number(version).returncode != 0, version
assert beta.count('--build-number="$BUILD_NUMBER"') == 2
assert "$GITHUB_RUN_NUMBER" not in beta

android = (ROOT / ".github/workflows/build_android.yml").read_text(encoding="utf-8")
assert "      commit_sha:\n        description:" in android
assert "ref: ${{ inputs.commit_sha || github.sha }}" in android
assert "ref: ${{ needs.prepare.outputs.commit_sha }}" in android
assert '-f "target_commitish=${RELEASE_COMMIT}"' in android
print("Release metadata checks passed.")
