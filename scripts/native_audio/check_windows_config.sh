#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/windows.lock"
source_dir=${1:?Usage: check_windows_config.sh <libmpv-win32-video-cmake source>}
ffmpeg_config="$source_dir/packages/ffmpeg.cmake"
openssl_config="$source_dir/packages/openssl.cmake"
libarchive_config="$source_dir/packages/libarchive.cmake"
libass_config="$source_dir/packages/libass.cmake"
libplacebo_config="$source_dir/packages/libplacebo.cmake"
mpv_config="$source_dir/packages/mpv.cmake"
opus_config="$source_dir/packages/opus.cmake"
opus_dnn_config="$source_dir/packages/opus-dnn.cmake"
libdvdcss_config="$source_dir/packages/libdvdcss.cmake"
libdvdread_config="$source_dir/packages/libdvdread.cmake"
libdvdnav_config="$source_dir/packages/libdvdnav.cmake"
libbluray_config="$source_dir/packages/libbluray.cmake"
libudfread_config="$source_dir/packages/libudfread.cmake"
libzimg_config="$source_dir/packages/libzimg.cmake"
graphengine_config="$source_dir/packages/graphengine.cmake"
fontconfig_config="$source_dir/packages/fontconfig.cmake"
harfbuzz_config="$source_dir/packages/harfbuzz.cmake"
game_music_emu_config="$source_dir/packages/game-music-emu.cmake"
x265_config="$source_dir/packages/x265.cmake"
xxhash_config="$source_dir/packages/xxhash.cmake"
vulkan_header_config="$source_dir/packages/vulkan-header.cmake"
vulkan_config="$source_dir/packages/vulkan.cmake"
toolchain_config="$source_dir/toolchain/CMakeLists.txt"

fail() {
    printf 'Windows native audio build config: %s\n' "$1" >&2
    exit 1
}

check_git_pin() {
    local name=$1
    local url=$2
    local commit=$3
    local config=$4

    grep -Fqx "    GIT_REPOSITORY $url" "$config" || fail "$name source repository changed"
    grep -Fqx "    GIT_TAG $commit" "$config" || fail "$name source is not pinned to $commit"
    if grep -Fq 'GIT_REMOTE_NAME' "$config"; then
        fail "pinned $name must use the commit reset path"
    fi
}

