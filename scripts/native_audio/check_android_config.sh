#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/android.lock"
source_dir=${1:?Usage: check_android_config.sh <libmpv-android-video-build source>}
depinfo="$source_dir/buildscripts/include/depinfo.sh"
download_deps="$source_dir/buildscripts/include/download-deps.sh"
download_sdk="$source_dir/buildscripts/include/download-sdk.sh"
ffmpeg_config="$source_dir/buildscripts/flavors/default.sh"

fail() {
    printf 'Android native audio build config: %s\n' "$1" >&2
    exit 1
}

grep -Fqx "v_sdk=$ANDROID_SDK_TOOLS" "$depinfo" || fail "Android command-line tools ref changed"
grep -Fqx "v_ndk=$ANDROID_NDK" "$depinfo" || fail "Android NDK ref changed"
grep -Fqx "v_sdk_build_tools=$ANDROID_BUILD_TOOLS" "$depinfo" || fail "Android build-tools ref changed"
grep -Fqx 'v_ffmpeg=$FFMPEG_VERSION' "$depinfo" || fail "FFmpeg version ref changed"
grep -Fqx 'v_mpv=$MPV_COMMIT' "$depinfo" || fail "mpv source commit changed"
grep -Fqx 'v_libplacebo=$LIBPLACEBO_COMMIT' "$depinfo" || fail "libplacebo source commit changed"
grep -Eq "^[[:space:]]*local apilvl=$ANDROID_API$" "$source_dir/buildscripts/build.sh" ||
    fail "Android native API level changed"
if [[ -e "$source_dir/buildscripts/patches/ffmpeg" ]]; then
    fail "FFmpeg 9.0.2 already includes the Android FFmpeg patch behaviors"
fi
if [[ -e "$source_dir/buildscripts/patches-encoders-gpl/ffmpeg" || -L "$source_dir/buildscripts/patches-encoders-gpl/ffmpeg" ]]; then
    fail "Android GPL patch tree must not retain the obsolete FFmpeg patch link"
fi
[[ -s "$source_dir/buildscripts/patches/mpv/mpv_lavc_set_java_vm.patch" ]] ||
    fail "Android mpv Java VM patch is missing"
cmp -s "$script_dir/android-mpv-java-vm.patch" \
    "$source_dir/buildscripts/patches/mpv/mpv_lavc_set_java_vm.patch" ||
    fail "Android mpv Java VM patch differs from the checked patch"
grep -Fq 'include/mpv/client.h' "$script_dir/android-mpv-java-vm.patch" ||
    fail "Android mpv Java VM patch must use the mpv 0.42 public header path"
grep -Fq 'MPV_EXPORT int mpv_lavc_set_java_vm(void *vm);' "$script_dir/android-mpv-java-vm.patch" ||
    fail "Android mpv Java VM patch must preserve the exported MediaKit symbol"
grep -Fq 'av_jni_set_java_vm(vm, NULL)' "$script_dir/android-mpv-java-vm.patch" ||
    fail "Android mpv Java VM patch must forward the JavaVM to FFmpeg"
grep -Fq "$GAS_PREPROCESSOR_COMMIT/gas-preprocessor.pl" "$download_sdk" ||
    fail "gas-preprocessor is not pinned to $GAS_PREPROCESSOR_COMMIT"
(
    bash "$script_dir/apply_mpv_audio_controls.sh" --check-patch \
        "$script_dir/mpv-audio-controls.patch" ||
        fail "mpv audio controls patch changed"
    bash "$script_dir/apply_ffmpeg_sendcmd_precision.sh" --check-patch \
        "$script_dir/ffmpeg-sendcmd-precision.patch" ||
        fail "FFmpeg sendcmd precision patch changed"
)
grep -Fq 'apply_mpv_audio_controls.sh' "$script_dir/build_android.sh" ||
    fail "mpv audio controls patch is not applied to the pinned source"
grep -Fq 'apply_ffmpeg_sendcmd_precision.sh' "$script_dir/build_android.sh" ||
    fail "FFmpeg sendcmd precision patch is not applied to the pinned source"
[[ -s "$script_dir/android-mbedtls-aesce.patch" ]] ||
    fail "MbedTLS AESCE target patch is missing"
mbedtls_pin_line=$(grep -Fn 'assert_source_commit MbedTLS "$ANDROID_MBEDTLS_COMMIT"' "$script_dir/build_android.sh" | cut -d: -f1)
mbedtls_patch_check_line=$(grep -Fn 'git -C "$mbedtls_source_dir" apply --check "$script_dir/android-mbedtls-aesce.patch"' "$script_dir/build_android.sh" | cut -d: -f1)
mbedtls_patch_apply_line=$(grep -Fn 'git -C "$mbedtls_source_dir" apply "$script_dir/android-mbedtls-aesce.patch"' "$script_dir/build_android.sh" | cut -d: -f1)
mbedtls_build_line=$(grep -Fn './build.sh --arch "$arch"' "$script_dir/build_android.sh" | cut -d: -f1)
[[ -n "$mbedtls_pin_line" && -n "$mbedtls_patch_check_line" && -n "$mbedtls_patch_apply_line" && -n "$mbedtls_build_line" ]] ||
    fail "MbedTLS AESCE patch must be checked and applied to the pinned source"
