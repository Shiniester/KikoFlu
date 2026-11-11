from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent


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


def _lock_assignments(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#") or line.startswith("source "):
            continue
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


class CommonNativeSourceTests(unittest.TestCase):
    def test_shared_core_sources_are_pinned_once(self) -> None:
        path = SCRIPT_DIR / "common.lock"
        common = _lock_assignments(path)
        expected = {
            "MPV_URL": "https://github.com/mpv-player/mpv.git",
            "MPV_VERSION": "0.42.0",
            "MPV_COMMIT": "b0841e8c4d156b8403dc1876c4cbd9011eb583f3",
            "FFMPEG_URL": "https://github.com/FFmpeg/FFmpeg.git",
            "FFMPEG_VERSION": "9.0.2",
            "FFMPEG_COMMIT": "946fcce07b6dcd0331c8cc609192aeff5e1924f8",
            "LIBPLACEBO_URL": "https://github.com/haasn/libplacebo.git",
            "LIBPLACEBO_VERSION": "7.387.0",
            "LIBPLACEBO_COMMIT": "275f7dea27924cdd34ab2e6c20e448b6bc4fab65",
        }
        self.assertEqual(expected, {key: common.get(key) for key in expected})
        lines = path.read_text().splitlines()
        for key in expected:
            with self.subTest(key=key):
                self.assertEqual(1, sum(line.startswith(f"{key}=") for line in lines))

    def test_android_and_windows_locks_use_common_source_pins(self) -> None:
        shared_keys = {
            "MPV_URL",
            "MPV_VERSION",
            "MPV_COMMIT",
            "FFMPEG_URL",
            "FFMPEG_VERSION",
            "FFMPEG_COMMIT",
            "LIBPLACEBO_URL",
            "LIBPLACEBO_VERSION",
            "LIBPLACEBO_COMMIT",
        }
        for platform in ("android", "windows"):
            with self.subTest(platform=platform):
                lock = (SCRIPT_DIR / f"{platform}.lock").read_text().splitlines()
                self.assertIn(
                    'source "$(dirname -- "${BASH_SOURCE[0]}")/common.lock"',
                    lock,
                )
                values = _lock_assignments(SCRIPT_DIR / f"{platform}.lock")
                self.assertFalse(shared_keys.intersection(values))

    def test_android_builder_fetches_each_common_source_commit(self) -> None:
        builder = (SCRIPT_DIR / "build_android.sh").read_text()
        config = (SCRIPT_DIR / "check_android_config.sh").read_text()
        self.assertIn('source "$script_dir/android.lock"', builder)
        self.assertIn('git -C mpv fetch --depth 1 "$MPV_URL" "$v_mpv"', config)
        self.assertIn(
            'git -C libplacebo fetch --depth 1 "$LIBPLACEBO_URL" "$v_libplacebo"',
            config,
        )
        self.assertIn('v_ffmpeg=$FFMPEG_VERSION', config)
        self.assertIn(
            '+[ ! -d ffmpeg ] && git clone --depth 1 --branch n$v_ffmpeg "$FFMPEG_URL" ffmpeg',
            (SCRIPT_DIR / "android-effects.patch").read_text(),
        )
        self.assertIn('assert_source_commit FFmpeg "$FFMPEG_COMMIT"', builder)
        self.assertIn(
            'cp "$script_dir/android-mpv-java-vm.patch"',
            builder,
        )
        self.assertLess(
            builder.index('cp "$script_dir/android-mpv-java-vm.patch"'),
            builder.index("./patch.sh"),
        )
        java_vm_patch = (SCRIPT_DIR / "android-mpv-java-vm.patch").read_text()
        self.assertIn("diff --git a/include/mpv/client.h b/include/mpv/client.h", java_vm_patch)
        self.assertNotIn("libmpv/client.h", java_vm_patch)
        self.assertIn("MPV_EXPORT int mpv_lavc_set_java_vm(void *vm);", java_vm_patch)
        self.assertIn("av_jni_set_java_vm(vm, NULL)", java_vm_patch)
        for obsolete_patch in (
            "patches/ffmpeg/dash_base_url_escape.patch",
            "patches/ffmpeg/hls_mp4_seek.patch",
            "patches-encoders-gpl/ffmpeg",
        ):
            with self.subTest(obsolete_android_patch=obsolete_patch):
                self.assertIn(obsolete_patch, builder)
                self.assertLess(builder.index(obsolete_patch), builder.index("./patch.sh"))
        self.assertIn("patches/ffmpeg", config)
        self.assertIn("patches-encoders-gpl/ffmpeg", config)
        self.assertIn("mpv_lavc_set_java_vm.patch", config)
        self.assertIn(
            'git -C "$libplacebo_source_dir" submodule update --init --recursive --depth 1',
            builder,
        )
        for path in (
            "3rdparty/glad/glad/__init__.py",
            "3rdparty/jinja/src/jinja2/__init__.py",
            "3rdparty/markupsafe/src/markupsafe/__init__.py",
        ):
            with self.subTest(submodule_path=path):
                self.assertIn(path, builder)
        self.assertIn("ANDROID_API=21", (SCRIPT_DIR / "android.lock").read_text())
        self.assertIn("ANDROID_NDK=27.3.13750724", (SCRIPT_DIR / "android.lock").read_text())
        self.assertIn("v_ndk=27.3.13750724", (SCRIPT_DIR / "android-effects.patch").read_text())
        self.assertIn('ndk_root="$buildscripts_dir/sdk/android-sdk-linux/ndk/$ANDROID_NDK"', builder)
        self.assertIn('python3 -c \'import json,sys;', builder)
        self.assertIn('int(data["min"]) <= api <= int(data["max"])', builder)
        self.assertIn("AAUDIO_FORMAT_IEC61937", builder)
        self.assertLess(builder.index("TRAVIS=1 ./download.sh"), builder.index("python3 -c"))
        self.assertLess(builder.index("python3 -c"), builder.index("AAUDIO_FORMAT_IEC61937"))
        self.assertLess(builder.index("AAUDIO_FORMAT_IEC61937"), builder.index("./patch.sh"))
        self.assertIn("android_mpv_java_vm_patch=%s", builder)
        self.assertIn("android_mbedtls_aesce_patch=%s", builder)

    def test_android_mbedtls_aesce_patch_scopes_crypto_feature_to_functions(self) -> None:
        builder = (SCRIPT_DIR / "build_android.sh").read_text()
        checker = (SCRIPT_DIR / "check_android_config.sh").read_text()
        patch = (SCRIPT_DIR / "android-mbedtls-aesce.patch").read_text()
        self.assertIn('target("crypto")', patch)
        self.assertIn('target("aes")', patch)
        self.assertIn('git -C "$mbedtls_source_dir" apply "$script_dir/android-mbedtls-aesce.patch"', builder)
        self.assertIn('android-mbedtls-aesce.patch', checker)

    def test_windows_pins_core_repositories_through_shared_environment(self) -> None:
        effects = (SCRIPT_DIR / "windows-effects.patch").read_text()
        closure = (SCRIPT_DIR / "windows-git-closure.patch").read_text()
        config = (SCRIPT_DIR / "check_windows_config.sh").read_text()
        builder = (SCRIPT_DIR / "build_windows.sh").read_text()
        self.assertIn("GIT_TAG $ENV{FFMPEG_COMMIT}", effects)
        self.assertIn("GIT_TAG $ENV{MPV_COMMIT}", effects)
        self.assertIn("GIT_TAG $ENV{LIBPLACEBO_COMMIT}", closure)
        self.assertIn("GIT_TAG $ENV{LIBPLACEBO_COMMIT}", config)
        self.assertIn('rm "$source_dir/packages/ffmpeg-dash-base-url-escape.patch"', builder)
        self.assertIn("ffmpeg-dash-base-url-escape.patch", config)
        self.assertIn('export MPV_COMMIT FFMPEG_COMMIT LIBPLACEBO_COMMIT', builder)
        added_effects = [
            line[1:]
            for line in effects.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        ]
        for header in ("client.h", "stream_cb.h", "render.h", "render_gl.h"):
            with self.subTest(mpv_header=header):
                self.assertIn(f"<SOURCE_DIR>/include/mpv/{header}", effects)
                self.assertIn('"<SOURCE_DIR>/include/mpv/$header"', config)
                self.assertTrue(any(f"<SOURCE_DIR>/include/mpv/{header}" in line for line in added_effects))
                self.assertFalse(any(f"<SOURCE_DIR>/libmpv/{header}" in line for line in added_effects))

    def test_ffmpeg_v9_removed_options_are_not_configured(self) -> None:
        android_patch = (SCRIPT_DIR / "android-effects.patch").read_text().splitlines()
        windows_patch = (SCRIPT_DIR / "windows-effects.patch").read_text().splitlines()
        for option in ("--disable-postproc", "--enable-libshaderc"):
            with self.subTest(option=option):
                self.assertTrue(
                    any(line.startswith("-") and option in line for line in windows_patch)
                )
                if option == "--disable-postproc":
                    self.assertTrue(
                        any(line.startswith("-") and option in line for line in android_patch)
                    )
                self.assertIn(option[2:], (SCRIPT_DIR / "check_android_config.sh").read_text())
                self.assertIn(option[2:], (SCRIPT_DIR / "check_windows_config.sh").read_text())

    def test_windows_tls_keeps_openssl_srtp_api_and_https_enabled(self) -> None:
        effects = (SCRIPT_DIR / "windows-effects.patch").read_text()
        config = (SCRIPT_DIR / "check_windows_config.sh").read_text()
        self.assertIn("-        no-srtp", effects)
        self.assertIn("        no-srtp", config)
        self.assertIn("--enable-openssl", config)
        self.assertIn("for protocol in https tls; do", config)

    def test_old_mpv_reinit_patch_is_not_reapplied(self) -> None:
        for name in (
            "build_android.sh",
            "build_windows.sh",
        ):
            with self.subTest(file=name):
                self.assertNotIn("apply_mpv_audio_reinit", (SCRIPT_DIR / name).read_text())


class SharedNativePatchTests(unittest.TestCase):
    def test_shared_patch_contracts_pass_their_cli_checks(self) -> None:
        bash = _bash_executable()
        if bash is None:
            self.skipTest("Bash is required to validate native source patch contracts")
        for helper, patch in (
            ("apply_mpv_audio_controls.sh", "mpv-audio-controls.patch"),
            ("apply_ffmpeg_sendcmd_precision.sh", "ffmpeg-sendcmd-precision.patch"),
        ):
            with self.subTest(helper=helper):
                result = subprocess.run(
                    [
                        bash,
                        str(SCRIPT_DIR / helper),
                        "--check-patch",
                        str(SCRIPT_DIR / patch),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(0, result.returncode, result.stderr)

    def test_patch_checker_rejects_invalid_patch_input(self) -> None:
        bash = _bash_executable()
        if bash is None:
            self.skipTest("Bash is required to validate native source patch contracts")
        with tempfile.TemporaryDirectory() as temporary:
            patch = Path(temporary) / "invalid.patch"
            patch.write_text("not a git patch\n")
            result = subprocess.run(
                [
                    bash,
                    str(SCRIPT_DIR / "apply_mpv_audio_controls.sh"),
                    "--check-patch",
                    str(patch),
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("patch format is invalid", result.stderr)


if __name__ == "__main__":
    unittest.main()