[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$RECIPE_COMMIT" ]] ||
    fail "recipe ref does not match $RECIPE_COMMIT"
if grep -Fqx '        openal-soft' "$ffmpeg_config"; then
    fail "FFmpeg must not build the unused OpenAL dependency"
fi
grep -Fqx '        --prefer-static' "$libass_config" ||
    fail "libass must resolve static dependency requirements"
grep -Fqx '        -Dvulkan=enabled' "$libplacebo_config" ||
    fail "libplacebo must build with Vulkan support"
grep -Fqx '        -Dmanpage-build=disabled' "$mpv_config" ||
    fail "mpv-dev build must not require manual generation"
grep -Fq -- '-DEGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE=0x3207' "$mpv_config" ||
    fail "mpv must define the ANGLE D3D9 enum missing from the pinned headers"
if grep -Fq '<BINARY_DIR>/mpv.pdf' "$mpv_config"; then
    fail "mpv-dev build must not copy an unbuilt PDF"
fi
for header in client.h stream_cb.h render.h render_gl.h; do
    grep -Fq "<SOURCE_DIR>/include/mpv/$header" "$mpv_config" ||
        fail "mpv-dev build must copy $header from the mpv 0.42 public header directory"
    if grep -Fq "<SOURCE_DIR>/libmpv/$header" "$mpv_config"; then
        fail "mpv-dev build must not use the removed libmpv header directory"
    fi
done
cmp -s "$script_dir/libarchive-openssl-static.patch" "$source_dir/packages/libarchive-openssl-static.patch" ||
    fail "libarchive OpenSSL patch differs from the checked patch"
grep -Fqx '    PATCH_COMMAND ${EXEC} git apply ${CMAKE_CURRENT_SOURCE_DIR}/libarchive-openssl-static.patch' "$libarchive_config" ||
    fail "libarchive OpenSSL patch is not applied during the source build"
grep -Fqx '    GIT_TAG $ENV{FFMPEG_COMMIT}' "$ffmpeg_config" ||
    fail "FFmpeg source is not pinned to $FFMPEG_COMMIT"
if grep -Fqx '        no-srtp' "$openssl_config"; then
    fail "OpenSSL SRTP APIs must remain enabled for FFmpeg's DTLS support"
fi
grep -Fqx '        --enable-openssl' "$ffmpeg_config" ||
    fail "FFmpeg HTTPS/TLS must keep OpenSSL support enabled"
for protocol in https tls; do
    grep -Fqx "        --enable-protocol=$protocol" "$ffmpeg_config" ||
        fail "FFmpeg $protocol protocol must remain enabled"
done
if grep -Eq '^[[:space:]]*--(disable-postproc|enable-libshaderc)(=|[[:space:]]|$)' "$ffmpeg_config"; then
    fail "FFmpeg 9.0.2 configure options must not include postproc or libshaderc"
fi
if [[ -e "$source_dir/packages/ffmpeg-dash-base-url-escape.patch" ]]; then
    fail "FFmpeg 9.0.2 already escapes DASH BaseURL content"
fi
[[ -f "$source_dir/packages/ffmpeg-sendcmd-precision.patch" ]] ||
    fail "FFmpeg sendcmd precision patch is missing from the recipe"
[[ -f "$source_dir/packages/apply_ffmpeg_sendcmd_precision.sh" ]] ||
    fail "FFmpeg sendcmd precision verifier is missing from the recipe"
cmp -s "$script_dir/ffmpeg-sendcmd-precision.patch" "$source_dir/packages/ffmpeg-sendcmd-precision.patch" ||
    fail "FFmpeg sendcmd precision patch differs from the checked patch"
cmp -s "$script_dir/apply_ffmpeg_sendcmd_precision.sh" "$source_dir/packages/apply_ffmpeg_sendcmd_precision.sh" ||
    fail "FFmpeg sendcmd precision verifier differs from the checked script"
bash "$script_dir/apply_ffmpeg_sendcmd_precision.sh" --check-patch \
    "$script_dir/ffmpeg-sendcmd-precision.patch" ||
    fail "FFmpeg sendcmd precision patch changed"
grep -Fq 'ffmpeg-*.patch' "$ffmpeg_config" ||
    fail "FFmpeg patch glob does not include the sendcmd precision patch"
patch_command_line=$(grep -Fn 'PATCH_COMMAND ${EXEC} git apply ${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg-*.patch' "$ffmpeg_config" | cut -d: -f1)
verify_command_line=$(grep -Fn 'COMMAND ${EXEC} bash ${CMAKE_CURRENT_LIST_DIR}/apply_ffmpeg_sendcmd_precision.sh' "$ffmpeg_config" | cut -d: -f1)
configure_command_line=$(grep -Fn 'CONFIGURE_COMMAND ${EXEC} CONF=1 <SOURCE_DIR>/configure' "$ffmpeg_config" | cut -d: -f1)
[[ -n "$patch_command_line" && -n "$verify_command_line" && -n "$configure_command_line" ]] ||
    fail "FFmpeg patch application and pre-build verification steps are required"
[[ "$patch_command_line" -lt "$verify_command_line" && "$verify_command_line" -lt "$configure_command_line" ]] ||
    fail "FFmpeg precision verification must run after patching and before configure"
grep -Fqx '            --verify <SOURCE_DIR> $ENV{FFMPEG_COMMIT} ${CMAKE_CURRENT_LIST_DIR}/ffmpeg-sendcmd-precision.patch' "$ffmpeg_config" ||
    fail "FFmpeg precision verifier is not bound to the pinned source and patch"
grep -Fqx '    GIT_TAG $ENV{MPV_COMMIT}' "$mpv_config" ||
    fail "mpv source is not pinned to $MPV_COMMIT"
[[ -f "$source_dir/packages/mpv-audio-controls.patch" ]] ||
    fail "mpv audio controls patch is missing from the recipe"
[[ -f "$source_dir/packages/apply_mpv_audio_controls.sh" ]] ||
    fail "mpv audio controls patch runner is missing from the recipe"
cmp -s "$script_dir/mpv-audio-controls.patch" "$source_dir/packages/mpv-audio-controls.patch" ||
    fail "mpv audio controls patch differs from the checked patch"
cmp -s "$script_dir/apply_mpv_audio_controls.sh" "$source_dir/packages/apply_mpv_audio_controls.sh" ||
    fail "mpv audio controls patch runner differs from the checked runner"
bash "$script_dir/apply_mpv_audio_controls.sh" --check-patch \
    "$script_dir/mpv-audio-controls.patch" ||
    fail "mpv audio controls patch changed"
grep -Fqx '    PATCH_COMMAND bash' "$mpv_config" ||
    fail "mpv audio controls patch is not applied during the source build"
grep -Fqx '        ${CMAKE_CURRENT_LIST_DIR}/apply_mpv_audio_controls.sh' "$mpv_config" ||
    fail "mpv audio controls patch runner is not configured"
grep -Fqx '        --apply' "$mpv_config" || fail "mpv controls patch runner mode changed"
grep -Fqx '        <SOURCE_DIR>' "$mpv_config" || fail "mpv controls patch source directory changed"
grep -Fqx '        $ENV{MPV_COMMIT}' "$mpv_config" ||
    fail "mpv audio controls patch source does not match the pinned mpv commit"
grep -Fqx '        ${CMAKE_CURRENT_LIST_DIR}/mpv-audio-controls.patch' "$mpv_config" ||
    fail "mpv audio controls patch path changed"
if grep -Fq 'apply_mpv_audio_reinit' "$mpv_config"; then
    fail "mpv reinit patch must not be reapplied over mpv 0.42.0"
fi
if grep -Fq 'apply_mpv_audio_reinit' "$script_dir/build_windows.sh"; then
    fail "mpv reinit patch must not be applied over mpv 0.42.0"
fi

grep -Fqx "    GIT_REPOSITORY $OPUS_URL" "$opus_config" ||
    fail "Opus source repository changed"
grep -Fqx "    GIT_TAG $OPUS_COMMIT" "$opus_config" ||
    fail "Opus source is not pinned to $OPUS_COMMIT"
if grep -Fq 'GIT_REMOTE_NAME' "$opus_config"; then
    fail "pinned Opus must use the commit reset path"
fi
check_git_pin libdvdcss "$LIBDVDCSS_URL" "$LIBDVDCSS_COMMIT" "$libdvdcss_config"
check_git_pin libdvdread "$LIBDVDREAD_URL" "$LIBDVDREAD_COMMIT" "$libdvdread_config"
check_git_pin libdvdnav "$LIBDVDNAV_URL" "$LIBDVDNAV_COMMIT" "$libdvdnav_config"
check_git_pin libbluray "$LIBBLURAY_URL" "$LIBBLURAY_COMMIT" "$libbluray_config"
check_git_pin libudfread "$LIBUDFREAD_URL" "$LIBUDFREAD_COMMIT" "$libudfread_config"
check_git_pin libzimg "$LIBZIMG_URL" "$LIBZIMG_COMMIT" "$libzimg_config"
check_git_pin graphengine "$GRAPHENGINE_URL" "$GRAPHENGINE_COMMIT" "$graphengine_config"
check_git_pin fontconfig "$FONTCONFIG_URL" "$FONTCONFIG_COMMIT" "$fontconfig_config"
check_git_pin harfbuzz "$HARFBUZZ_URL" "$HARFBUZZ_COMMIT" "$harfbuzz_config"
grep -Fqx '    PATCH_COMMAND ${EXEC} git apply ${CMAKE_CURRENT_SOURCE_DIR}/fontconfig-*.patch' "$fontconfig_config" ||
    fail "fontconfig patches must not create commits during the build"
grep -Fqx '        -Dutilities=disabled' "$harfbuzz_config" ||
    fail "unused HarfBuzz command-line tools must be disabled"
grep -Fqx "    GIT_REPOSITORY $GAME_MUSIC_EMU_URL" "$game_music_emu_config" ||
    fail "game-music-emu source repository changed"
grep -Fqx "    GIT_REPOSITORY $X265_URL" "$x265_config" ||
    fail "x265 source repository changed"
check_git_pin xxhash "$XXHASH_URL" "$XXHASH_COMMIT" "$xxhash_config"
check_git_pin vulkan-header "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_COMMIT" "$vulkan_header_config"
check_git_pin vulkan "$VULKAN_URL" "$VULKAN_COMMIT" "$vulkan_config"
[[ -f "$source_dir/packages/vulkan-loader-static.patch" ]] ||
    fail "compatible Vulkan loader patch is missing from the recipe"
cmp -s "$script_dir/vulkan-loader-static.patch" "$source_dir/packages/vulkan-loader-static.patch" ||
    fail "Vulkan loader patch differs from the checked patch"
grep -Fqx '    PATCH_COMMAND ${EXEC} git apply --unidiff-zero --check ${CMAKE_CURRENT_LIST_DIR}/vulkan-loader-static.patch' "$vulkan_config" ||
    fail "Vulkan loader patch must be checked before application"
grep -Fqx '        COMMAND ${EXEC} git apply --unidiff-zero ${CMAKE_CURRENT_LIST_DIR}/vulkan-loader-static.patch' "$vulkan_config" ||
    fail "Vulkan loader patch application command changed"
vulkan_patch_check_line=$(grep -Fn 'PATCH_COMMAND ${EXEC} git apply --unidiff-zero --check ${CMAKE_CURRENT_LIST_DIR}/vulkan-loader-static.patch' "$vulkan_config" | cut -d: -f1)
vulkan_patch_apply_line=$(grep -Fn 'COMMAND ${EXEC} git apply --unidiff-zero ${CMAKE_CURRENT_LIST_DIR}/vulkan-loader-static.patch' "$vulkan_config" | cut -d: -f1)
[[ -n "$vulkan_patch_check_line" && -n "$vulkan_patch_apply_line" && "$vulkan_patch_check_line" -lt "$vulkan_patch_apply_line" ]] ||
    fail "Vulkan loader patch must be checked before application"
grep -Fqx '    URL https://media.xiph.org/opus/models/opus_data-735117b.tar.gz' "$opus_dnn_config" ||
    fail "Opus DNN model package does not match v1.5.2"
grep -Fqx '    URL_HASH SHA256=8f34305a299183509d22c7ba66790f67916a0fc56028ebd4c8f7b938458f2801' "$opus_dnn_config" ||
    fail "Opus DNN model package hash changed"
grep -Fqx '    cppwinrt' "$toolchain_config" || fail "cppwinrt build target is not enabled"
grep -Fqx '    rustup' "$toolchain_config" || fail "rustup build target is not enabled"
[[ "$(sed -n '/list(APPEND ep/,/^)/p' "$toolchain_config" | grep -Ec '^    ')" == 2 ]] ||
    fail "prebuilt compiler configuration must keep only cppwinrt and rustup targets"
grep -Fq -- "-Dc_link_args='-static -Wl,--pdb='" "$mpv_config" ||
    fail "mpv C link arguments must use the prebuilt static runtime and PDB name"
grep -Fq -- "-Dcpp_link_args='-static -Wl,--pdb='" "$mpv_config" ||
    fail "mpv C++ link arguments must use the prebuilt static runtime and PDB name"
[[ "$(grep -Ec '^[[:space:]]*--disable-filters[[:space:]]*$' "$ffmpeg_config")" == 1 ]] ||
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
    sed -nE 's/^[[:space:]]*--enable-filter=([[:alnum:]_]+)[[:space:]]*$/\1/p' "$ffmpeg_config" |
        LC_ALL=C sort
)
if [[ "$actual_filters" != "$expected_filters" ]]; then
    diff -u <(printf '%s\n' "$expected_filters") <(printf '%s\n' "$actual_filters") || true
    fail "FFmpeg filter allowlist differs from scripts/native_audio/filters.txt"
