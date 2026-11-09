#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir/../.." rev-parse --show-toplevel)
source "$script_dir/android.lock"

work_dir=${NATIVE_AUDIO_LINUX_PROBE_WORK_DIR:-${RUNNER_TEMP:-$repo_root/build}/native-audio-linux-probe}
output_dir=${NATIVE_AUDIO_LINUX_PROBE_OUTPUT_DIR:-$repo_root/build/native-audio/linux-probe-output}
source_dir="$work_dir/mpv"
build_dir="$work_dir/build"
reinit_patch="$script_dir/mpv-audio-reinit.patch"
controls_patch="$script_dir/mpv-audio-controls.patch"

fail() {
    printf 'Linux native audio probe: %s\n' "$1" >&2
    exit 1
}

for tool in git meson ninja pkg-config cc python3; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is missing: $tool"
done

[[ -s "$reinit_patch" ]] || fail "patch file is missing: $reinit_patch"
[[ -s "$controls_patch" ]] || fail "patch file is missing: $controls_patch"
[[ ! -e "$work_dir" ]] || fail "work directory already exists: $work_dir"
if [[ -d "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]]; then
    fail "output directory is not empty: $output_dir"
fi

mkdir -p "$work_dir" "$output_dir"
git init -q "$source_dir"
git -C "$source_dir" remote add origin https://github.com/mpv-player/mpv.git
git -C "$source_dir" fetch --depth 1 origin "$ANDROID_MPV_COMMIT"
git -C "$source_dir" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$ANDROID_MPV_COMMIT" ]] ||
    fail "mpv source does not match $ANDROID_MPV_COMMIT"

bash "$script_dir/apply_mpv_audio_reinit.sh" --apply \
    "$source_dir" "$ANDROID_MPV_COMMIT" "$reinit_patch" "$MPV_AUDIO_REINIT_PATCH_COMMIT"
bash "$script_dir/apply_mpv_audio_controls.sh" --apply \
    "$source_dir" "$ANDROID_MPV_COMMIT" "$controls_patch"

meson setup "$build_dir" "$source_dir" \
    --wrap-mode=nodownload \
    -Ddefault_library=shared \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dtests=false \
    -Dbuild-date=false \
    -Dmanpage-build=disabled \
    -Dhtml-build=disabled \
    -Dpdf-build=disabled \
    -Dlibplacebo=disabled \
    -Dgl=disabled \
    -Dvulkan=disabled \
    -Dx11=disabled \
    -Dwayland=disabled \
    -Ddrm=disabled \
    -Dvaapi=disabled \
    -Dvdpau=disabled \
    -Djpeg=disabled
meson compile -C "$build_dir"

[[ -s "$build_dir/libmpv.so" ]] || fail 'headless libmpv target was not produced'
cp -L -- "$build_dir/libmpv.so" "$output_dir/libmpv.so"
[[ -s "$output_dir/libmpv.so" ]] || fail 'libmpv output copy is empty'

{
    printf 'mpv_commit=%s\n' "$ANDROID_MPV_COMMIT"
    printf 'mpv_version=%s\n' "$(<"$source_dir/VERSION")"
    printf 'mpv_patches=mpv-audio-reinit.patch,mpv-audio-controls.patch\n'
    printf 'compiler=%s\n' "$(cc --version | head -n 1)"
    printf 'meson=%s\n' "$(meson --version)"
    printf 'ninja=%s\n' "$(ninja --version)"
    for package in libass libavcodec libavfilter libavformat libavutil libswresample libswscale; do
        printf '%s=%s\n' "$package" "$(pkg-config --modversion "$package")"
    done
} > "$output_dir/provenance.txt"

printf 'Built headless libmpv: %s\n' "$output_dir/libmpv.so"
printf 'Build provenance: %s\n' "$output_dir/provenance.txt"
