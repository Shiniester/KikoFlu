from __future__ import annotations

import os
import plistlib
import re
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
    def test_recipe_patch_is_applied_to_the_pinned_recipe(self) -> None:
        recipe_dir = os.environ.get("DARWIN_RECIPE_SOURCE_DIR")
        if not recipe_dir:
            recipe_dir = str(
                REPO_ROOT / "build/native-audio-upgrade/darwin/libmpv-darwin-build"
            )
        recipe = Path(recipe_dir)
        if not recipe.is_dir() or not (recipe / "downloads.lock").is_file():
            self.skipTest("the pinned Darwin recipe is available after the builder fetches it")

        with tempfile.TemporaryDirectory() as temporary:
            patch_file = _normalized_patch(SCRIPT_DIR / "darwin-recipe.patch", Path(temporary))
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(recipe),
                    "apply",
                    "--unidiff-zero",
                    "--reverse",
                    "--check",
                    str(patch_file),
                ],
                check=True,
            )
        ffmpeg_options = (recipe / "scripts/ffmpeg/meson.build").read_text(encoding="utf-8")
        mpv_build = (recipe / "scripts/mpv/build.sh").read_text(encoding="utf-8")
        ffmpeg_build = (recipe / "scripts/ffmpeg/build.sh").read_text(encoding="utf-8")
        makefile = (recipe / "Makefile").read_text(encoding="utf-8")
        libplacebo_build = (recipe / "scripts/libplacebo/build.sh").read_text(encoding="utf-8")
        pkgconfig_build = (recipe / "scripts/pkg-config/build.sh").read_text(encoding="utf-8")
        freetype_build = (recipe / "scripts/freetype/build.sh").read_text(encoding="utf-8")
        audio_default_options = ffmpeg_options.split(
            "audio_default_options = [", 1
        )[1].split("\n]", 1)[0]
        actual_filters = {
            line.split("=", 1)[1].strip("', ")
            for line in audio_default_options.splitlines()
            if "--enable-filter=" in line
        }
        expected_filters = set((SCRIPT_DIR / "filters.txt").read_text().splitlines()) | {
            "overlay",
            "equalizer",
        }
        self.assertEqual(expected_filters, actual_filters)
        self.assertNotIn("--enable-filters", audio_default_options)
        self.assertIn("mpv-audio-controls.patch", mpv_build)
        self.assertNotIn("mpv-audio-reinit.patch", mpv_build)
        self.assertNotIn("mpv-filter-command-target.patch", mpv_build)
        self.assertIn("ffmpeg-sendcmd-precision.patch", ffmpeg_build)
        self.assertIn("ffmpeg-fix-ios-hdr-texture.patch", ffmpeg_build)
        self.assertIn("release_version=$(cat RELEASE)", ffmpeg_build)
        self.assertIn("${INTERMEDIATE_DIR}/libplacebo_", makefile)
        self.assertIn("-Dopengl=enabled", libplacebo_build)
        self.assertIn("for dependency in fast_float glad jinja markupsafe", libplacebo_build)
        self.assertIn("libplacebo-darwin-charconv.patch", libplacebo_build)
        self.assertIn("-mmacosx-version-min=10.15", libplacebo_build)
        self.assertIn("-miphoneos-version-min=13.0", libplacebo_build)
        self.assertIn("-mios-simulator-version-min=13.0", libplacebo_build)
        self.assertIn(
            'patch -p1 < "${PROJECT_DIR}/patches/pkg-config-glib-atomics.patch"',
            pkgconfig_build,
        )
        self.assertIn("cd subprojects/libpng-1.6.40", freetype_build)
        libpng_patch_command = (
            'patch -p1 < "${PROJECT_DIR}/patches/libpng-macos-fp-header.patch"'
        )
        self.assertIn(libpng_patch_command, freetype_build)
        self.assertLess(
            freetype_build.index("meson setup build"),
            freetype_build.index(libpng_patch_command),
        )
        self.assertLess(
            freetype_build.index(libpng_patch_command),
            freetype_build.index("meson compile -C build"),
        )
        self.assertIn(
            "libplacebo-glad", (recipe / "downloads.lock").read_text(encoding="utf-8")
        )
        self.assertIn(
            "libplacebo-fast_float", (recipe / "downloads.lock").read_text(encoding="utf-8")
        )
        simulator_arm64_cross_file = recipe / "cross-files/iossimulator-arm64.ini"
        simulator_arm64_contents = simulator_arm64_cross_file.read_text(encoding="utf-8")
        self.assertRegex(
            simulator_arm64_contents,
            r"-m(?:iphoneos|ios-simulator)-version-min=12\.0",
        )
        simulator_case = libplacebo_build.split("iossimulator)", 1)[1].split(";;", 1)[0]
        simulator_expressions = re.findall(
            r"sed_expression='([^']+)'", simulator_case
        )
        expression = next(item for item in simulator_expressions if "12[.]0" in item)
        simulator_arm64_contents = simulator_arm64_contents.replace(
            "-miphoneos-version-min=", "-mios-simulator-version-min="
        )
        rewritten = subprocess.run(
            ["sed", expression],
            input=simulator_arm64_contents,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertIn("-mios-simulator-version-min=13.0", rewritten)
        self.assertNotIn("-mios-simulator-version-min=12.0", rewritten)

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
                [
                    "git",
                    "-C",
                    str(root),
                    "apply",
                    "--unidiff-zero",
                    "--check",
                    str(recipe_patch),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(0, result.returncode)

    def test_ffmpeg_release_metadata_matches_the_download_lock(self) -> None:
        recipe_dir = os.environ.get("DARWIN_RECIPE_SOURCE_DIR")
        if not recipe_dir:
            recipe_dir = str(
                REPO_ROOT / "build/native-audio-upgrade/darwin/libmpv-darwin-build"
            )
        recipe = Path(recipe_dir)
        ffmpeg_build = recipe / "scripts/ffmpeg/build.sh"
        if not ffmpeg_build.is_file():
            self.skipTest("the pinned Darwin recipe is available after the builder fetches it")
        bash = _bash_executable()
        if bash is None:
            self.skipTest("Bash is required to verify FFmpeg release metadata")

        build_script = ffmpeg_build.read_text(encoding="utf-8")
        version_setup = build_script.split(
            "patch -p1 <${PROJECT_DIR}/patches/ffmpeg-fix-ios-hdr-texture.patch",
            1,
        )[0]
        self.assertIn("version_lock=$(grep -A1", version_setup)

        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            (project / "downloads.lock").write_text(
                "ffmpeg:\n  version: 9.0.2\n", encoding="utf-8"
            )
            source = project / "build/tmp/ffmpeg"
            source.mkdir(parents=True)
            (source / "RELEASE").write_text("9.0.2\n", encoding="utf-8")
            environment = os.environ.copy()
            environment["PROJECT_DIR"] = str(project)
            environment["SRC_DIR"] = str(source)
            result = subprocess.run(
                [bash, "-c", version_setup],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("9.0.2\n", (source / "VERSION").read_text(encoding="utf-8"))

            mismatch_source = project / "build/tmp/ffmpeg-mismatch"
            mismatch_source.mkdir(parents=True)
            (mismatch_source / "RELEASE").write_text("9.0.1\n", encoding="utf-8")
            environment["SRC_DIR"] = str(mismatch_source)
            mismatch = subprocess.run(
                [bash, "-c", version_setup],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )
            self.assertNotEqual(0, mismatch.returncode)
            self.assertFalse((mismatch_source / "VERSION").exists())

    def test_fixed_sources_keep_upstream_fixes_and_accept_darwin_audio_patches(self) -> None:
        source_dir = os.environ.get("DARWIN_NATIVE_SOURCE_DIR")
        if not source_dir:
            source_dir = str(REPO_ROOT / "build/native-audio-upgrade/darwin")
        sources = Path(source_dir)
        mpv_root = sources / "mpv"
        ffmpeg_root = sources / "ffmpeg"
        libplacebo_root = sources / "libplacebo"
        pkg_config_root = sources / "pkg-config"
        if (
            not (mpv_root / "MPV_VERSION").is_file()
            or not (ffmpeg_root / "RELEASE").is_file()
            or not (libplacebo_root / "src/convert.cc").is_file()
            or not (pkg_config_root / "glib/glib/gatomic.c").is_file()
        ):
            self.skipTest("the pinned native sources are available after download")

        common_lock = (SCRIPT_DIR / "common.lock").read_text().splitlines()
        pins = dict(
            line.split("=", 1)
            for line in common_lock
            if line.startswith(("MPV_VERSION=", "MPV_COMMIT=", "FFMPEG_VERSION=", "FFMPEG_COMMIT="))
        )
        self.assertEqual(pins["MPV_VERSION"], (mpv_root / "MPV_VERSION").read_text().strip())
        self.assertEqual(pins["FFMPEG_VERSION"], (ffmpeg_root / "RELEASE").read_text().strip())
        for source, expected in ((mpv_root, pins["MPV_COMMIT"]), (ffmpeg_root, pins["FFMPEG_COMMIT"])):
            git_dir = source / ".git"
            if git_dir.exists():
                actual = subprocess.run(
                    ["git", "-C", str(source), "rev-parse", "HEAD"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                self.assertEqual(expected, actual)

        mpv_audio = (mpv_root / "player/audio.c").read_text(encoding="utf-8")
        mpv_command = (mpv_root / "player/command.c").read_text(encoding="utf-8")
        mpv_filter_header = (mpv_root / "filters/filter.h").read_text(encoding="utf-8")
        ffmpeg_vp9 = (ffmpeg_root / "libavcodec/vp9.c").read_text(encoding="utf-8")
        ffmpeg_hls = (ffmpeg_root / "libavformat/hls.c").read_text(encoding="utf-8")
        ffmpeg_dash = (ffmpeg_root / "libavformat/dashdec.c").read_text(encoding="utf-8")
        reinit_audio = mpv_audio.split(
            "static int reinit_audio_filters_and_output", 1
        )[1].split("static bool ao_chain_init_decoder", 1)[0]
        self.assertNotIn("ao_is_playing(mpctx->ao)", reinit_audio)
        self.assertNotIn("Wait until all played", reinit_audio)
        self.assertIn("uninit_audio_out(mpctx);", reinit_audio)
        self.assertIn(".target = cmd->args[3].v.s", mpv_command)
        self.assertIn("const char *target;", mpv_filter_header)
        self.assertIn("HWACCEL_VIDEOTOOLBOX(vp9)", ffmpeg_vp9)
        self.assertIn("pls->cur_init_section = NULL;", ffmpeg_hls)
        self.assertGreaterEqual(ffmpeg_dash.count("xmlEncodeSpecialChars(NULL,"), 2)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            patch_cases = (
                (
                    "mpv-audio-controls.patch",
                    mpv_root,
                    ["filters/f_lavfi.c"],
                ),
                (
                    "ffmpeg-sendcmd-precision.patch",
                    ffmpeg_root,
                    ["libavfilter/f_sendcmd.c"],
                ),
                (
                    "darwin-ffmpeg-ios-hdr.patch",
                    ffmpeg_root,
                    ["libavcodec/videotoolbox.c", "libavutil/hwcontext_videotoolbox.c"],
                ),
                (
                    "darwin-libplacebo-charconv.patch",
                    libplacebo_root,
                    ["src/convert.cc"],
                ),
                (
                    "pkg-config-glib-atomics.patch",
                    pkg_config_root,
                    ["glib/glib/gatomic.c", "glib/glib/gatomic.h"],
                ),
            )
            for patch_name, source_root, source_files in patch_cases:
                case_root = root / Path(patch_name).stem
                for relative in source_files:
                    destination = case_root / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source_root / relative, destination)
                subprocess.run(["git", "init", "-q", str(case_root)], check=True)
                subprocess.run(["git", "-C", str(case_root), "add", "."], check=True)
                patch_path = _normalized_patch(SCRIPT_DIR / patch_name, case_root)
                subprocess.run(
                    ["git", "-C", str(case_root), "apply", "--check", str(patch_path)],
                    check=True,
                )
                subprocess.run(
                    ["git", "-C", str(case_root), "apply", str(patch_path)],
                    check=True,
                )
                if patch_name == "darwin-libplacebo-charconv.patch":
                    convert = (case_root / "src/convert.cc").read_text(encoding="utf-8")
                    self.assertIn("# define HAS_STD_TO_CHARS_FP 0", convert)
                if patch_name == "pkg-config-glib-atomics.patch":
                    atomic_c = (case_root / "glib/glib/gatomic.c").read_text(encoding="utf-8")
                    atomic_h = (case_root / "glib/glib/gatomic.h").read_text(encoding="utf-8")
                    pointer_macros = atomic_h.split(
                        "#define g_atomic_pointer_add(atomic, val)", 1
                    )[1].split("#else /* defined(G_ATOMIC_LOCK_FREE)", 1)[0]
                    self.assertIn("gintptr\n(g_atomic_pointer_add)", atomic_c)
                    self.assertIn("guintptr\n(g_atomic_pointer_and)", atomic_c)
                    for operation in ("add", "and", "or", "xor"):
                        self.assertIn(
                            f"__atomic_fetch_{operation}", pointer_macros
                        )
                    self.assertNotIn("__sync_fetch_and_", pointer_macros)

            patched_lavfi = (root / "mpv-audio-controls/filters/f_lavfi.c").read_text(
                encoding="utf-8"
            )
            patched_sendcmd = (
                root / "ffmpeg-sendcmd-precision/libavfilter/f_sendcmd.c"
            ).read_text(encoding="utf-8")
            patched_hdr_codec = (
                root / "darwin-ffmpeg-ios-hdr/libavcodec/videotoolbox.c"
            ).read_text(encoding="utf-8")
            patched_hdr_hwctx = (
                root / "darwin-ffmpeg-ios-hdr/libavutil/hwcontext_videotoolbox.c"
            ).read_text(encoding="utf-8")
            self.assertIn("replay_lavfi_commands(c)", patched_lavfi)
            self.assertIn('av_asprintf("%.17g", res)', patched_sendcmd)
            self.assertIn("#if TARGET_OS_IPHONE", patched_hdr_codec)
            self.assertIn("return AV_PIX_FMT_BGRA;", patched_hdr_codec)
            self.assertIn("return AV_PIX_FMT_P010;", patched_hdr_codec)
            self.assertIn("kCVPixelFormatType_32BGRA,                        false, AV_PIX_FMT_BGRA", patched_hdr_hwctx)

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

            for patch_file in (
                "mpv-audio-controls.patch",
                "ffmpeg-sendcmd-precision.patch",
                "darwin-ffmpeg-ios-hdr.patch",
            ):
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

    def test_ios_simulator_minimum_accounts_for_arm64_platform_floor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "ios.tar.gz"
            _write_archive(archive, "ios")

            def minimum_os(binary: Path, architecture: str) -> str:
                simulator = "ios-arm64_x86_64-simulator" in binary.parts
                minimum = "14.0" if simulator and architecture == "arm64" else "13.0"
                return f"Mach build version\n    minos {minimum}\n"

            validate_archive(archive, "ios", "13.0", vtool_runner=minimum_os)

            for variant, architecture, too_new in (
                ("simulator", "arm64", "14.1"),
                ("simulator", "x86_64", "13.1"),
                ("device", "arm64", "13.1"),
            ):
                def too_new_minimum(binary: Path, target_architecture: str) -> str:
                    simulator = "ios-arm64_x86_64-simulator" in binary.parts
                    target_variant = "simulator" if simulator else "device"
                    if (target_variant, target_architecture) == (variant, architecture):
                        return f"Mach build version\n    minos {too_new}\n"
                    return minimum_os(binary, target_architecture)

                with self.subTest(variant=variant, architecture=architecture):
                    with self.assertRaisesRegex(
                        ArtifactError,
                        rf"ios {variant} {architecture} minos {too_new} exceeds",
                    ):
                        validate_archive(
                            archive, "ios", "13.0", vtool_runner=too_new_minimum
                        )

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
    def test_rewrites_sdks_and_preserves_simulator_deployment_versions(self) -> None:
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
                "c_link_args = ['-miphoneos-version-min=12.0']\n"
            )
            (cross_files / "iossimulator-amd64.ini").write_text(
                "c_args = ['-isysroot', '/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk', '-miphoneos-version-min=9.0']\n"
                "c_link_args = ['-miphoneos-version-min=9.0']\n"
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
            self.assertEqual(2, simulator_contents.count("-mios-simulator-version-min=12.0"))
            self.assertNotIn("-miphoneos-version-min=", simulator_contents)
            simulator_amd64 = (cross_files / "iossimulator-amd64.ini").read_text()
            self.assertEqual(2, simulator_amd64.count("-mios-simulator-version-min=9.0"))
            self.assertNotIn("-miphoneos-version-min=", simulator_amd64)

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
            "mpv_source_version=%s",
            "mpv_source_commit=%s",
            "ffmpeg_source_version=%s",
            "ffmpeg_source_commit=%s",
            "libplacebo_source_version=%s",
            "libplacebo_source_commit=%s",
            "ios_minimum=%s",
            "macos_minimum=%s",
            "filters=%s,overlay,equalizer",
            "patches=darwin-recipe.patch,darwin-download-retry.patch,libpng-macos-fp-header.patch,darwin-ffmpeg-ios-hdr.patch,darwin-libplacebo-charconv.patch,ffmpeg-sendcmd-precision.patch,mpv-audio-controls.patch,pkg-config-glib-atomics.patch",
            "libmpv-xcframeworks_${DARWIN_OUTPUT_VERSION}_ios-universal-video-default.tar.gz",
            "libmpv-xcframeworks_${DARWIN_OUTPUT_VERSION}_macos-universal-video-default.tar.gz",
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
            'cp "$script_dir/darwin-ffmpeg-ios-hdr.patch" "$recipe_dir/patches/ffmpeg-fix-ios-hdr-texture.patch"',
            builder,
        )
        self.assertIn(
            'cp "$script_dir/darwin-libplacebo-charconv.patch" "$recipe_dir/patches/libplacebo-darwin-charconv.patch"',
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