fi

cppwinrt_config="$source_dir/toolchain/cppwinrt.cmake"
grep -Fqx "    GIT_TAG $CPPWINRT_REF" "$cppwinrt_config" ||
    fail "cppwinrt ref is not pinned to $CPPWINRT_REF"
grep -Fqx '    GIT_SHALLOW TRUE' "$cppwinrt_config" ||
    fail "cppwinrt must use a shallow clone"
grep -Fq "$WINDOWS_RS_COMMIT/crates/libs/bindgen/default/Windows.winmd" "$cppwinrt_config" ||
    fail "Windows.winmd source is not pinned to $WINDOWS_RS_COMMIT"

externalproject_config="$source_dir/cmake/download_externalproject.cmake"
grep -Fq "/archive/$CMAKE_EXTERNALPROJECT_COMMIT/cmake-$CMAKE_EXTERNALPROJECT_COMMIT.tar.gz?path=Modules/ExternalProject" "$externalproject_config" ||
    fail "ExternalProject templates are not pinned to CMake v$CMAKE_EXTERNALPROJECT_REF"
grep -Fq "/raw/$CMAKE_EXTERNALPROJECT_COMMIT/Modules/ExternalProject.cmake" "$externalproject_config" ||
    fail "ExternalProject module is not pinned to CMake v$CMAKE_EXTERNALPROJECT_REF"

