#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=${1:?Usage: check_darwin_config.sh <libmpv-darwin-build source>}
source "$script_dir/darwin.lock"

fail() {
    printf 'Darwin native audio build config: %s\n' "$1" >&2
    exit 1
}

actual_commit=$(git -C "$source_dir" rev-parse HEAD) || fail 'recipe checkout is missing'
[[ "$actual_commit" == "$DARWIN_RECIPE_COMMIT" ]] ||
    fail "recipe source is $actual_commit, expected $DARWIN_RECIPE_COMMIT"
[[ "$(git -C "$source_dir" describe --tags --exact-match HEAD)" == "$DARWIN_RECIPE_REF" ]] ||
    fail "recipe checkout is not the $DARWIN_RECIPE_REF tag"

ffmpeg_options="$source_dir/scripts/ffmpeg/meson.build"
ffmpeg_build="$source_dir/scripts/ffmpeg/build.sh"
mpv_build="$source_dir/scripts/mpv/build.sh"
[[ -f "$ffmpeg_options" && -f "$ffmpeg_build" && -f "$mpv_build" ]] ||
    fail 'one or more pinned recipe files are missing'
[[ -f "$source_dir/patches/mpv-audio-controls.patch" ]] ||
    fail 'MPV audio controls patch is missing from the recipe'
cmp -s "$script_dir/mpv-audio-controls.patch" "$source_dir/patches/mpv-audio-controls.patch" ||
    fail 'MPV audio controls patch differs from the checked patch'
bash "$script_dir/apply_mpv_audio_controls.sh" --check-patch \
    "$script_dir/mpv-audio-controls.patch" ||
    fail 'MPV audio controls patch changed'

expected_filters=$(
    {
        cat "$script_dir/filters.txt"
        printf '%s\n' overlay equalizer
    } | LC_ALL=C sort
)
audio_default_options=$(sed -n '/^audio_default_options = \[/,/^]/p' "$ffmpeg_options")
actual_filters=$(
    printf '%s\n' "$audio_default_options" |
        grep -oE -- '--enable-filter=[[:alnum:]_]+' |
        cut -d= -f2 |
        LC_ALL=C sort
)
[[ "$actual_filters" == "$expected_filters" ]] || {
    diff -u <(printf '%s\n' "$expected_filters") <(printf '%s\n' "$actual_filters") || true
    fail 'FFmpeg audio-default filter allowlist differs from filters.txt plus overlay/equalizer'
}
if grep -Eq -- '--enable-filters(=|[[:space:]]|$)' <<<"$audio_default_options"; then
    fail 'FFmpeg audio-default must not enable all filters'
fi

grep -Fq 'patch -p1 <${PROJECT_DIR}/patches/ffmpeg-sendcmd-precision.patch' "$ffmpeg_build" ||
    fail 'FFmpeg sendcmd precision patch is not applied by the pinned build script'
grep -Fq 'patch -p1 <${PROJECT_DIR}/patches/mpv-audio-reinit.patch' "$mpv_build" ||
    fail 'MPV audio filter reinit patch is not applied by the pinned build script'
grep -Fq 'patch -p1 <${PROJECT_DIR}/patches/mpv-audio-controls.patch' "$mpv_build" ||
    fail 'MPV audio controls patch is not applied by the pinned build script'

for option in \
    '-Dcocoa=enabled' \
    '-Dgl=enabled' \
    '-Dgl-cocoa=enabled' \
    '-Dvideotoolbox-gl=enabled' \
    '-Daudiounit=enabled' \
    '-Dios-gl=enabled'; do
    grep -Fq -- "$option" "$mpv_build" || fail "video-default provider option was removed: $option"
done

grep -A3 '^ffmpeg:' "$source_dir/downloads.lock" |
    grep -Fqx '  sha256: 57be87c22d9b49c112b6d24bc67d42508660e6b718b3db89c44e47e289137082' ||
    fail 'pinned FFmpeg 6.0 archive checksum changed'
grep -A3 '^mpv:' "$source_dir/downloads.lock" |
    grep -Fqx "  version: $DARWIN_MPV_VERSION" ||
    fail 'pinned MPV source version changed'
grep -A3 '^mpv:' "$source_dir/downloads.lock" |
    grep -Fqx "  url: https://github.com/mpv-player/mpv/archive/refs/tags/v$DARWIN_MPV_VERSION.tar.gz" ||
    fail 'pinned MPV source tag URL changed'
grep -A3 '^mpv:' "$source_dir/downloads.lock" |
    grep -Fqx '  sha256: 29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6' ||
    fail 'pinned MPV v0.36.0 archive checksum changed'
[[ "$DARWIN_MPV_VERSION" == '0.36.0' && "$DARWIN_MPV_COMMIT" == 'f4210f84906c3b00a65fba198c8127b6757b9350' ]] ||
    fail 'pinned MPV source tag or resolved commit changed'
git -C "$source_dir" diff --quiet -- downloads.lock .tool-versions ||
    fail 'upstream source or tool-version pins were changed'
git -C "$source_dir" diff --check || fail 'Darwin recipe patch has whitespace errors'
