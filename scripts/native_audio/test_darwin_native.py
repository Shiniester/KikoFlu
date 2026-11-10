from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from check_darwin_artifacts import ArtifactError, _version_parts, validate_archive
from rewrite_darwin_sdk_paths import DarwinSdkPathError, rewrite_sdk_paths


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]


def _bash_executable() -> str | None:
    bash = shutil.which("bash")
    if bash is not None:
        return bash
    if os.name == "nt":
        git = shutil.which("git")
        if git is not None:
            candidate = Path(git).resolve().parent.parent / "bin" / "bash.exe"
            if candidate.is_file():
                return str(candidate)
    return None


def _write_xcframework(root: Path, name: str, platform: str) -> None:
    framework = root / f"{name}.xcframework"
    slices = []
    if platform == "ios":
        slices = [
            {
                "LibraryIdentifier": "ios-arm64",
                "LibraryPath": f"{name}.framework",
                "SupportedArchitectures": ["arm64"],
                "SupportedPlatform": "ios",
            },
            {
                "LibraryIdentifier": "ios-arm64_x86_64-simulator",
                "LibraryPath": f"{name}.framework",
                "SupportedArchitectures": ["arm64", "x86_64"],
                "SupportedPlatform": "ios",
                "SupportedPlatformVariant": "simulator",
            },
        ]
    else:
        slices = [
            {
                "LibraryIdentifier": "macos-arm64_x86_64",
                "LibraryPath": f"{name}.framework",
                "SupportedArchitectures": ["arm64", "x86_64"],
                "SupportedPlatform": "macos",
            }
        ]

    framework.mkdir(parents=True)
    with (framework / "Info.plist").open("wb") as output:
        plistlib.dump({"AvailableLibraries": slices}, output)

    for item in slices:
        binary = framework / item["LibraryIdentifier"] / f"{name}.framework" / name
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"fixture Mach-O")


def _write_archive(path: Path, platform: str) -> None:
    package_root = path.parent / f"fixture-package-{path.name.replace('.tar.gz', '')}"
    package_root.mkdir()
    for name in (
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
    ):
        _write_xcframework(package_root, name, platform)

    with tarfile.open(path, "w:gz") as archive:
        archive.add(package_root, arcname="libmpv-xcframeworks-v0.6.0")


def _normalized_patch(source: Path, root: Path) -> Path:
    destination = root / "test-patches" / source.name
    destination.parent.mkdir(exist_ok=True)
    destination.write_bytes(source.read_bytes().replace(b"\r\n", b"\n"))
    return destination


