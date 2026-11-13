"""Check the release workflow artifact, dependency, and validation contracts."""

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
sys.path.insert(0, str(ROOT / "scripts/ci"))
from validate_release_source import required_source_files


def job(workflow: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [a-z0-9-]+:\n|\Z)",
        workflow,
    )
    assert match, f"Missing workflow job: {name}"
    return match.group(1)


build = (WORKFLOWS / "build.yml").read_text(encoding="utf-8")
android = (WORKFLOWS / "build_android.yml").read_text(encoding="utf-8")
beta = (WORKFLOWS / "build_android_beta.yml").read_text(encoding="utf-8")
release_on_push = (WORKFLOWS / "release_on_push.yml").read_text(encoding="utf-8")

for workflow in (build, android, beta):
    assert workflow.count("--target-platform android-arm64 --split-per-abi") == 1
    assert "Iroru-android-universe_" not in workflow
assert "android_all_abis: true" in job(build, "native-audio-android")
assert "android_all_abis: false" in job(android, "native-audio")
assert "android_all_abis: false" in job(beta, "native-audio")

for workflow in (build, android):
    assert "ANDROID_BASE_VERSION_CODE + 2000" in workflow
    assert "com.meteor.kikoeruflutter" in workflow
    assert "EXPECTED_CERT_SHA256" in workflow
    assert 'apksigner" verify --print-certs' in workflow

assert "EXPECTED_BUILD_NUMBER + 2000" in beta
assert "com.meteor.kikoeruflutter.beta" in beta
assert 'apksigner" verify "$apk"' in beta
assert "length == 1 and all" in beta

android_job = job(build, "android")
windows_job = job(build, "windows")
assert "needs: [prepare, native-audio-android]" in android_job
assert "needs: [prepare, native-audio-windows]" in windows_job
android_native = job(build, "native-audio-android")
assert "needs: prepare" in android_native
assert "android_only: true" in android_native
assert "android_all_abis: true" in android_native
assert "needs: prepare" in job(build, "native-audio-windows")
assert "windows_only: true" in job(build, "native-audio-windows")

android_verify = job(build, "android-verify")
assert "arch: x86_64" in android_verify
assert "timeout-minutes: 15" in android_verify
assert "run_android_emulator_test.sh" in android_verify
assert "android-emulator-diagnostics" in android_verify
assert "always() && steps.android-emulator-tests.outcome == 'failure'" in android_verify
assert "${{ runner.temp }}/android-emulator-diagnostics/" in android_verify
emulator_script = re.search(r"(?ms)^          script: >-\n(.*?)(?=^      - name:)", android_verify)
assert emulator_script and len([line for line in emulator_script.group(1).splitlines() if line.strip()]) == 1

release = job(build, "release")
for required_job in ("android", "android-verify", "windows", "ios-verify", "ios-build", "macos", "linux"):
    assert f"      - {required_job}" in release
assert "linux-arm64" not in build
assert "Iroru-linux-arm64_" not in release
assert "Iroru-linux-x64_" in release

for workflow in (build, android, beta):
    flutter_setups = workflow.count("uses: subosito/flutter-action@v2")
    assert workflow.count("          cache: true") == flutter_setups
    assert workflow.count("          pub-cache: true") == flutter_setups
    assert "Cache Android Gradle dependencies" in workflow
    assert "~/.gradle/caches/modules-2" in workflow
    assert "release-key.jks" not in workflow.split("Cache Android Gradle dependencies", 1)[1].split("- name:", 1)[0]

