#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir/../.." rev-parse --show-toplevel)
source "$script_dir/darwin.lock"

output_dir="$repo_root/build/native-audio/darwin-output"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/native-audio-darwin.XXXXXX")
recipe_dir="$work_dir/libmpv-darwin-build"

fail() {
    printf 'Darwin native audio build: %s\n' "$1" >&2
    exit 1
}

trap 'rm -rf "$work_dir"' EXIT

[[ "$(uname -s)" == Darwin ]] || fail 'this build must run on macOS'
[[ -x "$(command -v xcodebuild || true)" && -x "$(command -v xcrun || true)" && -x "$(command -v xcode-select || true)" ]] ||
    fail 'Xcode command line tools are missing'

actual_developer_dir=$(xcode-select -p)
export DEVELOPER_DIR="$actual_developer_dir"
xcode_version_output=$(xcodebuild -version)
actual_xcode=$(awk '$1 == "Xcode" { print $2 }' <<<"$xcode_version_output")
actual_xcode_build=$(awk '$1 == "Build" { print $3 }' <<<"$xcode_version_output")
[[ "$actual_xcode" == "$DARWIN_XCODE_VERSION" ]] ||
    fail "Xcode is $actual_xcode, expected $DARWIN_XCODE_VERSION"
[[ "$actual_xcode_build" == "$DARWIN_XCODE_BUILD" ]] ||
    fail "Xcode build is $actual_xcode_build, expected $DARWIN_XCODE_BUILD"
actual_ios_sdk=$(xcrun --sdk iphoneos --show-sdk-version)
actual_macos_sdk=$(xcrun --sdk macosx --show-sdk-version)
actual_ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
actual_macos_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
actual_ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
[[ "$actual_ios_sdk" == "$DARWIN_IOS_SDK_VERSION" ]] ||
    fail 'iOS SDK version differs from darwin.lock'
[[ "$actual_macos_sdk" == "$DARWIN_MACOS_SDK_VERSION" ]] ||
    fail 'macOS SDK version differs from darwin.lock'
actual_python=$(python3 --version 2>&1)
actual_go=$(go version)
actual_go_version=$(awk '{ sub(/^go/, "", $3); print $3 }' <<<"$actual_go")
actual_cmake=$(cmake --version | awk 'NR == 1 { print $3 }')
actual_meson=$(meson --version)
actual_ninja=$(ninja --version)
actual_make=$(make --version | awk 'NR == 1 { print $3 }')
actual_clang_output=$(xcrun clang --version)
actual_clang=${actual_clang_output%%$'\n'*}
[[ "$actual_python" == "Python $DARWIN_PYTHON_VERSION" ]] ||
    fail 'Python version differs from darwin.lock'
[[ "$actual_go_version" == "$DARWIN_GO_VERSION" ]] ||
    fail 'Go version differs from darwin.lock'
[[ "$actual_cmake" == "$DARWIN_CMAKE_VERSION" ]] ||
    fail 'CMake version differs from darwin.lock'
[[ "$actual_meson" == "$DARWIN_MESON_VERSION" ]] ||
    fail 'Meson version differs from darwin.lock'
[[ "$actual_ninja" == "$DARWIN_NINJA_VERSION" ]] ||
    fail "Ninja version is $actual_ninja, expected $DARWIN_NINJA_VERSION"
[[ "$actual_make" == "$DARWIN_MAKE_VERSION" ]] ||
    fail 'Make version differs from darwin.lock'

git clone --depth 1 --branch "$DARWIN_RECIPE_REF" --single-branch \
    "$DARWIN_RECIPE_URL" "$recipe_dir"
actual_commit=$(git -C "$recipe_dir" rev-parse HEAD)
[[ "$actual_commit" == "$DARWIN_RECIPE_COMMIT" ]] ||
    fail "recipe tag $DARWIN_RECIPE_REF resolved to $actual_commit, expected $DARWIN_RECIPE_COMMIT"

git -C "$recipe_dir" apply --check "$script_dir/darwin-recipe.patch" ||
    fail 'Darwin recipe patch does not apply cleanly'
git -C "$recipe_dir" apply "$script_dir/darwin-recipe.patch"
git -C "$recipe_dir" apply --unidiff-zero --check "$script_dir/darwin-download-retry.patch" ||
    fail 'Darwin download retry patch does not apply cleanly'
git -C "$recipe_dir" apply --unidiff-zero "$script_dir/darwin-download-retry.patch"
cp "$script_dir/darwin_download_test.go" "$recipe_dir/cmd/downloads/retry_test.go"
(cd "$recipe_dir" && go test ./cmd/downloads)
python3 "$script_dir/rewrite_darwin_sdk_paths.py" "$recipe_dir/cross-files" \
    --macos-sdk "$actual_macos_sdk_path" \
    --ios-sdk "$actual_ios_sdk_path" \
    --ios-simulator-sdk "$actual_ios_simulator_sdk_path"