lzo_config="$source_dir/packages/lzo.cmake"
grep -Fqx "    URL \"$LZO_URL\"" "$lzo_config" || fail "LZO 2.10 source URL changed"
grep -Fqx '    URL_HASH SHA1=4924676a9bae5db58ef129dc1cebce3baa3c4b5d' "$lzo_config" ||
    fail "LZO 2.10 source hash changed"

rustup_config="$source_dir/toolchain/rustup.cmake"
grep -Fq -- "--default-toolchain $RUST_VERSION" "$rustup_config" ||
    fail "Rust toolchain is not pinned to $RUST_VERSION"
grep -Fqx "        sh -s -- -y --default-toolchain $RUST_VERSION --target $RUST_TARGET --no-modify-path --profile minimal" "$rustup_config" ||
    fail "Rust target is not pinned to $RUST_TARGET"
grep -Fq -- "cargo +$RUST_VERSION install cargo-c --version $CARGO_C_VERSION --locked" "$rustup_config" ||
    fail "cargo-c is not pinned to $CARGO_C_VERSION with its lockfile"
grep -Fqx '    BUILD_COMMAND ""' "$rustup_config" ||
    fail "Rust toolchain update step must stay disabled"
if grep -Fq 'rustup update' "$rustup_config"; then
    fail "floating rustup update is not allowed"
