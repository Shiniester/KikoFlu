#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=${1:?Usage: check_darwin_config.sh <libmpv-darwin-build source>}
source "$script_dir/common.lock"
source "$script_dir/darwin.lock"

fail() {
    printf 'Darwin native audio build config: %s\n' "$1" >&2
    exit 1
}

lock_value() {
    local package=$1
    local field=$2
    awk -v package="$package" -v field="$field" '
        $0 == package ":" { inside = 1; next }
        inside && /^[^ ]/ { exit }
        inside && index($0, "  " field ": ") == 1 {
            sub("^  " field ": ", "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' "$source_dir/downloads.lock"
}

actual_commit=$(git -C "$source_dir" rev-parse HEAD) || fail 'recipe checkout is missing'
[[ "$actual_commit" == "$DARWIN_RECIPE_COMMIT" ]] ||
    fail "recipe source is $actual_commit, expected $DARWIN_RECIPE_COMMIT"
[[ "$(git -C "$source_dir" describe --tags --exact-match HEAD)" == "$DARWIN_RECIPE_REF" ]] ||
    fail "recipe checkout is not the $DARWIN_RECIPE_REF tag"

ffmpeg_options="$source_dir/scripts/ffmpeg/meson.build"
ffmpeg_build="$source_dir/scripts/ffmpeg/build.sh"
mpv_build="$source_dir/scripts/mpv/build.sh"
libplacebo_build="$source_dir/scripts/libplacebo/build.sh"
pkgconfig_build="$source_dir/scripts/pkg-config/build.sh"
freetype_build="$source_dir/scripts/freetype/build.sh"
makefile="$source_dir/Makefile"
[[ -f "$ffmpeg_options" && -f "$ffmpeg_build" && -f "$mpv_build" && -f "$libplacebo_build" && -f "$pkgconfig_build" && -f "$freetype_build" ]] ||
    fail 'one or more pinned recipe files are missing'

for package_version in \
    "mpv:$MPV_VERSION" \
    "ffmpeg:$FFMPEG_VERSION" \
    "libplacebo:$LIBPLACEBO_VERSION"; do
    package=${package_version%%:*}
    expected_version=${package_version#*:}
    [[ "$(lock_value "$package" version)" == "$expected_version" ]] ||
        fail "$package download version differs from common.lock"
done
[[ "$(lock_value mpv url)" == "https://github.com/mpv-player/mpv/archive/$MPV_COMMIT.tar.gz" ]] ||
    fail 'MPV download is not pinned to the common.lock commit'
[[ "$(lock_value ffmpeg url)" == "https://github.com/FFmpeg/FFmpeg/archive/$FFMPEG_COMMIT.tar.gz" ]] ||
    fail 'FFmpeg download is not pinned to the common.lock commit'
[[ "$(lock_value libplacebo url)" == "https://github.com/haasn/libplacebo/archive/$LIBPLACEBO_COMMIT.tar.gz" ]] ||
    fail 'libplacebo download is not pinned to the common.lock commit'
for dependency in glad jinja markupsafe vulkan-headers; do
    [[ -n "$(lock_value "libplacebo-$dependency" sha256)" ]] ||
        fail "libplacebo $dependency source archive is missing"
done
[[ "$(lock_value libplacebo-fast_float version)" == "97b54ca9e75f5303507699d27c6b4f4efe4641a1" ]] ||
    fail 'libplacebo fast_float source does not match the pinned gitlink'
[[ "$(lock_value libplacebo-fast_float url)" == "https://github.com/fastfloat/fast_float/archive/97b54ca9e75f5303507699d27c6b4f4efe4641a1.tar.gz" ]] ||
    fail 'libplacebo fast_float archive is not pinned to its gitlink commit'
[[ "$(lock_value libplacebo-fast_float sha256)" == "2b132274539286e41f37857cac22aa8441d21bd86d55de825a3342b149f66801" ]] ||
    fail 'libplacebo fast_float archive SHA-256 differs from the pinned archive'
vulkan_headers_commit=74d8a6cb930c68ef617b202c3ff3c59d919e086b
[[ "$(lock_value libplacebo-vulkan-headers version)" == "$vulkan_headers_commit" ]] ||
    fail 'libplacebo Vulkan-Headers archive does not match the pinned gitlink'
[[ "$(lock_value libplacebo-vulkan-headers url)" == "https://github.com/KhronosGroup/Vulkan-Headers/archive/$vulkan_headers_commit.tar.gz" ]] ||
    fail 'libplacebo Vulkan-Headers archive is not pinned to its gitlink commit'
[[ "$(lock_value libplacebo-vulkan-headers sha256)" == "75967a8288ff16044a86d1af462b96d2e75c435937efb75f2bb4102ab0382f29" ]] ||
    fail 'libplacebo Vulkan-Headers archive SHA-256 differs from the pinned archive'

[[ -f "$source_dir/patches/mpv-audio-controls.patch" ]] ||
    fail 'MPV audio controls patch is missing from the recipe'
cmp -s "$script_dir/mpv-audio-controls.patch" "$source_dir/patches/mpv-audio-controls.patch" ||
    fail 'MPV audio controls patch differs from the checked patch'
[[ -f "$source_dir/patches/mpv-vulkan-metal-layer.patch" ]] ||
    fail 'MPV Vulkan Metal layer patch is missing from the recipe'
cmp -s "$script_dir/darwin-mpv-vulkan-metal-layer.patch" "$source_dir/patches/mpv-vulkan-metal-layer.patch" ||
    fail 'MPV Vulkan Metal layer patch differs from the checked patch'
cmp -s "$script_dir/ffmpeg-sendcmd-precision.patch" "$source_dir/patches/ffmpeg-sendcmd-precision.patch" ||
    fail 'FFmpeg sendcmd precision patch differs from the checked patch'
cmp -s "$script_dir/darwin-ffmpeg-ios-hdr.patch" "$source_dir/patches/ffmpeg-fix-ios-hdr-texture.patch" ||
    fail 'FFmpeg iOS HDR texture patch differs from the checked patch'
cmp -s "$script_dir/darwin-libplacebo-charconv.patch" "$source_dir/patches/libplacebo-darwin-charconv.patch" ||
    fail 'libplacebo Darwin charconv patch differs from the checked patch'
cmp -s "$script_dir/pkg-config-glib-atomics.patch" "$source_dir/patches/pkg-config-glib-atomics.patch" ||
    fail 'pkg-config bundled GLib atomic patch differs from the checked patch'
cmp -s "$script_dir/libpng-macos-fp-header.patch" "$source_dir/patches/libpng-macos-fp-header.patch" ||
    fail 'libpng macOS math-header patch differs from the checked patch'
bash "$script_dir/apply_mpv_audio_controls.sh" --check-patch \
    "$script_dir/mpv-audio-controls.patch" ||
    fail 'MPV audio controls patch changed'

expected_filters=$(
    {
        tr -d '\r' < "$script_dir/filters.txt"
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

grep -Fq 'git -C "${PROJECT_DIR}" apply --directory="${SRC_DIR#${PROJECT_DIR}/}" "${PROJECT_DIR}/patches/ffmpeg-sendcmd-precision.patch"' "$ffmpeg_build" ||
    fail 'FFmpeg sendcmd precision patch is not applied by the pinned build script'
grep -Fq 'patch -p1 <${PROJECT_DIR}/patches/ffmpeg-fix-ios-hdr-texture.patch' "$ffmpeg_build" ||
    fail 'FFmpeg iOS HDR texture patch is not applied by the pinned build script'
grep -Fq 'release_version=$(cat RELEASE)' "$ffmpeg_build" ||
    fail 'FFmpeg release VERSION metadata is not restored before configure'
grep -Fq 'version_lock=$(grep -A1' "$ffmpeg_build" ||
    fail 'FFmpeg RELEASE is not checked against the pinned download version'
grep -Fq 'if [ "${release_version}" != "${version_lock}" ]; then' "$ffmpeg_build" ||
    fail 'FFmpeg RELEASE is not compared with the pinned download version'
grep -Fq '> VERSION' "$ffmpeg_build" ||
    fail 'FFmpeg release version metadata is not written before configure'
grep -Fq 'git -C "${PROJECT_DIR}" apply --directory="${SRC_DIR#${PROJECT_DIR}/}" "${PROJECT_DIR}/patches/mpv-audio-controls.patch"' "$mpv_build" ||
    fail 'MPV audio controls patch is not applied by the pinned build script'
grep -Fq 'git -C "${PROJECT_DIR}" apply --directory="${SRC_DIR#${PROJECT_DIR}/}" "${PROJECT_DIR}/patches/mpv-vulkan-metal-layer.patch"' "$mpv_build" ||
    fail 'MPV Vulkan Metal layer patch is not applied by the pinned build script'
grep -Fq 'patch -p1 < "${PROJECT_DIR}/patches/pkg-config-glib-atomics.patch"' "$pkgconfig_build" ||
    fail 'pkg-config bundled GLib atomic patch is not applied before configure'
grep -Fq 'cd subprojects/libpng-1.6.40' "$freetype_build" ||
    fail 'libpng fallback source directory is not patched'
grep -Fq 'patch -p1 < "${PROJECT_DIR}/patches/libpng-macos-fp-header.patch"' "$freetype_build" ||
    fail 'libpng macOS math-header patch is not applied'
setup_line=$(grep -Fn 'meson setup build \' "$freetype_build" | cut -d: -f1)
libpng_patch_line=$(grep -Fn 'patch -p1 < "${PROJECT_DIR}/patches/libpng-macos-fp-header.patch"' "$freetype_build" | cut -d: -f1)
compile_line=$(grep -Fn 'meson compile -C build' "$freetype_build" | cut -d: -f1)
[[ "$setup_line" -lt "$libpng_patch_line" && "$libpng_patch_line" -lt "$compile_line" ]] ||
    fail 'libpng fallback patch must run after Meson setup and before compilation'
if grep -Eq 'mpv-(filter-command-target|audio-reinit|fix-missing-objc)\.patch' "$mpv_build"; then
    fail 'MPV build script still applies a patch already included in mpv 0.42.0'
fi
if grep -Eq 'ffmpeg-fix-(vp9-hwaccel|hls-mp4-seek|dash-base-url-escape)\.patch' "$ffmpeg_build"; then
    fail 'FFmpeg build script still applies an upstream fix included in FFmpeg 9.0.2'
fi

for option in \
    '-Dcocoa=enabled' \
    '-Dgl=enabled' \
    '-Dgl-cocoa=enabled' \
    '-Dvideotoolbox-gl=enabled' \
    '-Daudiounit=enabled' \
    '-Dios-gl=enabled' \
    '-Dplain-gl=enabled'; do
    grep -Fq -- "$option" "$mpv_build" || fail "video-default provider option was removed: $option"
done
for option in libplacebo ta-leak-report stdatomic win32-internal-pthreads rpi rpi-mmal vaapi-x-egl macos-10-11-features macos-10-12-2-features macos-10-14-features; do
    if grep -Fq -- "-D$option=" "$mpv_build"; then
        fail "MPV build script passes an option removed before mpv 0.42.0: $option"
    fi
done

grep -Fq '${INTERMEDIATE_DIR}/libplacebo_$$(word 1,$$(subst -, ,$$*))-$$(word 2,$$(subst -, ,$$*))' "$makefile" ||
    fail 'MPV build is missing its libplacebo prerequisite'
for option in '-Dopengl=enabled' '-Dvulkan=disabled' '-Dglslang=disabled' '-Dshaderc=disabled' '-Ddefault_library=static'; do
    grep -Fq -- "$option" "$libplacebo_build" || fail "libplacebo build option is missing: $option"
done
grep -Fq 'for dependency in fast_float glad jinja markupsafe vulkan-headers;' "$libplacebo_build" ||
    fail 'libplacebo build does not extract all pinned gitlink archives'
grep -Fq 'subproject=Vulkan-Headers' "$libplacebo_build" ||
    fail 'libplacebo Vulkan-Headers archive is not extracted into the submodule path'
grep -Fq -- '-Dvulkan=disabled' "$libplacebo_build" ||
    fail 'libplacebo Vulkan backend must remain disabled'
grep -Fq 'git -C "${PROJECT_DIR}" apply --directory="${SRC_DIR#${PROJECT_DIR}/}" "${PROJECT_DIR}/patches/libplacebo-darwin-charconv.patch"' "$libplacebo_build" ||
    fail 'libplacebo Darwin charconv fallback patch is not applied'
for target in \
    "source_minimum='-mmacosx-version-min=10.9'" \
    "sed_expression='s/-mmacosx-version-min=10[.]9/-mmacosx-version-min=10.15/g'" \
    "source_minimum='-miphoneos-version-min=9.0'" \
    "sed_expression='s/-miphoneos-version-min=9[.]0/-miphoneos-version-min=13.0/g'" \
    "source_minimum='-mios-simulator-version-min=12.0'" \
    "sed_expression='s/-mios-simulator-version-min=12[.]0/-mios-simulator-version-min=13.0/g'" \
    "source_minimum='-mios-simulator-version-min=9.0'" \
    "sed_expression='s/-mios-simulator-version-min=9[.]0/-mios-simulator-version-min=13.0/g'"; do
    grep -Fq "$target" "$libplacebo_build" ||
        fail "libplacebo minimum deployment target is not configured: $target"
done
grep -Eq -- '-m(iphoneos|ios-simulator)-version-min=12[.]0' "$source_dir/cross-files/iossimulator-arm64.ini" ||
    fail 'pinned iOS simulator arm64 cross-file no longer matches the handled 12.0 minimum'

git -C "$source_dir" diff --quiet -- .tool-versions ||
    fail 'upstream tool-version pins were changed'
git -C "$source_dir" diff --check || fail 'Darwin recipe patch has whitespace errors'