class DarwinRecipePatchTests(unittest.TestCase):
    def test_recipe_patch_adds_only_the_required_audio_filter_allowlist(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ffmpeg = root / "scripts/ffmpeg"
            mpv = root / "scripts/mpv"
            pkg_config = root / "scripts/pkg-config"
            ffmpeg.mkdir(parents=True)
            mpv.mkdir(parents=True)
            pkg_config.mkdir(parents=True)
            freetype = root / "scripts/freetype"
            freetype.mkdir(parents=True)
            meson_lines = ["# fixture\n"] * 155 + [
                "    # filters\n",
                "    '--enable-filter=overlay',\n",
                "    '--enable-filter=equalizer',\n",
                "]\n",
            ]
            (ffmpeg / "meson.build").write_bytes(
                "".join(meson_lines).encode("utf-8")
            )
            (ffmpeg / "build.sh").write_bytes(
                (
                    "#!/bin/sh\n"
                    "\n"
                    "set -e # exit immediately if a command exits with a non-zero status\n"
                    "set -u # treat unset variables as an error\n"
                    "\n"
                    "cd ${SRC_DIR}\n"
                    "\n"
                    "patch -p1 <${PROJECT_DIR}/patches/ffmpeg-fix-vp9-hwaccel.patch\n"
                    "patch -p1 <${PROJECT_DIR}/patches/ffmpeg-fix-hls-mp4-seek.patch\n"
                    "patch -p1 <${PROJECT_DIR}/patches/ffmpeg-fix-ios-hdr-texture.patch\n"
                    "patch -p1 <${PROJECT_DIR}/patches/ffmpeg-fix-dash-base-url-escape.patch\n"
                    "\n"
                    "cp ${PROJECT_DIR}/scripts/ffmpeg/meson.* .\n"
                    "meson setup build \\\n"
                ).encode("utf-8")
            )
            (mpv / "build.sh").write_bytes(
                (
                    "#!/bin/bash\n"
                    "\n"
                    "set -e # exit immediately if a command exits with a non-zero status\n"
                    "set -u # treat unset variables as an error\n"
                    "\n"
                    "cd ${SRC_DIR}\n"
                    "\n"
                    "patch -p1 <${PROJECT_DIR}/patches/mpv-fix-missing-objc.patch\n"
                    'if [ "${VARIANT}" == "audio" ]; then\n'
                    "    patch -p1 <${PROJECT_DIR}/patches/mpv-remove-libass.patch\n"
                    "fi\n"
                ).encode("utf-8")
            )
            (pkg_config / "build.sh").write_bytes(
                (
                    "#!/bin/sh\n"
                    "set -e\n"
                    "set -u\n"
                    "cd ${SRC_DIR}\n"
                    "cp ${PROJECT_DIR}/scripts/pkg-config/meson.build ./meson.build\n"
                    "meson setup build \\\n"
                ).encode("utf-8")
            )
            freetype_builder = (
                "#!/bin/sh\n\n"
                "set -e # exit immediately if a command exits with a non-zero status\n"
                "set -u # treat unset variables as an error\n\n"
                "cd ${SRC_DIR}\n"
                "meson setup build " + "\\" + "\n"
            )
            (freetype / "build.sh").write_bytes(freetype_builder.encode("utf-8"))
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "core.autocrlf", "false"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)

            recipe_patch = _normalized_patch(SCRIPT_DIR / "darwin-recipe.patch", root)

            subprocess.run(
                ["git", "-C", str(root), "apply", "--check", str(recipe_patch)],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(root), "apply", str(recipe_patch)],
                check=True,
            )

            actual = {
                line.split("=", 1)[1].strip("', ")
                for line in (ffmpeg / "meson.build").read_text().splitlines()
                if "--enable-filter=" in line
            }
            expected = set((SCRIPT_DIR / "filters.txt").read_text().splitlines()) | {
                "overlay",
                "equalizer",
            }
            self.assertEqual(expected, actual)
            self.assertNotIn("--enable-filters", (ffmpeg / "meson.build").read_text())
            self.assertIn(
                "patch -p1 <${PROJECT_DIR}/patches/pkg-config-glib-atomics.patch",
                (pkg_config / "build.sh").read_text(),
            )
            self.assertIn("meson subprojects download libpng", (freetype / "build.sh").read_text())
            self.assertIn(
                "patch -p1 -d subprojects/libpng-1.6.40 <${PROJECT_DIR}/patches/libpng-macos-fp-header.patch",
                (freetype / "build.sh").read_text(),
            )

    def test_recipe_patch_rejects_unmatched_upstream_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ffmpeg = root / "scripts/ffmpeg"
            mpv = root / "scripts/mpv"
            pkg_config = root / "scripts/pkg-config"
            ffmpeg.mkdir(parents=True)
            mpv.mkdir(parents=True)
            pkg_config.mkdir(parents=True)
            freetype = root / "scripts/freetype"
            freetype.mkdir(parents=True)
            (ffmpeg / "meson.build").write_text("audio_default_options = []\n")
            (ffmpeg / "build.sh").write_text("# changed upstream\n")
            (mpv / "build.sh").write_text("# changed upstream\n")
            (pkg_config / "build.sh").write_text("# changed upstream\n")
            (freetype / "build.sh").write_text("# changed upstream\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "core.autocrlf", "false"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            recipe_patch = _normalized_patch(SCRIPT_DIR / "darwin-recipe.patch", root)

            result = subprocess.run(
                ["git", "-C", str(root), "apply", "--check", str(recipe_patch)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(0, result.returncode)

    def test_native_source_patches_apply_at_the_pinned_source_locations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mpv = root / "player/audio.c"
            ffmpeg = root / "libavfilter/f_sendcmd.c"
            mpv.parent.mkdir(parents=True)
            ffmpeg.parent.mkdir(parents=True)

            mpv_lines = ["// fixture\n"] * 391 + [
                "    // Wait until all played.\n",
                "    if (mpctx->ao && ao_is_playing(mpctx->ao)) {\n",
                "        talloc_free(out_fmt);\n",
                "        return 0;\n",
                "    }\n",
                "    // Format change during syncing. Force playback start early, then wait.\n",
                "    if (ao_c->ao_queue && mp_async_queue_get_frames(ao_c->ao_queue) &&\n",
                "        mpctx->audio_status == STATUS_SYNCING)\n",
            ]
            ffmpeg_lines = ["// fixture\n"] * 549 + [
                '                        cmd_arg = av_asprintf("%g", res);\n',
                "                        if (!cmd_arg) {\n",
                "                            av_frame_free(&ref);\n",
                "                            return AVERROR(ENOMEM);\n",
            ]
            mpv.write_bytes("".join(mpv_lines).encode("utf-8"))
            ffmpeg.write_bytes("".join(ffmpeg_lines).encode("utf-8"))
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "core.autocrlf", "false"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)

            for patch_file in ("mpv-audio-reinit.patch", "ffmpeg-sendcmd-precision.patch"):
                patch_path = _normalized_patch(SCRIPT_DIR / patch_file, root)
                subprocess.run(["git", "-C", str(root), "apply", "--check", str(patch_path)], check=True)
                subprocess.run(["git", "-C", str(root), "apply", str(patch_path)], check=True)

            self.assertNotIn("ao_is_playing(mpctx->ao)", mpv.read_text())
            self.assertIn('av_asprintf("%.17g", res)', ffmpeg.read_text())

    def test_pkgconfig_atomic_patch_uses_pointer_sized_atomic_intrinsics(self) -> None:
        added_lines = [
            line[1:]
            for line in (SCRIPT_DIR / "pkg-config-glib-atomics.patch").read_text().splitlines()
            if line.startswith("+") and not line.startswith("+++")
        ]
        self.assertTrue(any(line == "gintptr" for line in added_lines))
        self.assertTrue(any(line == "guintptr" for line in added_lines))
        for operation in ("add", "and", "or", "xor"):
            self.assertTrue(
                any(
                    f"__atomic_fetch_{operation}" in line
                    and "__ATOMIC_SEQ_CST" in line
                    for line in added_lines
                )
            )
        self.assertFalse(any("__sync_fetch_and_" in line for line in added_lines))

    def test_native_source_patch_fails_when_pinned_hunk_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mpv = root / "player/audio.c"
            ffmpeg = root / "libavfilter/f_sendcmd.c"
            mpv.parent.mkdir(parents=True)
            ffmpeg.parent.mkdir(parents=True)
            mpv.write_bytes(b"int main(void) { return 0; }\n")
            ffmpeg.write_bytes(b"int main(void) { return 0; }\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "core.autocrlf", "false"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)

            for patch_file in ("mpv-audio-reinit.patch", "ffmpeg-sendcmd-precision.patch"):
                result = subprocess.run(
                    [
                        "git",
                        "-C",
                        str(root),
                        "apply",
                        "--check",
                        str(_normalized_patch(SCRIPT_DIR / patch_file, root)),
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(0, result.returncode)


class DarwinArtifactTests(unittest.TestCase):
    def test_version_parts_treats_zero_patch_as_equivalent(self) -> None:
        self.assertEqual(_version_parts("13.0"), _version_parts("13.0.0"))

    def test_valid_archives_keep_provider_layout_and_project_minimums(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary)
            ios_archive = temp / "ios.tar.gz"
            macos_archive = temp / "macos.tar.gz"
            _write_archive(ios_archive, "ios")
            _write_archive(macos_archive, "macos")

            def vtool(_binary: Path, _architecture: str) -> str:
                return "Mach build version\n    minos 10.9\n"

            validate_archive(ios_archive, "ios", "13.0", vtool_runner=vtool)
            validate_archive(macos_archive, "macos", "10.15", vtool_runner=vtool)

    def test_legacy_version_min_load_commands_report_deployment_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary)
            ios_archive = temp / "ios.tar.gz"
            macos_archive = temp / "macos.tar.gz"
            _write_archive(ios_archive, "ios")
            _write_archive(macos_archive, "macos")

            validate_archive(
                ios_archive,
                "ios",
                "13.0",
                vtool_runner=lambda _binary, _architecture: (
                    "Load command 5\n"
                    " cmd LC_VERSION_MIN_IPHONEOS\n"
                    " version 9.0\n"
                    " sdk 18.5\n"
                ),
            )
            validate_archive(
                macos_archive,
                "macos",
                "10.15",
                vtool_runner=lambda _binary, _architecture: (
                    "Load command 5\n"
                    " cmd LC_VERSION_MIN_MACOSX\n"
                    " version 10.9\n"
                    " sdk 15.5\n"
                ),
            )

    def test_missing_artifact_fails_instead_of_selecting_stock_provider(self) -> None:
        with self.assertRaises(ArtifactError):
            validate_archive(Path("missing-custom-darwin-archive.tar.gz"), "ios", "13.0")

    def test_archive_above_project_minimum_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "ios.tar.gz"
            _write_archive(archive, "ios")

            def too_new(_binary: Path, _architecture: str) -> str:
                return "Mach build version\n    minos 14.0\n"

            with self.assertRaises(ArtifactError):
                validate_archive(archive, "ios", "13.0", vtool_runner=too_new)

    def test_macos_minimum_accounts_for_arm64_platform_floor_per_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "macos.tar.gz"
            _write_archive(archive, "macos")

            def valid_minimum(_binary: Path, architecture: str) -> str:
                minimum = {"arm64": "11.0", "x86_64": "10.15"}[architecture]
                return f"Mach build version\n    minos {minimum}\n"

            validate_archive(archive, "macos", "10.15", vtool_runner=valid_minimum)

            for architecture, too_new in (("arm64", "11.1"), ("x86_64", "10.16")):
                def too_new_minimum(
                    _binary: Path,
                    target_architecture: str,
                    architecture: str = architecture,
                    too_new: str = too_new,
                ) -> str:
                    minimum = (
                        too_new
                        if target_architecture == architecture
                        else {"arm64": "11.0", "x86_64": "10.15"}[target_architecture]
                    )
                    return f"Mach build version\n    minos {minimum}\n"

                with self.subTest(architecture=architecture, minimum=too_new):
                    with self.assertRaisesRegex(
                        ArtifactError,
                        rf"macos device {architecture} minos {too_new} exceeds",
                    ):
                        validate_archive(
                            archive,
                            "macos",
                            "10.15",
                            vtool_runner=too_new_minimum,
                        )


class DarwinSdkPathTests(unittest.TestCase):
    def test_rewrites_all_locked_cross_file_sdks_without_changing_deployment_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cross_files = Path(temporary)
            macos = "/Applications/Xcode_16.4.app/SDKs/MacOSX.sdk"
            ios = "/Applications/Xcode_16.4.app/SDKs/iPhoneOS.sdk"
            simulator = "/Applications/Xcode_16.4.app/SDKs/iPhoneSimulator.sdk"
            (cross_files / "macos-amd64.ini").write_text(
                "c_args = ['-isysroot', '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk', '-mmacosx-version-min=10.9']\n"
                "cmake_osx_sysroot = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'\n"
            )
            (cross_files / "ios-arm64.ini").write_text(
                "c_args = ['-isysroot', '/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk', '-miphoneos-version-min=9.0']\n"
            )
            (cross_files / "iossimulator-arm64.ini").write_text(
                "c_args = ['-isysroot', '/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk', '-miphoneos-version-min=12.0']\n"
            )

            rewrite_sdk_paths(
                cross_files,
                macos_sdk_path=macos,
                ios_sdk_path=ios,
                ios_simulator_sdk_path=simulator,
            )

            macos_contents = (cross_files / "macos-amd64.ini").read_text()
            self.assertEqual(2, macos_contents.count(macos))
            self.assertIn("-mmacosx-version-min=10.9", macos_contents)
            ios_contents = (cross_files / "ios-arm64.ini").read_text()
            self.assertIn(ios, ios_contents)
            self.assertIn("-miphoneos-version-min=9.0", ios_contents)
            simulator_contents = (cross_files / "iossimulator-arm64.ini").read_text()
            self.assertIn(simulator, simulator_contents)
            self.assertIn("-miphoneos-version-min=12.0", simulator_contents)

    def test_rejects_cross_files_missing_a_locked_sdk_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cross_files = Path(temporary)
            (cross_files / "macos.ini").write_text(
                "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk\n"
            )
            with self.assertRaises(DarwinSdkPathError):
                rewrite_sdk_paths(
                    cross_files,
                    macos_sdk_path="/selected/MacOSX.sdk",
                    ios_sdk_path="/selected/iPhoneOS.sdk",
                    ios_simulator_sdk_path="/selected/iPhoneSimulator.sdk",
                )


class LibpngMacOSPatchTests(unittest.TestCase):
    def test_patch_replaces_legacy_fp_header_and_records_upstream_author(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            header_lines = [
                "    */\n",
                "#  include <float.h>\n",
                "\n",
                "#  if (defined(__MWERKS__) && defined(macintosh)) || defined(applec) || \\\n",
                "    defined(THINK_C) || defined(__SC__) || defined(TARGET_OS_MAC)\n",
                "   /* We need to check that <math.h> hasn't already been included earlier\n",
                "    * as it seems it doesn't agree with <fp.h>, yet we should really use\n",
                "    * <fp.h> if possible.\n",
                "    */\n",
                "#    if !defined(__MATH_H__) && !defined(__MATH_H) && !defined(__cmath__)\n",
                "#      include <fp.h>\n",
                "#    endif\n",
                "#  else\n",
                "#    include <math.h>\n",
                "#  endif\n",
                "#  if defined(_AMIGA) && defined(__SASC) && defined(_M68881)\n",
                "   /* Amiga SAS/C: We must include builtin FPU functions when compiling using\n",
                "    * MATH=68881\n",
                "    */\n",
                "#    include <m68881.h>\n",
                "#  endif\n",
            ]
            (root / "pngpriv.h").write_bytes("".join(header_lines).encode("utf-8"))
            (root / "AUTHORS").write_bytes(
                (
                    "Authors, for copyright and licensing purposes.\n\n"
                    " * Vadim Barkov\n"
                    " * Willem van Schaik\n"
                    " * Zhijie Liang\n"
                    " * Arm Holdings\n"
                    "   - Richard Townsend\n"
                    " * Google Inc.\n"
                ).encode("utf-8")
            )
            patch = _normalized_patch(SCRIPT_DIR / "libpng-macos-fp-header.patch", root)

            subprocess.run(
                ["patch", "-p1", "-i", str(patch)],
                cwd=root,
                input="",
                text=True,
                check=True,
            )

            self.assertNotIn("<fp.h>", (root / "pngpriv.h").read_text())
            self.assertIn("#  include <math.h>", (root / "pngpriv.h").read_text())
            self.assertIn(" * Apple Inc.\n   - Zixu Wang", (root / "AUTHORS").read_text())


class DarwinBuilderCommandTests(unittest.TestCase):
    def _builder_commands(self, start: str, end: str | None = None) -> str:
        lines = (SCRIPT_DIR / "build_darwin.sh").read_text().splitlines()
        start_index = next(i for i, line in enumerate(lines) if line.startswith(start))
        if end is None:
            return "\n".join(line for line in lines if line.startswith(start))
        end_index = next(
            i for i, line in enumerate(lines[start_index:], start_index)
            if line.startswith(end)
        )
        return "\n".join(lines[start_index:end_index])

    def _run_builder_commands(
        self, commands: str, *, xcodebuild_fails: bool = False
    ) -> subprocess.CompletedProcess[str]:
        bash = _bash_executable()
        if bash is None:
            self.skipTest("Bash is required to exercise the Darwin build script")

        lock = (SCRIPT_DIR / "darwin.lock").read_text().splitlines()
        xcode_version = next(
            line.split("=", 1)[1] for line in lock
            if line.startswith("DARWIN_XCODE_VERSION=")
        )
        xcode_build = next(
            line.split("=", 1)[1] for line in lock
            if line.startswith("DARWIN_XCODE_BUILD=")
        )
        script = "\n".join(
            [
                "set -euo pipefail",
                "xcode-select() { printf '/fixture/Developer\\n'; }",
                "xcodebuild() {",
                '  if [[ "${XCODEBUILD_FAIL:-0}" == "1" ]]; then return 23; fi',
                '  printf "Xcode %s\\n" "$TEST_XCODE_VERSION"',
                "  sleep 0.05",
                '  printf "Build version %s\\n" "$TEST_XCODE_BUILD"',
                "}",
                "xcrun() {",
                '  [[ "${1:-}" == "clang" ]] || return 97',
                '  printf "Apple clang version fixture\\n"',
                "  sleep 0.05",
                '  printf "Target: arm64-apple-darwin\\n"',
                "}",
                "fail() { printf 'Darwin native audio build: %s\\n' \"$1\" >&2; exit 1; }",
                commands,
            ]
        )
        environment = os.environ.copy()
        environment["DARWIN_XCODE_VERSION"] = xcode_version
        environment["DARWIN_XCODE_BUILD"] = xcode_build
        environment["TEST_XCODE_VERSION"] = xcode_version
        environment["TEST_XCODE_BUILD"] = xcode_build
        environment["XCODEBUILD_FAIL"] = "1" if xcodebuild_fails else "0"
        if os.name == "nt":
            git_root = Path(bash).resolve().parent.parent
            runtime_paths = [git_root / "usr" / "bin", git_root / "bin"]
            environment["PATH"] = os.pathsep.join(
                [str(path) for path in runtime_paths if path.is_dir()]
                + [environment.get("PATH", "")]
            )
        return subprocess.run(
            [bash, "-c", script],
            capture_output=True,
            text=True,
            env=environment,
            timeout=10,
        )

    def test_xcode_version_probe_consumes_both_lines(self) -> None:
        commands = self._builder_commands(
            "actual_developer_dir=", "actual_ios_sdk="
        )
        result = self._run_builder_commands(
            commands + '\nprintf "%s\\n%s\\n" "$actual_xcode" "$actual_xcode_build"'
        )
        self.assertEqual(0, result.returncode, result.stderr)
        lock = (SCRIPT_DIR / "darwin.lock").read_text().splitlines()
        expected = [
            next(line.split("=", 1)[1] for line in lock if line.startswith(key))
            for key in ("DARWIN_XCODE_VERSION=", "DARWIN_XCODE_BUILD=")
        ]
        self.assertEqual("\n".join(expected) + "\n", result.stdout)

    def test_xcodebuild_failure_propagates(self) -> None:
        commands = self._builder_commands(
            "actual_developer_dir=", "actual_ios_sdk="
        )
        result = self._run_builder_commands(commands, xcodebuild_fails=True)
        self.assertEqual(23, result.returncode, result.stderr)

    def test_clang_version_probe_consumes_all_output(self) -> None:
        commands = self._builder_commands("actual_clang")
        result = self._run_builder_commands(
            commands + '\nprintf "%s\\n" "$actual_clang"'
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("Apple clang version fixture\n", result.stdout)


class DarwinProviderTests(unittest.TestCase):
    def test_workflow_runs_the_builder_through_bash(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/native_audio_darwin.yml").read_text()
        self.assertIn("run: bash scripts/native_audio/build_darwin.sh", workflow)

    def test_both_provider_artifacts_include_source_provenance(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/native_audio_darwin.yml").read_text()
        self.assertEqual(2, workflow.count("build/native-audio/darwin-output/source-provenance.txt"))

    def test_darwin_only_dispatch_skips_windows_effect_validation(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/build_test_only.yml").read_text()
        self.assertIn(
            "if: ${{ inputs.native_audio_only && !inputs.native_audio_android_only && !inputs.native_audio_darwin_only }}",
            workflow,
        )

    def test_builder_records_full_source_tool_sdk_and_patch_provenance(self) -> None:
        builder = (SCRIPT_DIR / "build_darwin.sh").read_text()
        lock = (SCRIPT_DIR / "darwin.lock").read_text()
        recipe_commit = next(
            line.partition("=")[2]
            for line in lock.splitlines()
            if line.startswith("DARWIN_RECIPE_COMMIT=")
        )
        self.assertRegex(recipe_commit, r"^[0-9a-f]{40}$")
        for field in (
            "recipe_commit=%s",
            "developer_dir=%s",
            "macos_sdk_path=%s",
            "ios_sdk_path=%s",
            "ios_simulator_sdk_path=%s",
            "xcode=%s",
            "xcode_build=%s",
            "ios_sdk=%s",
            "macos_sdk=%s",
            "python=%s",
            "go=%s",
            "cmake=%s",
            "meson=%s",
            "ninja=%s",
            "make=GNU Make %s",
            "clang=%s",
            "ios_minimum=%s",
            "macos_minimum=%s",
            "filters=%s,overlay,equalizer",
            "patches=darwin-recipe.patch,libpng-macos-fp-header.patch,ffmpeg-sendcmd-precision.patch,mpv-audio-reinit.patch,mpv-audio-controls.patch,pkg-config-glib-atomics.patch",
            "pkg-config-glib-atomics.patch",
            "upstream_downloads.lock:",
        ):
            self.assertIn(field, builder)
        self.assertIn('export DEVELOPER_DIR="$actual_developer_dir"', builder)
        self.assertIn("rewrite_darwin_sdk_paths.py", builder)
        self.assertIn("--macos-sdk \"$actual_macos_sdk_path\"", builder)
        self.assertIn("--ios-sdk \"$actual_ios_sdk_path\"", builder)
        self.assertIn("--ios-simulator-sdk \"$actual_ios_simulator_sdk_path\"", builder)
        self.assertIn(
            'cp "$script_dir/libpng-macos-fp-header.patch" "$recipe_dir/patches/libpng-macos-fp-header.patch"',
            builder,
        )
        self.assertIn(
            'cp "$script_dir/mpv-audio-controls.patch" "$recipe_dir/patches/mpv-audio-controls.patch"',
            builder,
        )
        self.assertIn(
            'cp "$script_dir/pkg-config-glib-atomics.patch" "$recipe_dir/patches/pkg-config-glib-atomics.patch"',
            builder,
        )

    def test_ninja_lock_matches_pinned_wheel_binary_version(self) -> None:
        lock = (SCRIPT_DIR / "darwin.lock").read_text()
        requirements = (SCRIPT_DIR / "darwin-requirements.txt").read_text()
        builder = (SCRIPT_DIR / "build_darwin.sh").read_text()
        self.assertIn(
            "DARWIN_NINJA_VERSION=1.11.1.git.kitware.jobserver-1",
            lock,
        )
        self.assertIn("ninja==1.11.1.3", requirements)
        self.assertIn(
            'fail "Ninja version is $actual_ninja, expected $DARWIN_NINJA_VERSION"',
            builder,
        )

    def test_provider_makefiles_require_the_run_artifact_without_stock_fallback(self) -> None:
        for makefile in (
            REPO_ROOT / "third_party/media_kit_libs_ios_video/ios/Makefile",
            REPO_ROOT / "third_party/media_kit_libs_macos_video/macos/Makefile",
        ):
            contents = makefile.read_text()
            self.assertIn("darwin-output", contents)
            self.assertIn("Required", contents)
            self.assertNotIn("curl", contents.lower())
            self.assertNotIn("releases/download", contents)

    def test_provider_podspec_propagates_a_missing_archive_failure(self) -> None:
        for podspec in (
            REPO_ROOT / "third_party/media_kit_libs_ios_video/ios/media_kit_libs_ios_video.podspec",
            REPO_ROOT / "third_party/media_kit_libs_macos_video/macos/media_kit_libs_macos_video.podspec",
        ):
            self.assertRegex(podspec.read_text(), r"system\(['\"]make['\"]\).*raise|raise.*system\(['\"]make['\"]\)")


if __name__ == "__main__":
    unittest.main()
