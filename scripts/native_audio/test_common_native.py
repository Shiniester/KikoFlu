from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
import zipfile
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

    def test_windows_native_tls_patch_is_wired_into_static_ffmpeg_build(self) -> None:
        builder = (SCRIPT_DIR / "build_windows.sh").read_text()
        checker = (SCRIPT_DIR / "check_windows_config.sh").read_text()
        self.assertIn(
            'cp "$script_dir/windows-ffmpeg-native-trust.patch" "$source_dir/packages/ffmpeg-windows-native-trust.patch"',
            builder,
        )
        self.assertIn('ffmpeg-windows-native-trust.patch', checker)
        self.assertIn('cmp -s "$script_dir/windows-ffmpeg-native-trust.patch"', checker)
        self.assertIn('--pkg-config-flags=--static', checker)
        patch_stats = subprocess.run(
            ["git", "apply", "--numstat", str(SCRIPT_DIR / "windows-ffmpeg-native-trust.patch")],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(0, patch_stats.returncode, patch_stats.stderr)
        self.assertEqual(
            ["libavformat/tls_openssl.c"],
            [line.split("\t", 2)[2] for line in patch_stats.stdout.splitlines()],
        )

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


class WindowsOutputCacheTests(unittest.TestCase):
    def test_cache_key_fingerprints_only_windows_build_inputs_and_steps(self) -> None:
        workflow = (SCRIPT_DIR.parents[1] / ".github/workflows/native_audio.yml").read_text()
        cache_step = workflow.split(
            "      - name: Restore Windows libmpv output cache\n", 1
        )[1].split("\n      - name:", 1)[0]
        key_line = next(line for line in cache_step.splitlines() if "key:" in line)
        input_line = next(
            line
            for line in workflow.splitlines()
            if "INPUT_FINGERPRINT: ${{ hashFiles(" in line
        )
        hashed_files = set(
            re.findall(r"scripts/native_audio/([A-Za-z0-9_.-]+)", input_line)
        )
        script_references = set(
            re.findall(
                r"\$script_dir/([A-Za-z0-9_.-]+)",
                (SCRIPT_DIR / "build_windows.sh").read_text()
                + (SCRIPT_DIR / "check_windows_config.sh").read_text(),
            )
        ) - {".."}
        self.assertNotIn("scripts/native_audio/**", key_line)
        self.assertIn("steps.windows-inputs.outputs.fingerprint", key_line)
        self.assertIn("steps.windows-workflow.outputs.fingerprint", key_line)
        self.assertTrue(script_references.issubset(hashed_files))
        self.assertIn("scripts/native_audio/requirements.txt", input_line)
        self.assertIn("scripts/native_audio/filters.txt", input_line)

    def test_only_complete_exact_hits_are_reused(self) -> None:
        bash = _bash_executable()
        if bash is None:
            self.skipTest("Bash is required to validate the Windows output cache")

        root = SCRIPT_DIR.parents[1]
        workflow = (root / ".github/workflows/native_audio.yml").read_text()
        step = workflow.split("      - name: Check restored Windows libmpv output\n", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        pins = _lock_assignments(SCRIPT_DIR / "common.lock") | _lock_assignments(
            SCRIPT_DIR / "windows.lock"
        )
        provenance = {
            "recipe_ref": pins["RECIPE_COMMIT"],
            "mpv_commit": pins["MPV_COMMIT"],
            "ffmpeg_commit": pins["FFMPEG_COMMIT"],
            "compiler_bundle": pins["LLVM_MINGW_DIR"],
            "target_arch": pins["TARGET_ARCH"],
            "rust_version": pins["RUST_VERSION"],
            "rust_target": pins["RUST_TARGET"],
            "cargo_c_version": pins["CARGO_C_VERSION"],
        }
        files = (
            "mpv-dev/libmpv-2.dll",
            "mpv-dev/include/mpv/client.h",
            "mpv-dev/include/mpv/stream_cb.h",
            "mpv-dev/include/mpv/render.h",
            "mpv-dev/include/mpv/render_gl.h",
            "vulkan-smoke.exe",
        )
        with tempfile.TemporaryDirectory() as temporary:
            for scenario in ("miss", "valid", "missing", "stale"):
                with self.subTest(scenario=scenario):
                    directory = Path(temporary) / scenario
                    output = directory / "output"
                    for name in files:
                        path = output / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_text("fixture")
                    records = dict(provenance)
                    if scenario == "missing":
                        (output / "mpv-dev/include/mpv/client.h").unlink()
                    if scenario == "stale":
                        records["mpv_commit"] = "outdated"
                    (output / "source-provenance.txt").write_text(
                        "".join(f"{key}={value}\n" for key, value in records.items())
                    )
                    result_file = directory / "github-output"
                    result = subprocess.run(
                        [bash, "--noprofile", "--norc", "-c", script],
                        cwd=root,
                        env={
                            **os.environ,
                            "WINDOWS_OUTPUT_CACHE_HIT": (
                                "false" if scenario == "miss" else "true"
                            ),
                            "NATIVE_AUDIO_OUTPUT_DIR": output.as_posix(),
                            "GITHUB_OUTPUT": result_file.as_posix(),
                        },
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)
                    valid = scenario == "valid"
                    self.assertIn(f"valid={str(valid).lower()}", result_file.read_text())
                    self.assertEqual(valid, output.exists())


class AndroidNativeOutputTests(unittest.TestCase):
    def test_android_build_and_gradle_keep_only_the_supported_abis(self) -> None:
        builder = (SCRIPT_DIR / "build_android.sh").read_text()
        android_patch = (SCRIPT_DIR / "android-effects.patch").read_text()
        config = (SCRIPT_DIR / "check_android_config.sh").read_text()
        gradle = (
            SCRIPT_DIR.parents[1]
            / "third_party/media_kit_libs_android_video/android/build.gradle"
        ).read_text()
        workflow = (SCRIPT_DIR.parents[1] / ".github/workflows/native_audio.yml").read_text()

        self.assertIn("all) arches=(arm64 x86_64)", builder)
        self.assertNotIn("armv7l) abi=", builder)
        self.assertNotIn("x86) abi=", builder)
        self.assertIn("+archs=(arm64 x86_64)", android_patch)
        self.assertIn("archs=(arm64 x86_64)", config)
        self.assertIn('supportedNativeAudioAbis = ["arm64-v8a", "x86_64"]', gradle)
        self.assertIn('project.findProperty("target-platform")', gradle)
        self.assertIn('"android-arm64": "arm64-v8a", "android-x64": "x86_64"', gradle)
        self.assertIn("if (targetPlatforms != null)", gradle)
        self.assertIn("nativeAudioAbis = supportedNativeAudioAbis", gradle)
        self.assertIn("Custom libmpv does not support Flutter target platform", gradle)
        self.assertIn('fromJSON(\'["arm64","x86_64"]\')', workflow)
        self.assertIn("name: native-audio-android-${{ matrix.arch }}", workflow)
        self.assertIn("name: native-audio-android\n", workflow)
        self.assertIn("Only exact cache hits may be reused.", workflow)
        self.assertIn("Fingerprint Android build workflow", workflow)
        self.assertIn("steps.android-workflow.outputs.fingerprint", workflow)
        self.assertIn("needs: [validate-inputs, build-android]", workflow)
        self.assertIn('[[ -s "$OUTPUT_DIR/default-$abi.jar" ]] ||', workflow)
        self.assertIn("native-audio-android-arm64", workflow)
        self.assertIn("native-audio-android-x86_64", workflow)
        self.assertIn("Restore Windows libmpv output cache", workflow)
        self.assertIn("probe-windows:", workflow)

    def test_android_output_validator_rejects_incomplete_or_stale_cache_entries(self) -> None:
        bash = _bash_executable()
        if bash is None:
            self.skipTest("Bash is required to validate Android native output")
        probe = subprocess.run(
            [bash, "--noprofile", "--norc", "-c", "exit 0"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if probe.returncode != 0:
            self.skipTest(f"Git Bash cannot start in this host: {probe.stderr.strip()}")

        android_pins = _lock_assignments(SCRIPT_DIR / "android.lock")
        common_pins = _lock_assignments(SCRIPT_DIR / "common.lock")
        pins = {**common_pins, **android_pins}
        filters = ",".join((SCRIPT_DIR / "filters.txt").read_text().splitlines())
        validator = SCRIPT_DIR / "build_android.sh"
        scenarios = (
            "valid",
            "missing-jar-entry",
            "wrong-machine",
            "stale-provenance",
            "arm64-root-provenance",
            "mismatched-arm64-root",
        )

        with tempfile.TemporaryDirectory() as temporary:
            for arch in ("arm64", "x86_64"):
                abi = "arm64-v8a" if arch == "arm64" else "x86_64"
                expected_machine = (
                    "AArch64" if arch == "arm64" else "Advanced Micro Devices X86-64"
                )
                for scenario in scenarios:
                    with self.subTest(arch=arch, scenario=scenario):
                        output = Path(temporary) / arch / scenario / "output"
                        output.mkdir(parents=True)
                        payloads = {
                            f"lib/{abi}/libmpv.so": b"fixture libmpv",
                            f"lib/{abi}/libmediakitandroidhelper.so": b"fixture helper",
                        }
                        if scenario == "missing-jar-entry":
                            payloads.pop(f"lib/{abi}/libmediakitandroidhelper.so")
                        with zipfile.ZipFile(output / f"default-{abi}.jar", "w") as archive:
                            for name, payload in payloads.items():
                                archive.writestr(name, payload)
                        abi_dir = output / abi
                        abi_dir.mkdir()
                        (abi_dir / "libmpv.so").write_bytes(b"fixture libmpv")
                        (abi_dir / "libmediakitandroidhelper.so").write_bytes(
                            b"fixture helper"
                        )

                        records = {
                            "builder_url": pins["ANDROID_BUILDER_URL"],
                            "builder_ref": pins["ANDROID_BUILDER_REF"],
                            "builder_commit": pins["ANDROID_BUILDER_COMMIT"],
                            "android_helper_commit": pins["ANDROID_HELPER_COMMIT"],
                            "ffmpeg_version": pins["FFMPEG_VERSION"],
                            "ffmpeg_commit": pins["FFMPEG_COMMIT"],
                            "mpv_version": pins["MPV_VERSION"],
                            "mpv_commit": pins["MPV_COMMIT"],
                            "libplacebo_version": pins["LIBPLACEBO_VERSION"],
                            "libplacebo_commit": pins["LIBPLACEBO_COMMIT"],
                            "gas_preprocessor_commit": pins[
                                "GAS_PREPROCESSOR_COMMIT"
                            ],
                            "android_api": pins["ANDROID_API"],
                            "android_sdk_tools": pins["ANDROID_SDK_TOOLS"],
                            "android_build_tools": pins["ANDROID_BUILD_TOOLS"],
                            "android_ndk": pins["ANDROID_NDK"],
                            "cxx_runtime": "libc++_shared.so",
                            "meson": "1.0-test",
                            "ninja": "1.0-test",
                            "mpv_audio_controls_patch": "mpv-audio-controls.patch",
                            "android_mpv_java_vm_patch": "android-mpv-java-vm.patch",
                            "android_mbedtls_aesce_patch": "android-mbedtls-aesce.patch",
                            "ffmpeg_sendcmd_argument_format": "%.17g",
                            "architectures": arch,
                            "android_arch": arch,
                            "android_abi": abi,
                            "runner_image": "Ubuntu-22.04-test-image",
                            "input_fingerprint": "test-input-fingerprint",
                            "toolchain_fingerprint": "test-toolchain-fingerprint",
                            "filters": f"{filters},overlay,equalizer",
                        }
                        if scenario == "stale-provenance":
                            records["mpv_commit"] = "stale"
                        provenance = "".join(
                            f"{key}={value}\n" for key, value in records.items()
                        )
                        root_provenance = provenance
                        if scenario == "arm64-root-provenance" and arch == "x86_64":
                            root_records = dict(records)
                            root_records.update(
                                android_arch="arm64",
                                android_abi="arm64-v8a",
                                architectures="arm64",
                            )
                            root_provenance = "".join(
                                f"{key}={value}\n" for key, value in root_records.items()
                            )
                        if scenario == "mismatched-arm64-root" and arch == "arm64":
                            root_provenance = provenance.replace(
                                "input_fingerprint=test-input-fingerprint",
                                "input_fingerprint=stale-input-fingerprint",
                            )
                        (output / "source-provenance.txt").write_text(root_provenance)
                        (output / f"source-provenance-{abi}.txt").write_text(provenance)

                        command = textwrap.dedent(
                            """
                            set -euo pipefail
                            readelf() {
                              case " $* " in
                                *" -h "*) printf '  Machine: %s\\n' "$TEST_ELF_MACHINE" ;;
                                *" -d "*) printf '  Shared library: [libc++_shared.so]\\n' ;;
                                *" -l "*) printf '  LOAD 0x0 0x0 0x0 0x0 0x0 0x0 R E 0x4000\\n' ;;
                                *) return 1 ;;
                              esac
                            }
                            source "$NATIVE_AUDIO_ANDROID_VALIDATOR" --validate-output "$ANDROID_ARCH"
                            """
                        )
                        machine = (
                            "Intel 80386"
                            if scenario == "wrong-machine"
                            else expected_machine
                        )
                        result = subprocess.run(
                            [bash, "--noprofile", "--norc", "-c", command],
                            cwd=SCRIPT_DIR.parents[1],
                            env={
                                **os.environ,
                                "NATIVE_AUDIO_ANDROID_VALIDATOR": validator.as_posix(),
                                "NATIVE_AUDIO_ANDROID_OUTPUT_DIR": output.as_posix(),
                                "NATIVE_AUDIO_ANDROID_RUNNER_IMAGE": records[
                                    "runner_image"
                                ],
                                "NATIVE_AUDIO_ANDROID_INPUT_FINGERPRINT": records[
                                    "input_fingerprint"
                                ],
                                "NATIVE_AUDIO_ANDROID_TOOLCHAIN_FINGERPRINT": records[
                                    "toolchain_fingerprint"
                                ],
                                "NATIVE_AUDIO_ANDROID_MESON_VERSION": records[
                                    "meson"
                                ],
                                "NATIVE_AUDIO_ANDROID_NINJA_VERSION": records[
                                    "ninja"
                                ],
                                "ANDROID_ARCH": arch,
                                "TEST_ELF_MACHINE": machine,
                            },
                            capture_output=True,
                            text=True,
                            timeout=10,
                        )
                        should_pass = scenario in {"valid", "arm64-root-provenance"} or (
                            scenario == "mismatched-arm64-root" and arch == "x86_64"
                        )
                        self.assertEqual(0 if should_pass else 1, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
