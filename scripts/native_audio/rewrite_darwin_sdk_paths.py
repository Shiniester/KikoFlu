from __future__ import annotations

import argparse
from pathlib import Path


_LOCKED_SDK_PATHS = {
    "macos": "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
    "ios": "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk",
    "ios_simulator": "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
}


class DarwinSdkPathError(ValueError):
    pass


def rewrite_sdk_paths(
    cross_files_dir: Path,
    *,
    macos_sdk_path: str,
    ios_sdk_path: str,
    ios_simulator_sdk_path: str,
) -> None:
    if not cross_files_dir.is_dir():
        raise DarwinSdkPathError(f"cross-file directory does not exist: {cross_files_dir}")

    selected_paths = {
        "macos": macos_sdk_path,
        "ios": ios_sdk_path,
        "ios_simulator": ios_simulator_sdk_path,
    }
    if any(not path.startswith("/") for path in selected_paths.values()):
        raise DarwinSdkPathError("selected SDK paths must be absolute")

    cross_files = sorted(cross_files_dir.glob("*.ini"))
    if not cross_files:
        raise DarwinSdkPathError(f"no Meson cross-files found in {cross_files_dir}")

    replacements = {name: 0 for name in _LOCKED_SDK_PATHS}
    for cross_file in cross_files:
        with cross_file.open(encoding="utf-8", newline="") as source:
            contents = source.read()
        for name, locked_path in _LOCKED_SDK_PATHS.items():
            count = contents.count(locked_path)
            if count:
                contents = contents.replace(locked_path, selected_paths[name])
                replacements[name] += count
        if cross_file.name.startswith("iossimulator-"):
            contents = contents.replace(
                "-miphoneos-version-min=", "-mios-simulator-version-min="
            )
        if "/Applications/Xcode.app/Contents/Developer/Platforms/" in contents:
            raise DarwinSdkPathError(f"stale Xcode.app SDK path remains in {cross_file.name}")
        with cross_file.open("w", encoding="utf-8", newline="") as destination:
            destination.write(contents)

    missing = [name for name, count in replacements.items() if count == 0]
    if missing:
        raise DarwinSdkPathError(
            "locked cross-files did not contain expected SDK paths: " + ", ".join(missing)
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("cross_files_dir", type=Path)
    parser.add_argument("--macos-sdk", required=True)
    parser.add_argument("--ios-sdk", required=True)
    parser.add_argument("--ios-simulator-sdk", required=True)
    args = parser.parse_args()
    try:
        rewrite_sdk_paths(
            args.cross_files_dir,
            macos_sdk_path=args.macos_sdk,
            ios_sdk_path=args.ios_sdk,
            ios_simulator_sdk_path=args.ios_simulator_sdk,
        )
    except DarwinSdkPathError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
