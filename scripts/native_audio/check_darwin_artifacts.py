#!/usr/bin/env python3
"""Validate Darwin libmpv XCFramework archives before app packaging."""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Callable


REQUIRED_FRAMEWORKS = {
    "Ass",
    "Avcodec",
    "Avfilter",
    "Avformat",
    "Avutil",
    "Dav1d",
    "Freetype",
    "Fribidi",
    "Harfbuzz",
    "Mbedcrypto",
    "Mbedtls",
    "Mbedx509",
    "Mpv",
    "Png16",
    "Swresample",
    "Swscale",
    "Uchardet",
    "Xml2",
}


class ArtifactError(RuntimeError):
    pass


def _version_parts(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"\d+(?:\.\d+){1,2}", value)
    if not match:
        raise ArtifactError(f"invalid deployment target: {value}")
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0, 0, 0])[:3])


def _run_vtool(binary: Path, architecture: str) -> str:
    result = subprocess.run(
        ["xcrun", "vtool", "-arch", architecture, "-show-build", str(binary)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ArtifactError(
            f"vtool failed for {binary} ({architecture}): {result.stderr.strip()}"
        )
    return result.stdout + result.stderr


def _find_minimum_os(output: str, binary: Path, architecture: str) -> str:
    match = re.search(r"\bminos\s+([0-9]+(?:\.[0-9]+){1,2})\b", output)
    if not match and re.search(r"\bcmd\s+LC_VERSION_MIN_(?:MACOSX|IPHONEOS)\b", output):
        match = re.search(r"\bversion\s+([0-9]+(?:\.[0-9]+){1,2})\b", output)
    if not match:
        raise ArtifactError(
            f"vtool did not report a deployment target for {binary} ({architecture})"
        )
    return match.group(1)


def _required_slices(platform: str) -> dict[str | None, set[str]]:
    if platform == "ios":
        return {None: {"arm64"}, "simulator": {"arm64"}}
    if platform == "macos":
        return {None: {"arm64"}}
    raise ArtifactError(f"unsupported artifact platform: {platform}")


def _check_slices(info: dict, framework_name: str, platform: str) -> list[tuple[str, str, Path]]:
    available = info.get("AvailableLibraries")
    if not isinstance(available, list):
        raise ArtifactError(f"{framework_name}.xcframework has no AvailableLibraries")

    required = _required_slices(platform)
    actual: dict[str | None, set[str]] = {}
    binaries: list[tuple[str, str, Path]] = []
    for item in available:
        if item.get("SupportedPlatform") != platform:
            continue
        variant = item.get("SupportedPlatformVariant")
        architectures = set(item.get("SupportedArchitectures", []))
        actual.setdefault(variant, set()).update(architectures)
        library_path = Path(item["LibraryIdentifier"]) / item["LibraryPath"]
        if library_path.suffix == ".framework":
            binary = library_path / library_path.stem
        else:
            binary = library_path
        binaries.extend((variant, architecture, binary) for architecture in architectures)

    for variant, architectures in actual.items():
        variant_name = variant or "device"
        if variant not in required:
            raise ArtifactError(
                f"{framework_name}.xcframework has unexpected {platform} "
                f"variant: {variant_name}"
            )
        unexpected = sorted(architectures - required[variant])
        if unexpected:
            raise ArtifactError(
                f"{framework_name}.xcframework has unexpected {platform} "
                f"{variant_name} architectures: {', '.join(unexpected)}"
            )

    for variant, architectures in required.items():
        if not architectures.issubset(actual.get(variant, set())):
            variant_name = variant or "device"
            missing = sorted(architectures - actual.get(variant, set()))
            raise ArtifactError(
                f"{framework_name}.xcframework is missing {platform} {variant_name} architectures: "
                f"{', '.join(missing)}"
            )
    return binaries


def validate_archive(
    archive_path: Path,
    platform: str,
    minimum_version: str,
    *,
    vtool_runner: Callable[[Path, str], str] = _run_vtool,
) -> None:
    archive_path = Path(archive_path)
    if not archive_path.is_file() or archive_path.stat().st_size == 0:
        raise ArtifactError(f"required custom Darwin archive is missing or empty: {archive_path}")

    maximum = _version_parts(minimum_version)
    with tempfile.TemporaryDirectory(prefix="darwin-xcframework-") as temporary:
        extract_root = Path(temporary)
        try:
            with tarfile.open(archive_path, "r:gz") as archive:
                roots = {
                    PurePosixPath(member.name).parts[0]
                    for member in archive.getmembers()
                    if PurePosixPath(member.name).parts
                }
                if len(roots) != 1:
                    raise ArtifactError(
                        f"{archive_path.name} must contain one upstream archive root"
                    )
                archive.extractall(extract_root)
        except (tarfile.TarError, OSError) as error:
            raise ArtifactError(f"cannot read Darwin archive {archive_path}: {error}") from error

        archive_root = extract_root / next(iter(roots))
        frameworks = {
            path.name.removesuffix(".xcframework"): path
            for path in archive_root.glob("*.xcframework")
            if path.is_dir()
        }
        missing_frameworks = sorted(REQUIRED_FRAMEWORKS - frameworks.keys())
        if missing_frameworks:
            raise ArtifactError(
                f"{archive_path.name} is missing required XCFrameworks: "
                f"{', '.join(missing_frameworks)}"
            )

        for framework_name in sorted(REQUIRED_FRAMEWORKS):
            framework = frameworks[framework_name]
            info_path = framework / "Info.plist"
            if not info_path.is_file():
                raise ArtifactError(f"{info_path} is missing")
            try:
                with info_path.open("rb") as info_file:
                    info = plistlib.load(info_file)
            except (OSError, plistlib.InvalidFileException) as error:
                raise ArtifactError(f"cannot parse {info_path}: {error}") from error

            for variant, architecture, relative_binary in _check_slices(
                info, framework_name, platform
            ):
                binary = framework / relative_binary
                if not binary.is_file():
                    raise ArtifactError(f"{framework_name} slice binary is missing: {binary}")
                minimum = _find_minimum_os(
                    vtool_runner(binary, architecture), binary, architecture
                )
                allowed_maximum = maximum
                allowed_maximum_label = f"project minimum {minimum_version}"
                if platform == "macos" and architecture == "arm64":
                    # Apple silicon first supports macOS 11.0.
                    apple_silicon_minimum = _version_parts("11.0")
                    if apple_silicon_minimum > allowed_maximum:
                        allowed_maximum = apple_silicon_minimum
                        allowed_maximum_label = "macOS arm64 minimum 11.0"
                elif platform == "ios" and variant == "simulator" and architecture == "arm64":
                    # Apple silicon simulators first support iOS 14.0.
                    simulator_minimum = _version_parts("14.0")
                    if simulator_minimum > allowed_maximum:
                        allowed_maximum = simulator_minimum
                        allowed_maximum_label = "iOS simulator arm64 minimum 14.0"
                if _version_parts(minimum) > allowed_maximum:
                    variant_name = variant or "device"
                    raise ArtifactError(
                        f"{framework_name} {platform} {variant_name} {architecture} "
                        f"minos {minimum} exceeds {allowed_maximum_label}"
                    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ios-archive", required=True, type=Path)
    parser.add_argument("--macos-archive", required=True, type=Path)
    parser.add_argument("--ios-min", required=True)
    parser.add_argument("--macos-min", required=True)
    args = parser.parse_args()

    try:
        validate_archive(args.ios_archive, "ios", args.ios_min)
        validate_archive(args.macos_archive, "macos", args.macos_min)
    except ArtifactError as error:
        print(f"Darwin native audio artifacts: {error}", file=sys.stderr)
        return 1
    print("Darwin iOS and macOS XCFramework archives passed layout, slice, and minos checks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
