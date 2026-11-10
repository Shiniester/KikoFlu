#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir/../.." rev-parse --show-toplevel)
source "$script_dir/android.lock"
export ANDROID_HELPER_COMMIT MPV_URL MPV_COMMIT FFMPEG_URL FFMPEG_VERSION \
    LIBPLACEBO_URL LIBPLACEBO_COMMIT

mode=${1:-arm64}
work_dir="${RUNNER_TEMP:-$repo_root/build}/native-audio-work/android"
output_dir="${NATIVE_AUDIO_ANDROID_OUTPUT_DIR:-$repo_root/build/native-audio/android-output}"
source_dir="$work_dir/libmpv-android-video-build"
buildscripts_dir="$source_dir/buildscripts"

fail() {
    printf 'Android native audio build: %s\n' "$1" >&2
    exit 1
}

assert_source_commit() {
    local name=$1
    local expected_commit=$2
    local source_path=$3
    local actual_commit

    actual_commit=$(git -C "$source_path" rev-parse HEAD) || fail "$name source is missing"
    [[ "$actual_commit" == "$expected_commit" ]] || fail "$name source is $actual_commit, expected $expected_commit"
}

[[ "$mode" == arm64 || "$mode" == all ]] || fail "mode must be arm64 or all"
[[ ! -e "$work_dir" ]] || fail "work directory already exists: $work_dir"
if [[ -d "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]]; then
    fail "output directory is not empty: $output_dir"
fi

mkdir -p "$work_dir" "$output_dir"
git clone --depth 1 --branch "$ANDROID_BUILDER_REF" --single-branch "$ANDROID_BUILDER_URL" "$source_dir"
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$ANDROID_BUILDER_COMMIT" ]] ||
    fail "builder tag $ANDROID_BUILDER_REF moved from $ANDROID_BUILDER_COMMIT"
git -C "$source_dir" apply --unidiff-zero --check "$script_dir/android-effects.patch"
git -C "$source_dir" apply --unidiff-zero "$script_dir/android-effects.patch"
cp "$script_dir/android-mpv-java-vm.patch" \
    "$source_dir/buildscripts/patches/mpv/mpv_lavc_set_java_vm.patch"
rm \
    "$source_dir/buildscripts/patches/ffmpeg/dash_base_url_escape.patch" \
    "$source_dir/buildscripts/patches/ffmpeg/hls_mp4_seek.patch" \
    "$source_dir/buildscripts/patches-encoders-gpl/ffmpeg"
rmdir "$source_dir/buildscripts/patches/ffmpeg"
bash "$script_dir/check_android_config.sh" "$source_dir"

cd "$buildscripts_dir"
TRAVIS=1 ./download.sh
./patch.sh
mpv_source_dir="$buildscripts_dir/deps/mpv"
ffmpeg_source_dir="$buildscripts_dir/deps/ffmpeg"
helper_source_dir="$buildscripts_dir/deps/media-kit-android-helper"
assert_source_commit mpv "$MPV_COMMIT" "$mpv_source_dir"
assert_source_commit FFmpeg "$FFMPEG_COMMIT" "$ffmpeg_source_dir"
libplacebo_source_dir="$buildscripts_dir/deps/libplacebo"
assert_source_commit libplacebo "$LIBPLACEBO_COMMIT" "$libplacebo_source_dir"
git -C "$libplacebo_source_dir" submodule update --init --recursive --depth 1
for required_file in \
    "$libplacebo_source_dir/3rdparty/glad/glad/__init__.py" \
    "$libplacebo_source_dir/3rdparty/jinja/src/jinja2/__init__.py" \
    "$libplacebo_source_dir/3rdparty/markupsafe/src/markupsafe/__init__.py"
do
    [[ -f "$required_file" ]] || fail "libplacebo OpenGL submodule file is missing: $required_file"
done
assert_source_commit media-kit-android-helper "$ANDROID_HELPER_COMMIT" "$helper_source_dir"
bash "$script_dir/apply_mpv_audio_controls.sh" --apply \
    "$mpv_source_dir" "$MPV_COMMIT" \
    "$script_dir/mpv-audio-controls.patch"
bash "$script_dir/apply_ffmpeg_sendcmd_precision.sh" --apply \
    "$ffmpeg_source_dir" "$FFMPEG_COMMIT" \
    "$script_dir/ffmpeg-sendcmd-precision.patch"
cp flavors/default.sh scripts/ffmpeg.sh

assert_source_commit dav1d "$ANDROID_DAV1D_COMMIT" "$buildscripts_dir/deps/dav1d"
assert_source_commit freetype "$ANDROID_FREETYPE_COMMIT" "$buildscripts_dir/deps/freetype"
freetype_dlg_gitlink=$(git -C "$buildscripts_dir/deps/freetype" ls-tree HEAD subprojects/dlg)
expected_freetype_dlg_gitlink="160000 commit $ANDROID_FREETYPE_DLG_COMMIT"$'\t'subprojects/dlg
[[ "$freetype_dlg_gitlink" == "$expected_freetype_dlg_gitlink" ]] ||
    fail "freetype dlg gitlink does not match $ANDROID_FREETYPE_DLG_COMMIT"
assert_source_commit FriBidi "$ANDROID_FRIBIDI_COMMIT" "$buildscripts_dir/deps/fribidi"
assert_source_commit HarfBuzz "$ANDROID_HARFBUZZ_COMMIT" "$buildscripts_dir/deps/harfbuzz"
assert_source_commit libass "$ANDROID_LIBASS_COMMIT" "$buildscripts_dir/deps/libass"
assert_source_commit libxml2 "$ANDROID_LIBXML2_COMMIT" "$buildscripts_dir/deps/libxml2"
assert_source_commit MbedTLS "$ANDROID_MBEDTLS_COMMIT" "$buildscripts_dir/deps/mbedtls"
[[ "$(git -C deps/ffmpeg describe --tags --exact-match HEAD)" == "n$FFMPEG_VERSION" ]] ||
    fail "FFmpeg source does not match n$FFMPEG_VERSION"

if [[ "$mode" == all ]]; then
    arches=(arm64 armv7l x86 x86_64)
else
    arches=(arm64)
fi

helper_cmake_source="$helper_source_dir/app/src/main/cpp"
helper_cmake="$buildscripts_dir/sdk/android-sdk-linux/cmake/3.22.1/bin/cmake"
helper_toolchain="$buildscripts_dir/sdk/android-sdk-linux/ndk/$ANDROID_NDK/build/cmake/android.toolchain.cmake"
[[ -f "$helper_cmake_source/CMakeLists.txt" ]] || fail "media-kit Android helper CMake source is missing"
[[ -x "$helper_cmake" ]] || fail "Android CMake 3.22.1 is missing: $helper_cmake"
[[ -f "$helper_toolchain" ]] || fail "locked Android NDK toolchain is missing: $helper_toolchain"
grep -Fq -- '-Wl,-z,max-page-size=16384' "$helper_cmake_source/CMakeLists.txt" ||
    fail "media-kit Android helper CMake source does not enable 16 KiB page alignment"

for arch in "${arches[@]}"; do
    case "$arch" in
        arm64) abi=arm64-v8a; expected_machine='AArch64' ;;
        armv7l) abi=armeabi-v7a; expected_machine='ARM' ;;
        x86) abi=x86; expected_machine='Intel 80386' ;;
        x86_64) abi=x86_64; expected_machine='Advanced Micro Devices X86-64' ;;
        *) fail "unsupported Android architecture: $arch" ;;
    esac

    helper_build_dir="$work_dir/helper-build/$abi"
    helper_output_dir="$work_dir/helper-output/$abi"
    "$helper_cmake" -G Ninja -S "$helper_cmake_source" -B "$helper_build_dir" \
        -DCMAKE_TOOLCHAIN_FILE="$helper_toolchain" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-$ANDROID_API" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$helper_output_dir" ||
        fail "media-kit Android helper CMake configuration failed for $abi"
    "$helper_cmake" --build "$helper_build_dir" --config Release --parallel 2 ||
        fail "media-kit Android helper build failed for $abi"
    helper_library="$helper_output_dir/libmediakitandroidhelper.so"
    [[ -s "$helper_library" ]] || fail "media-kit Android helper was not produced for $abi"
    readelf -h "$helper_library" | grep -Eq "Machine:[[:space:]]+$expected_machine" ||
        fail "media-kit Android helper has the wrong ELF machine for $abi"
    readelf -W -l "$helper_library" |
        awk '/^[[:space:]]*LOAD/ { found = 1; if ($NF != "0x4000") invalid = 1 } END { exit !(found && !invalid) }' ||
        fail "media-kit Android helper is not aligned for 16 KiB pages for $abi"

    ./build.sh --arch "$arch"
    library="$buildscripts_dir/prefix/$abi/usr/local/lib/libmpv.so"
    [[ -s "$library" ]] || fail "libmpv.so was not produced for $abi"
    readelf -h "$library" | grep -Eq "Machine:[[:space:]]+$expected_machine" ||
        fail "libmpv.so has the wrong ELF machine for $abi"

    mkdir -p "$output_dir/$abi" "$work_dir/jar/$abi/lib/$abi"
    cp "$library" "$output_dir/$abi/libmpv.so"
    cp "$helper_library" "$output_dir/$abi/libmediakitandroidhelper.so"
    cp "$library" "$work_dir/jar/$abi/lib/$abi/libmpv.so"
    cp "$helper_library" "$work_dir/jar/$abi/lib/$abi/libmediakitandroidhelper.so"
    (
        cd "$work_dir/jar/$abi"
        zip -q -r "$output_dir/default-$abi.jar" "lib/$abi/libmpv.so" "lib/$abi/libmediakitandroidhelper.so"
    )
    unzip -Z1 "$output_dir/default-$abi.jar" | grep -Fxq "lib/$abi/libmpv.so" ||
        fail "default-$abi.jar is missing lib/$abi/libmpv.so"
    unzip -Z1 "$output_dir/default-$abi.jar" | grep -Fxq "lib/$abi/libmediakitandroidhelper.so" ||
        fail "default-$abi.jar is missing lib/$abi/libmediakitandroidhelper.so"