linux_cache = (ROOT / ".github/actions/linux-native-audio-cache/action.yml").read_text(encoding="utf-8")
test_only = (WORKFLOWS / "build_test_only.yml").read_text(encoding="utf-8")
assert "uses: ./.github/actions/linux-native-audio-cache" in build
assert "uses: ./.github/actions/linux-native-audio-cache" in test_only
assert "ImageOS" in linux_cache and "ImageVersion" in linux_cache
assert "dpkg-query -W" in linux_cache and "python3 -m pip freeze" in linux_cache
assert 'workspace=%s\\n' in linux_cache and '"$GITHUB_WORKSPACE"' in linux_cache
assert "hashFiles('.github/actions/linux-native-audio-cache/action.yml'" in linux_cache
assert "scripts/native_audio/linux.lock" in linux_cache
assert "scripts/native_audio/ffmpeg-sendcmd-precision.patch" in linux_cache
assert "scripts/native_audio/mpv-audio-controls.patch" in linux_cache
assert "ldd \"$prefix/lib/libmpv.so\"" in linux_cache
assert "readelf -d" in linux_cache
assert "readelf -h" in linux_cache and "x86_64 shared library" in linux_cache
assert "actions/cache/restore@v4" in linux_cache
assert "actions/cache/save@v4" in linux_cache
assert "continue-on-error: true" in linux_cache
assert "production-pcm.json" not in linux_cache
cache_keys = re.findall(r"^        key: (.+)$", linux_cache, re.MULTILINE)
assert len(cache_keys) == 2 and cache_keys[0] == cache_keys[1]

plan = job(release_on_push, "plan")
assert "scripts/ci/build_test_scope.py" not in release_on_push
assert re.findall(r"^    if: (.+)$", plan, re.MULTILINE) == ["github.event.deleted != true"]
assert "scripts/plan_push_release.py" in plan
for release_job in ("stable", "beta"):
    assert "needs: plan" in job(release_on_push, release_job)
    assert "needs.plan.outputs.publish == 'true'" in job(release_on_push, release_job)
assert "workflow_dispatch:" not in release_on_push
assert "python3 scripts/test_plan_push_release.py" in job(test_only, "quality-analysis")

build_scope = job(test_only, "build-scope")
assert "fetch-depth: 0" in build_scope
assert 'args+=("refs/remotes/origin/$DEFAULT_BRANCH")' in build_scope
assert 'scripts/ci/build_test_scope.py "${args[@]}"' in build_scope
for gated_job in ("native-audio", "native-audio-android", "native-audio-darwin", "linux"):
    assert "needs.build-scope.outputs.build_required != 'false'" in job(test_only, gated_job)


for workflow, profile in (
    (build, "full"),
    (android, "android"),
    ((WORKFLOWS / "native_audio.yml").read_text(encoding="utf-8"), "android"),
):
    assert "if [[ ! -f scripts/ci/validate_release_source.py ]]" in workflow
    assert f"validate_release_source.py {profile}" in workflow
    assert "Choose a commit that includes the new release configuration." in workflow

assert "needs: prepare" in job(build, "native-audio-android")
assert "needs: prepare" in job(build, "native-audio-windows")
assert "needs: native-audio" in job(beta, "android")


def make_source_fixture(destination: Path, profile: str) -> None:
    for relative_path in required_source_files(profile):
        source = ROOT / relative_path
        target = destination / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)


def run_source_preflight(root: Path, profile: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/ci/validate_release_source.py"),
            profile,
            "--root",
            str(root),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary) / "current-source"
    fixture.mkdir()
    make_source_fixture(fixture, "full")
    for profile in ("android", "full"):
        result = run_source_preflight(fixture, profile)
        assert result.returncode == 0, result.stdout + result.stderr

    legacy = Path(temporary) / "legacy-source"
    legacy.mkdir()
    make_source_fixture(legacy, "full")
    (legacy / "scripts/native_audio/build_android.sh").write_text(
        "# Legacy builder without per-ABI validation or provenance output.\n",
        encoding="utf-8",
    )
    (legacy / "third_party/media_kit_libs_android_video/android/build.gradle").write_text(
        "// Legacy Gradle integration without target-platform selection.\n",
        encoding="utf-8",
    )
    (legacy / ".github/actions/linux-native-audio-cache/action.yml").unlink()
    (legacy / "scripts/ci/run_android_emulator_test.sh").unlink()
    (legacy / "scripts/native_audio/build_darwin.sh").write_text(
        'python3 "$script_dir/rewrite_darwin_sdk_paths.py"\n'
        'python3 "$script_dir/test_darwin_native.py"\n',
        encoding="utf-8",
    )
    result = run_source_preflight(legacy, "full")
    assert result.returncode != 0
    assert "Selected commit lacks required release configuration" in result.stdout
    assert "--validate-output" in result.stdout
    assert "target-platform" in result.stdout
    assert "linux-native-audio-cache/action.yml is missing" in result.stdout
    assert "native source checks before rewriting SDK paths" in result.stdout

print("Release workflow contract checks passed.")
