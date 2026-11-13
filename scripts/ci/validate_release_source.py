"""Check that a selected release checkout has the required build interfaces."""

from __future__ import annotations

import argparse
from pathlib import Path


ANDROID_SOURCE_FILES = {
    "scripts/native_audio/build_android.sh": (
        "--validate-output",
        "/default-$abi.jar",
        "source-provenance.txt",
        "source-provenance-$abi.txt",
    ),
    "third_party/media_kit_libs_android_video/android/build.gradle": (
        'project.findProperty("target-platform")',
        '"android-arm64": "arm64-v8a"',
        '"android-x64": "x86_64"',
    ),
}

FULL_SOURCE_FILES = {
    ".github/actions/linux-native-audio-cache/action.yml": (),
    "scripts/ci/run_android_emulator_test.sh": (),
    "scripts/native_audio/build_darwin.sh": (),
}


def required_source_files(profile: str) -> dict[str, tuple[str, ...]]:
    if profile == "android":
        return ANDROID_SOURCE_FILES
    if profile == "full":
        return {**ANDROID_SOURCE_FILES, **FULL_SOURCE_FILES}
    raise ValueError(f"unsupported release profile: {profile}")


def missing_requirements(root: Path, profile: str) -> list[str]:
    missing: list[str] = []
    for relative_path, markers in required_source_files(profile).items():
        path = root / relative_path
        if not path.is_file():
            missing.append(f"{relative_path} is missing")
            continue
        content = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in content:
                missing.append(f"{relative_path} is missing {marker!r}")
    if profile == "full":
        darwin_builder = root / "scripts/native_audio/build_darwin.sh"
        if darwin_builder.is_file():
            content = darwin_builder.read_text(encoding="utf-8")
            source_check = 'python3 "$script_dir/test_darwin_native.py"'
            sdk_rewrite = 'python3 "$script_dir/rewrite_darwin_sdk_paths.py"'
            if (
                source_check not in content
                or sdk_rewrite not in content
                or content.index(source_check) > content.index(sdk_rewrite)
            ):
                missing.append(
                    "scripts/native_audio/build_darwin.sh must run native source "
                    "checks before rewriting SDK paths"
                )
    return missing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=("android", "full"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()

    missing = missing_requirements(args.root, args.profile)
    if missing:
        print(
            "::error::Selected commit lacks required release configuration or "
            "Android native/Gradle interfaces. Choose a commit that includes "
            "the new release configuration."
        )
        for item in missing:
            print(f" - {item}")
        return 1

    print(f"Selected commit satisfies the {args.profile} release source contract.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