done

{
    printf 'builder_url=%s\n' "$ANDROID_BUILDER_URL"
    printf 'builder_ref=%s\n' "$ANDROID_BUILDER_COMMIT"
    printf 'android_helper_commit=%s\n' "$ANDROID_HELPER_COMMIT"
    printf 'ffmpeg_version=%s\n' "$FFMPEG_VERSION"
    printf 'ffmpeg_commit=%s\n' "$FFMPEG_COMMIT"
    printf 'mpv_version=%s\n' "$MPV_VERSION"
    printf 'mpv_commit=%s\n' "$MPV_COMMIT"
    printf 'libplacebo_version=%s\n' "$LIBPLACEBO_VERSION"
    printf 'libplacebo_commit=%s\n' "$LIBPLACEBO_COMMIT"
    printf 'mpv_audio_controls_patch=%s\n' 'mpv-audio-controls.patch'
    printf 'ffmpeg_sendcmd_argument_format=%s\n' '%.17g'
    printf 'gas_preprocessor_commit=%s\n' "$GAS_PREPROCESSOR_COMMIT"
    printf 'android_api=%s\n' "$ANDROID_API"
    printf 'android_sdk_tools=%s\n' "$ANDROID_SDK_TOOLS"
    printf 'android_build_tools=%s\n' "$ANDROID_BUILD_TOOLS"
    printf 'android_ndk=%s\n' "$ANDROID_NDK"
    printf 'meson=%s\n' "$(meson --version)"
    printf 'ninja=%s\n' "$(ninja --version)"
    printf 'architectures=%s\n' "${arches[*]}"
    printf 'filters=%s,overlay,equalizer\n' "$(paste -sd, "$script_dir/filters.txt")"
    printf 'built_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'source_revisions:\n'
    for package_dir in "$buildscripts_dir"/deps/*; do
        [[ -d "$package_dir/.git" || -f "$package_dir/.git" ]] || continue
        package_commit=$(git -C "$package_dir" rev-parse HEAD)
        printf '  %s=%s\n' "$(basename "$package_dir")" "$package_commit"
        git -C "$package_dir" submodule status --recursive 2>/dev/null | sed 's/^/    /'
    done
} > "$output_dir/source-provenance.txt"