cp "$script_dir/libpng-macos-fp-header.patch" "$recipe_dir/patches/libpng-macos-fp-header.patch"
cp "$script_dir/ffmpeg-sendcmd-precision.patch" "$recipe_dir/patches/ffmpeg-sendcmd-precision.patch"
cp "$script_dir/mpv-filter-command-target.patch" "$recipe_dir/patches/mpv-filter-command-target.patch"
cp "$script_dir/mpv-audio-reinit.patch" "$recipe_dir/patches/mpv-audio-reinit.patch"
cp "$script_dir/mpv-audio-controls.patch" "$recipe_dir/patches/mpv-audio-controls.patch"
cp "$script_dir/pkg-config-glib-atomics.patch" "$recipe_dir/patches/pkg-config-glib-atomics.patch"
bash "$script_dir/check_darwin_config.sh" "$recipe_dir"

printf 'Darwin recipe: %s @ %s\n' "$DARWIN_RECIPE_REF" "$actual_commit"
printf 'Xcode: %s (%s), iOS SDK %s, macOS SDK %s\n' \
    "$actual_xcode" "$actual_xcode_build" "$actual_ios_sdk" "$actual_macos_sdk"
printf 'Selected developer directory: %s\n' "$actual_developer_dir"
printf 'Clang toolchain:\n'
xcrun clang --version
printf 'FFmpeg and MPV source pins:\n'
grep -A3 '^ffmpeg:' "$recipe_dir/downloads.lock"
grep -A3 '^mpv:' "$recipe_dir/downloads.lock"

ios_artifact="build/output/libmpv-xcframeworks_${DARWIN_OUTPUT_VERSION}_ios-universal-video-default.tar.gz"
macos_artifact="build/output/libmpv-xcframeworks_${DARWIN_OUTPUT_VERSION}_macos-universal-video-default.tar.gz"
(
    cd "$recipe_dir"
    make "VERSION=$DARWIN_OUTPUT_VERSION" "$ios_artifact" "$macos_artifact"
)

python3 "$script_dir/check_darwin_artifacts.py" \
    --ios-archive "$recipe_dir/$ios_artifact" \
    --macos-archive "$recipe_dir/$macos_artifact" \
    --ios-min "$DARWIN_IOS_MIN_VERSION" \
    --macos-min "$DARWIN_MACOS_MIN_VERSION"

mkdir -p "$output_dir"
cp -f "$recipe_dir/$ios_artifact" "$output_dir/"
cp -f "$recipe_dir/$macos_artifact" "$output_dir/"
{
    printf 'recipe_url=%s\n' "$DARWIN_RECIPE_URL"
    printf 'recipe_ref=%s\n' "$DARWIN_RECIPE_REF"
    printf 'recipe_commit=%s\n' "$actual_commit"
    printf 'developer_dir=%s\n' "$actual_developer_dir"
    printf 'macos_sdk_path=%s\n' "$actual_macos_sdk_path"
    printf 'ios_sdk_path=%s\n' "$actual_ios_sdk_path"
    printf 'ios_simulator_sdk_path=%s\n' "$actual_ios_simulator_sdk_path"
    printf 'xcode=%s\n' "$actual_xcode"
    printf 'xcode_build=%s\n' "$actual_xcode_build"
    printf 'ios_sdk=%s\n' "$actual_ios_sdk"
    printf 'macos_sdk=%s\n' "$actual_macos_sdk"
    printf 'python=%s\n' "$actual_python"
    printf 'go=%s\n' "$actual_go"
    printf 'cmake=%s\n' "$actual_cmake"
    printf 'meson=%s\n' "$actual_meson"
    printf 'ninja=%s\n' "$actual_ninja"
    printf 'make=GNU Make %s\n' "$actual_make"
    printf 'clang=%s\n' "$actual_clang"
    printf 'mpv_source_version=%s\n' "$DARWIN_MPV_VERSION"
    printf 'mpv_source_tag_commit=%s\n' "$DARWIN_MPV_COMMIT"
    printf 'ios_minimum=%s\n' "$DARWIN_IOS_MIN_VERSION"
    printf 'macos_minimum=%s\n' "$DARWIN_MACOS_MIN_VERSION"
    printf 'filters=%s,overlay,equalizer\n' "$(paste -sd, "$script_dir/filters.txt")"
    printf 'patches=darwin-recipe.patch,darwin-download-retry.patch,libpng-macos-fp-header.patch,ffmpeg-sendcmd-precision.patch,mpv-filter-command-target.patch,mpv-audio-reinit.patch,mpv-audio-controls.patch,pkg-config-glib-atomics.patch\n'
    printf 'built_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '\nupstream_downloads.lock:\n'
    sed 's/^/  /' "$recipe_dir/downloads.lock"
} > "$output_dir/source-provenance.txt"
printf 'Darwin artifacts written to %s\n' "$output_dir"