fi

check_git_pin amf-headers "$AMF_HEADERS_URL" "$AMF_HEADERS_COMMIT" "$source_dir/packages/amf-headers.cmake"
check_git_pin angle-headers "$ANGLE_HEADERS_URL" "$ANGLE_HEADERS_COMMIT" "$source_dir/packages/angle-headers.cmake"
check_git_pin avisynth-headers "$AVISYNTH_HEADERS_URL" "$AVISYNTH_HEADERS_COMMIT" "$source_dir/packages/avisynth-headers.cmake"
check_git_pin brotli "$BROTLI_URL" "$BROTLI_COMMIT" "$source_dir/packages/brotli.cmake"
check_git_pin bzip2 "$BZIP2_URL" "$BZIP2_COMMIT" "$source_dir/packages/bzip2.cmake"
check_git_pin dav1d "$DAV1D_URL" "$DAV1D_COMMIT" "$source_dir/packages/dav1d.cmake"
check_git_pin expat "$EXPAT_URL" "$EXPAT_COMMIT" "$source_dir/packages/expat.cmake"
check_git_pin freetype2 "$FREETYPE2_URL" "$FREETYPE2_COMMIT" "$source_dir/packages/freetype2.cmake"
check_git_pin fribidi "$FRIBIDI_URL" "$FRIBIDI_COMMIT" "$source_dir/packages/fribidi.cmake"
check_git_pin glslang "$GLSLANG_URL" "$GLSLANG_COMMIT" "$source_dir/packages/glslang.cmake"
check_git_pin highway "$HIGHWAY_URL" "$HIGHWAY_COMMIT" "$source_dir/packages/highway.cmake"
check_git_pin lame "$LAME_URL" "$LAME_COMMIT" "$source_dir/packages/lame.cmake"
check_git_pin lcms2 "$LCMS2_URL" "$LCMS2_COMMIT" "$source_dir/packages/lcms2.cmake"
check_git_pin libarchive "$LIBARCHIVE_URL" "$LIBARCHIVE_COMMIT" "$source_dir/packages/libarchive.cmake"
check_git_pin libass "$LIBASS_URL" "$LIBASS_COMMIT" "$source_dir/packages/libass.cmake"
check_git_pin libbs2b "$LIBBS2B_URL" "$LIBBS2B_BASE_COMMIT" "$source_dir/packages/libbs2b.cmake"
check_git_pin libjpeg "$LIBJPEG_URL" "$LIBJPEG_COMMIT" "$source_dir/packages/libjpeg.cmake"
check_git_pin libjxl "$LIBJXL_URL" "$LIBJXL_COMMIT" "$source_dir/packages/libjxl.cmake"
check_git_pin libmodplug "$LIBMODPLUG_URL" "$LIBMODPLUG_COMMIT" "$source_dir/packages/libmodplug.cmake"
check_git_pin libmysofa "$LIBMYSOFA_URL" "$LIBMYSOFA_COMMIT" "$source_dir/packages/libmysofa.cmake"
check_git_pin libpng "$LIBPNG_URL" "$LIBPNG_COMMIT" "$source_dir/packages/libpng.cmake"
check_git_pin libsdl2 "$LIBSDL2_URL" "$LIBSDL2_COMMIT" "$source_dir/packages/libsdl2.cmake"
check_git_pin libsoxr "$LIBSOXR_URL" "$LIBSOXR_COMMIT" "$source_dir/packages/libsoxr.cmake"
check_git_pin libsrt "$LIBSRT_URL" "$LIBSRT_COMMIT" "$source_dir/packages/libsrt.cmake"
check_git_pin libssh "$LIBSSH_URL" "$LIBSSH_COMMIT" "$source_dir/packages/libssh.cmake"
check_git_pin libunibreak "$LIBUNIBREAK_URL" "$LIBUNIBREAK_COMMIT" "$source_dir/packages/libunibreak.cmake"
check_git_pin libvpl "$LIBVPL_URL" "$LIBVPL_COMMIT" "$source_dir/packages/libvpl.cmake"
check_git_pin libwebp "$LIBWEBP_URL" "$LIBWEBP_COMMIT" "$source_dir/packages/libwebp.cmake"
check_git_pin libxml2 "$LIBXML2_URL" "$LIBXML2_COMMIT" "$source_dir/packages/libxml2.cmake"
check_git_pin nvcodec-headers "$NVCODEC_HEADERS_URL" "$NVCODEC_HEADERS_COMMIT" "$source_dir/packages/nvcodec-headers.cmake"
check_git_pin ogg "$OGG_URL" "$OGG_COMMIT" "$source_dir/packages/ogg.cmake"
check_git_pin openssl "$OPENSSL_URL" "$OPENSSL_COMMIT" "$source_dir/packages/openssl.cmake"
check_git_pin speex "$SPEEX_URL" "$SPEEX_COMMIT" "$source_dir/packages/speex.cmake"
check_git_pin spirv-cross "$SPIRV_CROSS_URL" "$SPIRV_CROSS_BASE_COMMIT" "$source_dir/packages/spirv-cross.cmake"
check_git_pin spirv-headers "$SPIRV_HEADERS_URL" "$SPIRV_HEADERS_COMMIT" "$source_dir/packages/spirv-headers.cmake"
check_git_pin spirv-tools "$SPIRV_TOOLS_URL" "$SPIRV_TOOLS_COMMIT" "$source_dir/packages/spirv-tools.cmake"
check_git_pin uchardet "$UCHARDET_URL" "$UCHARDET_COMMIT" "$source_dir/packages/uchardet.cmake"
check_git_pin vorbis "$VORBIS_URL" "$VORBIS_COMMIT" "$source_dir/packages/vorbis.cmake"
check_git_pin xz "$XZ_URL" "$XZ_COMMIT" "$source_dir/packages/xz.cmake"
check_git_pin zlib "$ZLIB_URL" "$ZLIB_COMMIT" "$source_dir/packages/zlib.cmake"
grep -Fq 'git am --3way' "$source_dir/packages/libbs2b.cmake" ||
    fail "libbs2b patch application command changed"
