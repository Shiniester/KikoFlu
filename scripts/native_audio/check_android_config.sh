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
grep -Fqx "v_ffmpeg=$ANDROID_FFMPEG_VERSION" "$depinfo" || fail "FFmpeg version ref changed"
grep -Fqx "v_mpv=$ANDROID_MPV_COMMIT" "$depinfo" || fail "mpv source commit changed"
grep -Eq "^[[:space:]]*local apilvl=$ANDROID_API$" "$source_dir/buildscripts/build.sh" ||
    fail "Android native API level changed"
grep -Fq "$GAS_PREPROCESSOR_COMMIT/gas-preprocessor.pl" "$download_sdk" ||
    fail "gas-preprocessor is not pinned to $GAS_PREPROCESSOR_COMMIT"
(
    cd "$script_dir"
    bash "$script_dir/apply_mpv_audio_reinit.sh" --check-patch \
        "$script_dir/mpv-audio-reinit.patch" "$MPV_AUDIO_REINIT_PATCH_COMMIT" ||
        fail "mpv audio reinit patch changed"
    bash "$script_dir/apply_mpv_audio_controls.sh" --check-patch \
        "$script_dir/mpv-audio-controls.patch" ||
        fail "mpv audio controls patch changed"
    bash "$script_dir/apply_ffmpeg_sendcmd_precision.sh" --check-patch \
        "$script_dir/ffmpeg-sendcmd-precision.patch" ||
        fail "FFmpeg sendcmd precision patch changed"
)
grep -Fq 'apply_mpv_audio_controls.sh' "$script_dir/build_android.sh" ||
    fail "mpv audio controls patch is not applied to the pinned source"

if grep -Eq 'git clone.*(--branch[[:space:]]+(main|master)|refs/heads/(main|master))' "$download_deps"; then
    fail "default flavor downloads an unpinned moving branch"
fi
if grep -Eq 'git clone.*(fftools-ffi|media-kit-android-helper|media_kit|x264\.git)' "$download_deps"; then
    fail "default flavor downloads an unused source repository"
fi

[[ "$(grep -Fc -- '--disable-filters' "$ffmpeg_config")" == 1 ]] ||
    fail "FFmpeg must keep its explicit filter allowlist"
if grep -Eq -- '--enable-(filters|all)(=|[[:space:]]|$)' "$ffmpeg_config"; then
    fail "broad FFmpeg filter enablement is not allowed"
fi

expected_filters=$(
    {
        cat "$script_dir/filters.txt"
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