[[ "$mbedtls_pin_line" -lt "$mbedtls_patch_check_line" && "$mbedtls_patch_check_line" -lt "$mbedtls_patch_apply_line" && "$mbedtls_patch_apply_line" -lt "$mbedtls_build_line" ]] ||
    fail "MbedTLS AESCE patch must apply after source pin verification and before build"
if grep -Fq 'apply_mpv_audio_reinit.sh' "$script_dir/build_android.sh"; then
    fail "mpv 0.42.0 already includes the audio reinitialization fix"
fi

if grep -Eq 'git clone.*(--branch[[:space:]]+(main|master)|refs/heads/(main|master))' "$download_deps"; then
    fail "default flavor downloads an unpinned moving branch"
fi
if grep -Eq 'git clone.*(fftools-ffi|media_kit|x264\.git)' "$download_deps"; then
    fail "default flavor downloads an unused source repository"
fi
grep -Fq 'git clone https://github.com/media-kit/media-kit-android-helper.git' "$download_deps" ||
    fail "media-kit Android helper source is not downloaded"
grep -Fq 'git reset --hard "$ANDROID_HELPER_COMMIT"' "$download_deps" ||
    fail "media-kit Android helper is not checked out at its locked commit"
grep -Fq 'git -C mpv fetch --depth 1 "$MPV_URL" "$v_mpv"' "$download_deps" ||
    fail "mpv is not fetched at the common locked commit"
grep -Fq 'git -C libplacebo fetch --depth 1 "$LIBPLACEBO_URL" "$v_libplacebo"' "$download_deps" ||
    fail "libplacebo is not fetched at the common locked commit"
grep -Fq 'git clone --depth 1 --branch n$v_ffmpeg "$FFMPEG_URL" ffmpeg' "$download_deps" ||
    fail "FFmpeg is not fetched from the common locked source"
if grep -Eq -- '^[[:space:]]*--(disable-postproc|enable-libshaderc)(=|[[:space:]]|$)' "$ffmpeg_config"; then
    fail "FFmpeg 9.0.2 configure options must not include postproc or libshaderc"
fi
grep -Fq 'dep_mpv=(ffmpeg libass libplacebo)' "$depinfo" ||
    fail "libplacebo is not a required mpv build dependency"
[[ -f "$source_dir/buildscripts/scripts/libplacebo.sh" ]] ||
    fail "libplacebo build script is missing"
if grep -Fq -- '-Dlibplacebo=disabled' "$source_dir/buildscripts/scripts/mpv.sh"; then
    fail "mpv cannot build with libplacebo disabled"
fi
grep -Fq -- '-Dopengl=enabled' "$source_dir/buildscripts/scripts/libplacebo.sh" ||
    fail "libplacebo must preserve the Android OpenGL video renderer"
grep -Fq -- '-Dgl=enabled' "$source_dir/buildscripts/scripts/mpv.sh" ||
    fail "mpv must keep its OpenGL renderer"
grep -Fq -- '-Degl-android=enabled' "$source_dir/buildscripts/scripts/mpv.sh" ||
    fail "mpv must keep its Android EGL renderer"
grep -Fq -- '-Dvulkan=disabled' "$source_dir/buildscripts/scripts/libplacebo.sh" ||
    fail "Android libplacebo must preserve API 21 compatibility"
grep -Fq 'git -C "$libplacebo_source_dir" submodule update --init --recursive --depth 1' "$script_dir/build_android.sh" ||
    fail "Android must initialize pinned libplacebo submodules"
for required_path in \
    '3rdparty/glad/glad/__init__.py' \
    '3rdparty/jinja/src/jinja2/__init__.py' \
    '3rdparty/markupsafe/src/markupsafe/__init__.py'
do
    grep -Fq "$required_path" "$script_dir/build_android.sh" ||
        fail "Android libplacebo submodule check is missing $required_path"
done
libplacebo_pin_line=$(grep -Fn 'assert_source_commit libplacebo' "$script_dir/build_android.sh" | cut -d: -f1)
libplacebo_submodule_line=$(grep -Fn 'submodule update --init --recursive --depth 1' "$script_dir/build_android.sh" | cut -d: -f1)
[[ -n "$libplacebo_pin_line" && -n "$libplacebo_submodule_line" && "$libplacebo_pin_line" -lt "$libplacebo_submodule_line" ]] ||
    fail "libplacebo submodules must initialize after the locked source is verified"

[[ "$(grep -Fc -- '--disable-filters' "$ffmpeg_config")" == 1 ]] ||
    fail "FFmpeg must keep its explicit filter allowlist"
if grep -Eq -- '--enable-(filters|all)(=|[[:space:]]|$)' "$ffmpeg_config"; then
    fail "broad FFmpeg filter enablement is not allowed"
fi

expected_filters=$(
    {
        tr -d '\r' < "$script_dir/filters.txt"
        printf '%s\n' overlay equalizer
    } | LC_ALL=C sort
)
actual_filters=$(
    grep -oE -- '--enable-filter=[[:alnum:]_]+' "$ffmpeg_config" |
        cut -d= -f2 |
        LC_ALL=C sort
)
if [[ "$actual_filters" != "$expected_filters" ]]; then
    diff -u <(printf '%s\n' "$expected_filters") <(printf '%s\n' "$actual_filters") || true
    fail "FFmpeg filter allowlist differs from scripts/native_audio/filters.txt"
fi