grep -Fq 'git am --3way' "$source_dir/packages/spirv-cross.cmake" ||
    fail "SPIRV-Cross patch application command changed"
grep -Fq 'windows-git-closure.patch' "$script_dir/build_windows.sh" ||
    fail "Windows immutable Git source pin patch is not applied"
check_git_pin fast_float "$FAST_FLOAT_URL" "$FAST_FLOAT_COMMIT" "$source_dir/packages/fast_float.cmake"
check_git_pin glad "$GLAD_URL" "$GLAD_COMMIT" "$source_dir/packages/glad.cmake"
check_git_pin libdovi "$LIBDOVI_URL" "$LIBDOVI_COMMIT" "$source_dir/packages/libdovi.cmake"
grep -Fqx "    GIT_REPOSITORY $LIBPLACEBO_URL" "$libplacebo_config" ||
    fail "libplacebo source repository changed"
grep -Fqx '    GIT_TAG $ENV{LIBPLACEBO_COMMIT}' "$libplacebo_config" ||
    fail "libplacebo source is not pinned to $LIBPLACEBO_COMMIT"
check_git_pin shaderc "$SHADERC_URL" "$SHADERC_COMMIT" "$source_dir/packages/shaderc.cmake"
zstd_config="$source_dir/packages/zstd.cmake"
grep -Fqx "    GIT_REPOSITORY $ZSTD_URL" "$zstd_config" ||
    fail "zstd source repository changed"
grep -Fqx "    GIT_TAG $ZSTD_COMMIT" "$zstd_config" ||
    fail "zstd source is not pinned to $ZSTD_COMMIT"
if grep -Fq 'GIT_REMOTE_NAME' "$zstd_config"; then
    fail "pinned zstd must use the commit reset path"
fi
