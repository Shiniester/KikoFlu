#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir/../.." rev-parse --show-toplevel)
source "$script_dir/common.lock"
source "$script_dir/linux.lock"

work_dir="${RUNNER_TEMP:-$repo_root/build}/native-audio-linux"
output_dir="$repo_root/build/native-audio/linux-output"
[[ ! -e "$work_dir" && ! -e "$output_dir" ]] || {
    echo 'Linux native audio work or output directory already exists.' >&2
    exit 1
}
mkdir -p "$work_dir" "$output_dir"
export PKG_CONFIG_PATH="$output_dir/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$output_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

fetch_source() {
    local name=$1 url=$2 commit=$3
    git init -q "$work_dir/$name"
    git -C "$work_dir/$name" remote add origin "$url"
    git -C "$work_dir/$name" fetch --depth 1 origin "$commit"
    git -C "$work_dir/$name" checkout -q --detach FETCH_HEAD
    [[ "$(git -C "$work_dir/$name" rev-parse HEAD)" == "$commit" ]]
}

fetch_source dav1d "$DAV1D_URL" "$DAV1D_COMMIT"
meson setup "$work_dir/dav1d-build" "$work_dir/dav1d" \
    --prefix="$output_dir" --libdir=lib --buildtype=release \
    -Denable_tools=false -Denable_tests=false
meson install -C "$work_dir/dav1d-build"

fetch_source ffmpeg "$FFMPEG_URL" "$FFMPEG_COMMIT"
git -C "$work_dir/ffmpeg" fetch --depth 1 origin \
    "refs/tags/n$FFMPEG_VERSION:refs/tags/n$FFMPEG_VERSION"
[[ "$(git -C "$work_dir/ffmpeg" rev-parse "n$FFMPEG_VERSION^{commit}")" == "$FFMPEG_COMMIT" ]]
bash "$script_dir/apply_ffmpeg_sendcmd_precision.sh" --apply \
    "$work_dir/ffmpeg" "$FFMPEG_COMMIT" "$script_dir/ffmpeg-sendcmd-precision.patch"
(
    cd "$work_dir/ffmpeg"
    ./configure --prefix="$output_dir" --libdir="$output_dir/lib" \
        --enable-shared --disable-static --disable-doc --disable-debug \
        --enable-gpl --enable-version3 --enable-openssl --enable-libdav1d \
        --extra-ldflags="-Wl,-rpath,$output_dir/lib"
    make -j2
    make install
)

fetch_source libplacebo "$LIBPLACEBO_URL" "$LIBPLACEBO_COMMIT"
git -C "$work_dir/libplacebo" submodule update --init --recursive --depth 1
meson setup "$work_dir/libplacebo-build" "$work_dir/libplacebo" \
    --prefix="$output_dir" --libdir=lib --buildtype=release \
    -Ddefault_library=shared -Dopengl=enabled -Dvulkan=disabled -Dshaderc=disabled \
    -Dglslang=disabled -Dlibdovi=disabled -Ddemos=false -Dtests=false
meson install -C "$work_dir/libplacebo-build"

fetch_source mpv "$MPV_URL" "$MPV_COMMIT"
bash "$script_dir/apply_mpv_audio_controls.sh" --apply \
    "$work_dir/mpv" "$MPV_COMMIT" "$script_dir/mpv-audio-controls.patch"
meson setup "$work_dir/mpv-build" "$work_dir/mpv" \
    --prefix="$output_dir" --libdir=lib --buildtype=release \
    -Ddefault_library=shared -Dlibmpv=true -Dcplayer=false \
    -Dbuild-date=false -Dmanpage-build=disabled -Dhtml-build=disabled \
    -Dpdf-build=disabled -Dc_link_args="-Wl,-rpath,$output_dir/lib"
meson install -C "$work_dir/mpv-build"

[[ -s "$output_dir/lib/libmpv.so" ]]
{
    printf 'mpv_version=%s\nmpv_commit=%s\n' "$MPV_VERSION" "$MPV_COMMIT"
    printf 'ffmpeg_version=%s\nffmpeg_commit=%s\n' "$FFMPEG_VERSION" "$FFMPEG_COMMIT"
    printf 'libplacebo_commit=%s\ndav1d_commit=%s\n' "$LIBPLACEBO_COMMIT" "$DAV1D_COMMIT"
    printf 'mpv_audio_controls_patch=mpv-audio-controls.patch\n'
    printf 'ffmpeg_sendcmd_argument_format=%%.17g\n'
    cc --version | head -n 1
} > "$output_dir/source-provenance.txt"
