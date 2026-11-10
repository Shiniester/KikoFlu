#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir/../.." rev-parse --show-toplevel)
source "$script_dir/windows.lock"

work_dir="${RUNNER_TEMP:-$repo_root/build/native-audio-work/windows}"
output_dir="${NATIVE_AUDIO_OUTPUT_DIR:-$repo_root/build/native-audio/windows-output}"
source_dir="$work_dir/libmpv-win32-video-cmake"
sources_dir="$work_dir/sources"
build_dir="$work_dir/build"

fail() {
    printf 'Windows native audio build: %s\n' "$1" >&2
    exit 1
}

assert_git_source_commit() {
    local package=$1
    local expected=$2
    local actual
    actual=$(git -C "$sources_dir/$package" rev-parse HEAD)
    [[ "$actual" == "$expected" ]] || fail "$package built from $actual, expected $expected"
}

assert_git_source_base_commit() {
    local package=$1
    local expected=$2
    local actual
    actual=$(git -C "$sources_dir/$package" rev-parse HEAD^)
    [[ "$actual" == "$expected" ]] || fail "$package patch base is $actual, expected $expected"
}
dump_external_project_logs() {
    printf 'Checked out Windows dependency commits:\n'
    for package_dir in "$sources_dir"/*; do
        [[ -d "$package_dir" ]] || continue
        [[ -d "$package_dir/.git" || -f "$package_dir/.git" ]] || continue
        package_commit=$(git -C "$package_dir" rev-parse HEAD 2>/dev/null) || continue
        printf '  %s=%s\n' "$(basename "$package_dir")" "$package_commit"
    done
    find "$build_dir/toolchain" "$build_dir/packages" -type f -name '*.log' \
        -print -exec cat {} \; 2>/dev/null || true
}

[[ ! -e "$source_dir" && ! -e "$build_dir" ]] ||
    fail "work directory already exists: $work_dir"
if [[ -d "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]]; then
    fail "output directory is not empty: $output_dir"
fi

mkdir -p "$work_dir" "$output_dir"
git clone --depth 1 --branch "$RECIPE_REF" --single-branch "$RECIPE_URL" "$source_dir"
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$RECIPE_COMMIT" ]] ||
    fail "recipe tag $RECIPE_REF moved from $RECIPE_COMMIT"
git -C "$source_dir" apply --check "$script_dir/windows-effects.patch"
git -C "$source_dir" apply "$script_dir/windows-effects.patch"
git -C "$source_dir" apply --check "$script_dir/windows-toolchain.patch"
git -C "$source_dir" apply "$script_dir/windows-toolchain.patch"
git -C "$source_dir" apply --check "$script_dir/windows-dependencies.patch"
git -C "$source_dir" apply "$script_dir/windows-dependencies.patch"
git -C "$source_dir" apply --check "$script_dir/windows-zstd.patch"
git -C "$source_dir" apply "$script_dir/windows-zstd.patch"
git -C "$source_dir" apply --check "$script_dir/windows-opus.patch"
git -C "$source_dir" apply "$script_dir/windows-opus.patch"
git -C "$source_dir" apply --check "$script_dir/windows-libdvd.patch"
git -C "$source_dir" apply "$script_dir/windows-libdvd.patch"
git -C "$source_dir" apply --check "$script_dir/windows-optical-media.patch"
git -C "$source_dir" apply "$script_dir/windows-optical-media.patch"
git -C "$source_dir" apply --check "$script_dir/windows-zimg.patch"
git -C "$source_dir" apply "$script_dir/windows-zimg.patch"
git -C "$source_dir" apply --check "$script_dir/windows-fonts.patch"
git -C "$source_dir" apply "$script_dir/windows-fonts.patch"
git -C "$source_dir" apply --check "$script_dir/windows-rust.patch"
git -C "$source_dir" apply "$script_dir/windows-rust.patch"
cp "$script_dir/mpv-audio-reinit.patch" "$source_dir/packages/mpv-audio-reinit.patch"
cp "$script_dir/apply_mpv_audio_reinit.sh" "$source_dir/packages/apply_mpv_audio_reinit.sh"
cp "$script_dir/mpv-audio-controls.patch" "$source_dir/packages/mpv-audio-controls.patch"
cp "$script_dir/apply_mpv_audio_controls.sh" "$source_dir/packages/apply_mpv_audio_controls.sh"
cp "$script_dir/ffmpeg-sendcmd-precision.patch" "$source_dir/packages/ffmpeg-sendcmd-precision.patch"
cp "$script_dir/apply_ffmpeg_sendcmd_precision.sh" "$source_dir/packages/apply_ffmpeg_sendcmd_precision.sh"
cp "$script_dir/vulkan-loader-static.patch" "$source_dir/packages/vulkan-loader-static.patch"
git -C "$source_dir" apply --check "$script_dir/windows-mpv-audio-reinit.patch"
git -C "$source_dir" apply "$script_dir/windows-mpv-audio-reinit.patch"
git -C "$source_dir" apply --check "$script_dir/windows-git-closure.patch"
git -C "$source_dir" apply "$script_dir/windows-git-closure.patch"
bash "$script_dir/check_windows_config.sh" "$source_dir"

toolchain_archive="$work_dir/llvm-mingw.tar.xz"
curl --fail --location --retry 3 "$LLVM_MINGW_URL" --output "$toolchain_archive"
tar -xJf "$toolchain_archive" -C "$work_dir"
toolchain_dir="$work_dir/$LLVM_MINGW_DIR"
[[ -d "$toolchain_dir/bin" ]] || fail "llvm-mingw bundle is missing: $toolchain_dir"

ln -sf "$(command -v pkgconf)" "$toolchain_dir/bin/$TARGET_ARCH-pkgconf"
ln -sf "$(command -v pkgconf)" "$toolchain_dir/bin/$TARGET_ARCH-pkg-config"
export PATH="$toolchain_dir/bin:$PATH"
for tool in gcc g++ ar ranlib strip windres dlltool ld; do
    [[ -x "$toolchain_dir/bin/$TARGET_ARCH-$tool" ]] || fail "missing compiler tool: $TARGET_ARCH-$tool"
done
compiler_target=$("$toolchain_dir/bin/$TARGET_ARCH-gcc" -dumpmachine)
[[ "$compiler_target" == x86_64-w64-windows-gnu ]] ||
    fail "unexpected llvm-mingw compiler target: $compiler_target"

cat > "$work_dir/toolchain-smoke.cpp" <<'EOF'
#include <stdexcept>

extern "C" __declspec(dllexport) int smoke() {
    try {
        throw std::runtime_error("static runtime check");
    } catch (...) {
        return 1;
    }
}
EOF
"$toolchain_dir/bin/$TARGET_ARCH-g++" -shared -static "$work_dir/toolchain-smoke.cpp" -o "$work_dir/toolchain-smoke.dll"
"$toolchain_dir/bin/llvm-objdump" -p "$work_dir/toolchain-smoke.dll" > "$work_dir/toolchain-smoke-imports.txt"
if grep -Eiq 'DLL Name: (libc\+\+\.dll|libunwind\.dll|libwinpthread-1\.dll|libstdc\+\+-6\.dll|libgcc_s[^[:space:]]*\.dll)' "$work_dir/toolchain-smoke-imports.txt"; then
    fail "llvm-mingw smoke DLL imports a dynamic C++ runtime"
fi

cmake \
    -DTARGET_ARCH="$TARGET_ARCH" \
    -DCOMPILER_TOOLCHAIN=clang \
    -DGCC_ARCH=x86-64 \
    -DCLANG_PACKAGES_LTO=OFF \
    -DCMAKE_C_COMPILER=/usr/bin/cc \
    -DCMAKE_INSTALL_PREFIX="$toolchain_dir" \
    -DMINGW_INSTALL_PREFIX="$toolchain_dir/$TARGET_ARCH" \
    -DSINGLE_SOURCE_LOCATION="$sources_dir" \
    -DRUSTUP_LOCATION="$work_dir/rustup" \
    -G Ninja \
    -B "$build_dir" \
    -S "$source_dir"

if ! ninja -C "$build_dir" cppwinrt rustup; then
    dump_external_project_logs
    fail "cppwinrt/rustup toolchain build failed"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'rust-cache-ready=true\n' >> "$GITHUB_OUTPUT"
fi

# Upstream package patches use git am; keep their authors and set only the build committer.
export GIT_COMMITTER_NAME='Native Audio Builder'
export GIT_COMMITTER_EMAIL='native-audio-build@localhost'

actual_cppwinrt_commit=$(git -C "$sources_dir/cppwinrt" rev-parse HEAD)
[[ "$actual_cppwinrt_commit" == "$CPPWINRT_COMMIT" ]] || fail "cppwinrt built from $actual_cppwinrt_commit"
if ! ninja -C "$build_dir" mpv; then
    dump_external_project_logs
    fail "mpv build failed"
fi

actual_mpv_commit=$(git -C "$sources_dir/mpv" rev-parse HEAD)
actual_ffmpeg_commit=$(git -C "$sources_dir/ffmpeg" rev-parse HEAD)
actual_opus_commit=$(git -C "$sources_dir/opus" rev-parse HEAD)
actual_libdvdcss_commit=$(git -C "$sources_dir/libdvdcss" rev-parse HEAD)
actual_libdvdread_commit=$(git -C "$sources_dir/libdvdread" rev-parse HEAD)
actual_libdvdnav_commit=$(git -C "$sources_dir/libdvdnav" rev-parse HEAD)
actual_libbluray_commit=$(git -C "$sources_dir/libbluray" rev-parse HEAD)
actual_libudfread_commit=$(git -C "$sources_dir/libudfread" rev-parse HEAD)
actual_libzimg_commit=$(git -C "$sources_dir/libzimg" rev-parse HEAD)
actual_graphengine_commit=$(git -C "$sources_dir/graphengine" rev-parse HEAD)
actual_xxhash_commit=$(git -C "$sources_dir/xxhash" rev-parse HEAD)
actual_fontconfig_commit=$(git -C "$sources_dir/fontconfig" rev-parse HEAD)
actual_harfbuzz_commit=$(git -C "$sources_dir/harfbuzz" rev-parse HEAD)
actual_zstd_commit=$(git -C "$sources_dir/zstd" rev-parse HEAD)
actual_vulkan_commit=$(git -C "$sources_dir/vulkan" rev-parse HEAD)
actual_vulkan_headers_commit=$(git -C "$sources_dir/vulkan-header" rev-parse HEAD)
[[ "$actual_mpv_commit" == "$MPV_COMMIT" ]] || fail "mpv built from $actual_mpv_commit"
[[ "$actual_ffmpeg_commit" == "$FFMPEG_COMMIT" ]] || fail "FFmpeg built from $actual_ffmpeg_commit"
[[ "$actual_opus_commit" == "$OPUS_COMMIT" ]] || fail "Opus built from $actual_opus_commit"
[[ "$actual_libdvdcss_commit" == "$LIBDVDCSS_COMMIT" ]] || fail "libdvdcss built from $actual_libdvdcss_commit"
[[ "$actual_libdvdread_commit" == "$LIBDVDREAD_COMMIT" ]] || fail "libdvdread built from $actual_libdvdread_commit"
[[ "$actual_libdvdnav_commit" == "$LIBDVDNAV_COMMIT" ]] || fail "libdvdnav built from $actual_libdvdnav_commit"
[[ "$actual_libbluray_commit" == "$LIBBLURAY_COMMIT" ]] || fail "libbluray built from $actual_libbluray_commit"
[[ "$actual_libudfread_commit" == "$LIBUDFREAD_COMMIT" ]] || fail "libudfread built from $actual_libudfread_commit"
[[ "$actual_libzimg_commit" == "$LIBZIMG_COMMIT" ]] || fail "libzimg built from $actual_libzimg_commit"
[[ "$actual_graphengine_commit" == "$GRAPHENGINE_COMMIT" ]] || fail "graphengine built from $actual_graphengine_commit"
[[ "$actual_xxhash_commit" == "$XXHASH_COMMIT" ]] || fail "xxhash built from $actual_xxhash_commit"
[[ "$actual_fontconfig_commit" == "$FONTCONFIG_COMMIT" ]] || fail "fontconfig built from $actual_fontconfig_commit"
[[ "$actual_harfbuzz_commit" == "$HARFBUZZ_COMMIT" ]] || fail "harfbuzz built from $actual_harfbuzz_commit"
[[ "$actual_zstd_commit" == "$ZSTD_COMMIT" ]] || fail "zstd built from $actual_zstd_commit"
[[ "$actual_vulkan_commit" == "$VULKAN_COMMIT" ]] || fail "vulkan built from $actual_vulkan_commit"
[[ "$actual_vulkan_headers_commit" == "$VULKAN_HEADERS_COMMIT" ]] || fail "vulkan-header built from $actual_vulkan_headers_commit"

assert_git_source_commit amf-headers "$AMF_HEADERS_COMMIT"
assert_git_source_commit angle-headers "$ANGLE_HEADERS_COMMIT"
assert_git_source_commit avisynth-headers "$AVISYNTH_HEADERS_COMMIT"
assert_git_source_commit brotli "$BROTLI_COMMIT"
assert_git_source_commit bzip2 "$BZIP2_COMMIT"
assert_git_source_commit dav1d "$DAV1D_COMMIT"
assert_git_source_commit expat "$EXPAT_COMMIT"
assert_git_source_commit freetype2 "$FREETYPE2_COMMIT"
assert_git_source_commit fribidi "$FRIBIDI_COMMIT"
assert_git_source_commit glslang "$GLSLANG_COMMIT"
assert_git_source_commit highway "$HIGHWAY_COMMIT"
assert_git_source_commit lame "$LAME_COMMIT"
assert_git_source_commit lcms2 "$LCMS2_COMMIT"
assert_git_source_commit libarchive "$LIBARCHIVE_COMMIT"
assert_git_source_commit libass "$LIBASS_COMMIT"
assert_git_source_base_commit libbs2b "$LIBBS2B_BASE_COMMIT"
assert_git_source_commit libjpeg "$LIBJPEG_COMMIT"
assert_git_source_commit libjxl "$LIBJXL_COMMIT"
assert_git_source_commit libmodplug "$LIBMODPLUG_COMMIT"
assert_git_source_commit libmysofa "$LIBMYSOFA_COMMIT"
assert_git_source_commit libpng "$LIBPNG_COMMIT"
assert_git_source_commit libsdl2 "$LIBSDL2_COMMIT"
assert_git_source_commit libsoxr "$LIBSOXR_COMMIT"
assert_git_source_commit libsrt "$LIBSRT_COMMIT"
assert_git_source_commit libssh "$LIBSSH_COMMIT"
assert_git_source_commit libunibreak "$LIBUNIBREAK_COMMIT"
assert_git_source_commit libvpl "$LIBVPL_COMMIT"
assert_git_source_commit libwebp "$LIBWEBP_COMMIT"
assert_git_source_commit libxml2 "$LIBXML2_COMMIT"
assert_git_source_commit nvcodec-headers "$NVCODEC_HEADERS_COMMIT"
assert_git_source_commit ogg "$OGG_COMMIT"
assert_git_source_commit openssl "$OPENSSL_COMMIT"
assert_git_source_commit speex "$SPEEX_COMMIT"
assert_git_source_base_commit spirv-cross "$SPIRV_CROSS_BASE_COMMIT"
assert_git_source_commit spirv-headers "$SPIRV_HEADERS_COMMIT"
assert_git_source_commit spirv-tools "$SPIRV_TOOLS_COMMIT"
assert_git_source_commit uchardet "$UCHARDET_COMMIT"
assert_git_source_commit vorbis "$VORBIS_COMMIT"
assert_git_source_commit xz "$XZ_COMMIT"
assert_git_source_commit zlib "$ZLIB_COMMIT"
assert_git_source_commit fast_float "$FAST_FLOAT_COMMIT"
assert_git_source_commit glad "$GLAD_COMMIT"
assert_git_source_commit libdovi "$LIBDOVI_COMMIT"
assert_git_source_commit libplacebo "$LIBPLACEBO_COMMIT"
assert_git_source_commit shaderc "$SHADERC_COMMIT"
mapfile -t dev_dirs < <(find "$build_dir" -maxdepth 1 -mindepth 1 -type d -name 'mpv-dev-x86_64-*' -print)
[[ "${#dev_dirs[@]}" == 1 ]] || fail "expected one mpv-dev output directory, found ${#dev_dirs[@]}"
[[ -s "${dev_dirs[0]}/libmpv-2.dll" ]] || fail "libmpv-2.dll was not produced"
[[ -s "${dev_dirs[0]}/include/mpv/client.h" ]] || fail "libmpv client headers were not produced"
"$toolchain_dir/bin/llvm-objdump" -p "${dev_dirs[0]}/libmpv-2.dll" > "$work_dir/libmpv-imports.txt"
if grep -Eiq 'DLL Name: (libc\+\+\.dll|libunwind\.dll|libwinpthread-1\.dll|libstdc\+\+-6\.dll|libgcc_s[^[:space:]]*\.dll)' "$work_dir/libmpv-imports.txt"; then
    fail "libmpv imports a dynamic C++ runtime"
fi

mkdir -p "$output_dir/mpv-dev"
cp -a "${dev_dirs[0]}/." "$output_dir/mpv-dev/"
{
    printf 'recipe_url=%s\n' "$RECIPE_URL"
    printf 'recipe_ref=%s\n' "$RECIPE_COMMIT"
    printf 'mpv_url=%s\n' "$MPV_URL"
    printf 'mpv_commit=%s\n' "$actual_mpv_commit"
    printf 'mpv_audio_reinit_patch_commit=%s\n' "$MPV_AUDIO_REINIT_PATCH_COMMIT"
    printf 'mpv_audio_controls_patch=%s\n' 'mpv-audio-controls.patch'
    printf 'ffmpeg_url=%s\n' "$FFMPEG_URL"
    printf 'ffmpeg_commit=%s\n' "$actual_ffmpeg_commit"
    printf 'ffmpeg_sendcmd_argument_format=%s\n' '%.17g'
    printf 'vulkan_url=%s\n' "$VULKAN_URL"
    printf 'vulkan_commit=%s\n' "$actual_vulkan_commit"
    printf 'vulkan_headers_url=%s\n' "$VULKAN_HEADERS_URL"
    printf 'vulkan_headers_commit=%s\n' "$actual_vulkan_headers_commit"
    printf 'cppwinrt_ref=%s\n' "$CPPWINRT_REF"
    printf 'cppwinrt_commit=%s\n' "$actual_cppwinrt_commit"
    printf 'windows_rs_commit=%s\n' "$WINDOWS_RS_COMMIT"
    printf 'cmake_externalproject_ref=%s\n' "$CMAKE_EXTERNALPROJECT_REF"
    printf 'cmake_externalproject_commit=%s\n' "$CMAKE_EXTERNALPROJECT_COMMIT"
    printf 'compiler_url=%s\n' "$LLVM_MINGW_URL"
    printf 'compiler_bundle=%s\n' "$LLVM_MINGW_DIR"
    printf 'libbs2b_url=%s\n' "$LIBBS2B_URL"
    printf 'libbs2b_base_commit=%s\n' "$(git -C "$sources_dir/libbs2b" rev-parse HEAD^)"
    printf 'spirv_cross_url=%s\n' "$SPIRV_CROSS_URL"
    printf 'spirv_cross_base_commit=%s\n' "$(git -C "$sources_dir/spirv-cross" rev-parse HEAD^)"
    printf 'compiler=%s\n' "$("$toolchain_dir/bin/$TARGET_ARCH-gcc" --version | head -n 1)"
    printf 'compiler_resource_dir=%s\n' "$("$toolchain_dir/bin/$TARGET_ARCH-gcc" -print-resource-dir)"
    printf 'target_arch=%s\n' "$TARGET_ARCH"
    printf 'compiler_toolchain=llvm-mingw clang aliases\n'
    printf 'runtime_flags=-static -Wl,--pdb=\n'
    printf 'lzo_version=2.10\n'
    printf 'lzo_url=%s\n' "$LZO_URL"
    printf 'rust_version=%s\n' "$RUST_VERSION"
    printf 'rust_target=%s\n' "$RUST_TARGET"
    printf 'cargo_c_version=%s\n' "$CARGO_C_VERSION"
    printf 'cargo_c_locked_cargo_crate=%s\n' "$CARGO_CRATE_VERSION"
    printf 'cargo_cli=%s\n' "$("$build_dir/exec" cargo +"$RUST_VERSION" --version)"
    printf 'cmake=%s\n' "$(cmake --version | head -n 1)"
    printf 'ninja=%s\n' "$(ninja --version)"
    printf 'meson=%s\n' "$(meson --version)"
    printf 'filters=%s\n' "$(paste -sd, "$script_dir/filters.txt"),overlay,equalizer"
    printf 'built_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'other_git_sources:\n'
    for package_dir in "$sources_dir"/*; do
        [[ -d "$package_dir" ]] || continue
        [[ -e "$package_dir/.git" ]] || continue
        package_commit=$(git -C "$package_dir" rev-parse HEAD 2>/dev/null) || continue
        printf '  %s=%s\n' "$(basename "$package_dir")" "$package_commit"
    done
} > "$output_dir/source-provenance.txt"
