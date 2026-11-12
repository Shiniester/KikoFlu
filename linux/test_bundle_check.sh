#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
checker="$script_dir/check_linux_bundle.sh"
packer="$script_dir/package_linux_libmpv.sh"
lddtree_bin=${LDDTREE_BIN:-lddtree}
patchelf_bin=${PATCHELF_BIN:-patchelf}
readelf_bin=${READELF_BIN:-readelf}
compiler=${CC:-cc}

for tool in "$compiler" "$lddtree_bin" "$patchelf_bin" "$readelf_bin" cmake; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Linux bundle checker tests require $tool" >&2
    exit 1
  }
done

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
bundle="$test_dir/bundle"
host="$test_dir/host"
mkdir -p "$bundle/lib" "$host"

cat >"$test_dir/leaf.c" <<'EOF'
int leaf_value(void) { return 1; }
EOF
cat >"$test_dir/codec.c" <<'EOF'
extern int leaf_value(void);
int codec_value(void) { return leaf_value(); }
EOF
cat >"$test_dir/mpv.c" <<'EOF'
extern int codec_value(void);
int mpv_value(void) { return codec_value(); }
EOF
cat >"$test_dir/plugin.c" <<'EOF'
extern int mpv_value(void);
int plugin_value(void) { return mpv_value(); }
EOF
cat >"$test_dir/app.c" <<'EOF'
extern int plugin_value(void);
int main(void) { return plugin_value(); }
EOF
cat >"$test_dir/app_without_plugin.c" <<'EOF'
int main(void) { return 0; }
EOF
cat >"$test_dir/host_stack.c" <<'EOF'
extern int codec_value(void);
int stack_value(void) { return codec_value(); }
EOF
cat >"$test_dir/app_with_host_stack.c" <<'EOF'
extern int stack_value(void);
extern int plugin_value(void);
int main(void) { return stack_value() == 7 ? plugin_value() : 99; }
EOF
cat >"$test_dir/host_codec.c" <<'EOF'
int codec_value(void) { return 7; }
EOF
cat >"$test_dir/lookup.c" <<'EOF'
#include <dlfcn.h>
int main(void) {
  void *library = dlopen("libmpv.so", RTLD_NOW);
  if (!library) return 1;
  int (*value)(void) = (int (*)(void))dlsym(library, "mpv_value");
  return !value || value() != 1;
}
EOF

"$compiler" -shared -fPIC -Wl,-soname,libleaf.so.1 -o "$host/libleaf.so.1" "$test_dir/leaf.c"
"$compiler" -shared -fPIC -Wl,-soname,libglib-2.0.so.0 -o "$host/libglib-2.0.so.0" "$test_dir/leaf.c"
"$compiler" -shared -fPIC -Wl,-soname,libcodec.so.1 -L"$host" -Wl,--no-as-needed -l:libleaf.so.1 -o "$host/libcodec.so.1" "$test_dir/codec.c"
"$compiler" -shared -fPIC -Wl,-soname,libmpv.so.1 -L"$host" -Wl,--no-as-needed -l:libcodec.so.1 -o "$host/libmpv.so.1" "$test_dir/mpv.c"
"$patchelf_bin" --set-rpath "$host" "$host/libcodec.so.1"
"$patchelf_bin" --set-rpath "$host" "$host/libmpv.so.1"
"$patchelf_bin" --add-needed libstdc++.so.6 "$host/libmpv.so.1"
"$patchelf_bin" --add-needed libgcc_s.so.1 "$host/libmpv.so.1"
"$patchelf_bin" --add-needed libglib-2.0.so.0 "$host/libmpv.so.1"
"$compiler" -shared -fPIC -Wl,-soname,libmedia_kit_video_plugin.so -Wl,-rpath,"$host" -L"$host" -Wl,--no-as-needed -l:libmpv.so.1 -o "$bundle/lib/libmedia_kit_video_plugin.so" "$test_dir/plugin.c"
"$compiler" -L"$bundle/lib" -Wl,--no-as-needed -l:libmedia_kit_video_plugin.so -o "$bundle/KikoFlu" "$test_dir/app.c"
"$patchelf_bin" --set-rpath '$ORIGIN/lib' "$bundle/KikoFlu"
cp -- "$bundle/lib/libmedia_kit_video_plugin.so" "$test_dir/original-plugin.so"

expect_failure() {
  local expected=$1
  shift
  local output
  if output=$("$@" 2>&1); then
    echo "Expected failure containing '$expected', but command passed." >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "Expected failure containing '$expected', got:" >&2
    echo "$output" >&2
    exit 1
  fi
}

bash "$packer" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin" >/dev/null
bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin" >/dev/null
[[ "$(readlink -- "$bundle/lib/libmpv.so")" == 'libmpv.so.1' ]] || {
  echo "libmpv.so must point to the plugin's libmpv SONAME" >&2
  exit 1
}
for host_runtime in libstdc++.so.6 libgcc_s.so.1 libglib-2.0.so.0; do
  [[ ! -e "$bundle/lib/$host_runtime" ]] || {
    echo "host C++ runtime $host_runtime was copied into the bundle" >&2
    exit 1
  }
done
echo "PASS: packaging copies media dependencies, leaves host runtimes external, and repairs RUNPATHs"

cp -- "$bundle/lib/libmpv.so.1" "$test_dir/packaged-mpv.so.1"
cp -- "$test_dir/original-plugin.so" "$bundle/lib/libmedia_kit_video_plugin.so"
printf 'keep\n' >"$bundle/lib/unrelated.txt"
bash "$packer" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin" >/dev/null
cmp -- "$test_dir/packaged-mpv.so.1" "$bundle/lib/libmpv.so.1"
[[ "$(cat "$bundle/lib/unrelated.txt")" == 'keep' ]]
echo "PASS: repeated packaging repairs the plugin and preserves existing files"

mv "$bundle/lib/libmpv.so" "$test_dir/libmpv-reinstall-link"
expect_failure "bundle already contains" bash "$packer" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
mv "$test_dir/libmpv-reinstall-link" "$bundle/lib/libmpv.so"
echo "PASS: an incomplete existing bundle is not overwritten"

mv "$bundle/lib/libcodec.so.1" "$test_dir/libcodec-reinstall.so.1"
expect_failure "unresolved libmpv dependency libcodec.so.1" bash "$packer" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
mv "$test_dir/libcodec-reinstall.so.1" "$bundle/lib/libcodec.so.1"
echo "PASS: repeated packaging rejects missing transitive dependencies"

"$compiler" -Wl,-rpath,'$ORIGIN/lib' -o "$bundle/lookup" "$test_dir/lookup.c" -ldl
env -u LD_LIBRARY_PATH "$bundle/lookup"
mv "$bundle/lib/libmpv.so" "$test_dir/libmpv.so"
if env -u LD_LIBRARY_PATH "$bundle/lookup"; then
  echo "unversioned dlopen unexpectedly found the bundled test library" >&2
  exit 1
fi
mv "$test_dir/libmpv.so" "$bundle/lib/libmpv.so"
echo "PASS: unversioned dlopen uses the bundled libmpv symlink"

desktop_host="$test_dir/desktop-host"
mkdir -p "$desktop_host"
"$compiler" -shared -fPIC -Wl,-soname,libcodec.so.1 -o "$desktop_host/libcodec.so.1" "$test_dir/host_codec.c"
"$compiler" -shared -fPIC -Wl,-soname,libhost_stack.so -Wl,-rpath,"$desktop_host" -L"$desktop_host" -Wl,--no-as-needed -l:libcodec.so.1 -o "$bundle/lib/libhost_stack.so" "$test_dir/host_stack.c"
mv "$bundle/KikoFlu" "$test_dir/KikoFlu"
"$compiler" -L"$bundle/lib" -Wl,--no-as-needed -l:libhost_stack.so -l:libmedia_kit_video_plugin.so -o "$bundle/KikoFlu" "$test_dir/app_with_host_stack.c"
"$patchelf_bin" --set-rpath '$ORIGIN/lib' "$bundle/KikoFlu"
status=0
env -u LD_LIBRARY_PATH "$bundle/KikoFlu" || status=$?
[[ "$status" == 7 ]] || {
  echo "expected the application to reuse the host's loaded codec, got exit $status" >&2
  exit 1
}
bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin" >/dev/null
mv "$test_dir/KikoFlu" "$bundle/KikoFlu"
rm -- "$bundle/lib/libhost_stack.so"
echo "PASS: a host-loaded library is reused while a bundled fallback remains available"

"$compiler" -o "$bundle/KikoFlu" "$test_dir/app_without_plugin.c"
"$patchelf_bin" --set-rpath '$ORIGIN/lib' "$bundle/KikoFlu"
expect_failure "application does not declare DT_NEEDED libmedia_kit_video_plugin.so" bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
"$compiler" -L"$bundle/lib" -Wl,--no-as-needed -l:libmedia_kit_video_plugin.so -o "$bundle/KikoFlu" "$test_dir/app.c"
"$patchelf_bin" --set-rpath '$ORIGIN/lib' "$bundle/KikoFlu"
echo "PASS: an application without the media player plugin is rejected"

mv "$bundle/lib/libmpv.so.1" "$test_dir/libmpv.so.1"
expect_failure "bundle is missing it" bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
mv "$test_dir/libmpv.so.1" "$bundle/lib/libmpv.so.1"
echo "PASS: missing direct libmpv dependency is rejected"

mv "$bundle/lib/libcodec.so.1" "$test_dir/libcodec.so.1"
expect_failure "unresolved libmpv dependency libcodec.so.1" bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
mv "$test_dir/libcodec.so.1" "$bundle/lib/libcodec.so.1"
echo "PASS: missing transitive dependency is rejected"

"$patchelf_bin" --remove-rpath "$bundle/lib/libcodec.so.1"
expect_failure "libcodec.so.1 RUNPATH must be" bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
"$patchelf_bin" --set-rpath '$ORIGIN' "$bundle/lib/libcodec.so.1"
echo "PASS: non-transitive RUNPATH gap is rejected at the dependent library"

"$patchelf_bin" --add-needed libz.so.1 "$bundle/lib/libmpv.so.1"
expect_failure "unexpected host fallback: libz.so.1 resolved to" bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
"$patchelf_bin" --remove-needed libz.so.1 "$bundle/lib/libmpv.so.1"
echo "PASS: dependency resolving from the host is rejected unless allow-listed"

"$patchelf_bin" --add-needed libEGL_test_missing.so.1 "$bundle/lib/libmpv.so.1"
expect_failure "missing host graphics/display dependency libEGL_test_missing.so.1" bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
"$patchelf_bin" --remove-needed libEGL_test_missing.so.1 "$bundle/lib/libmpv.so.1"
echo "PASS: unavailable host graphics dependencies produce a specific error"

for host_runtime in libstdc++.so.6 libglib-2.0.so.0; do
  : >"$bundle/lib/$host_runtime"
  expect_failure "host runtime library $host_runtime must not be bundled" bash "$checker" "$bundle" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
  rm -- "$bundle/lib/$host_runtime"
done
echo "PASS: host C++ and GLib runtime copies are rejected"

bundle_v2="$test_dir/bundle-v2"
mkdir -p "$bundle_v2/lib"
"$compiler" -shared -fPIC -Wl,-soname,libmpv.so.2 -L"$host" -Wl,--no-as-needed -l:libcodec.so.1 -o "$host/libmpv.so.2" "$test_dir/mpv.c"
"$patchelf_bin" --set-rpath "$host" "$host/libmpv.so.2"
"$patchelf_bin" --add-needed libstdc++.so.6 "$host/libmpv.so.2"
"$patchelf_bin" --add-needed libgcc_s.so.1 "$host/libmpv.so.2"
"$patchelf_bin" --add-needed libglib-2.0.so.0 "$host/libmpv.so.2"
"$compiler" -shared -fPIC -Wl,-soname,libmedia_kit_video_plugin.so -Wl,-rpath,"$host" -L"$host" -Wl,--no-as-needed -l:libmpv.so.2 -o "$bundle_v2/lib/libmedia_kit_video_plugin.so" "$test_dir/plugin.c"
"$compiler" -L"$bundle_v2/lib" -Wl,--no-as-needed -l:libmedia_kit_video_plugin.so -o "$bundle_v2/KikoFlu" "$test_dir/app.c"
"$patchelf_bin" --set-rpath '$ORIGIN/lib' "$bundle_v2/KikoFlu"
bash "$packer" "$bundle_v2" "$lddtree_bin" "$patchelf_bin" "$readelf_bin" >/dev/null
bash "$checker" "$bundle_v2" "$lddtree_bin" "$patchelf_bin" "$readelf_bin" >/dev/null
[[ "$(readlink -- "$bundle_v2/lib/libmpv.so")" == 'libmpv.so.2' ]] || {
  echo "libmpv.so must point to libmpv.so.2 when the plugin declares that SONAME" >&2
  exit 1
}
cp "$bundle/lookup" "$bundle_v2/lookup"
env -u LD_LIBRARY_PATH "$bundle_v2/lookup"
echo "PASS: libmpv.so.2 and the versionless FFI symlink are supported"

# Exercise the real CMake install hooks without configuring Flutter.
cmake_source="$test_dir/cmake-source"
cmake_build="$test_dir/cmake-build"
prefix="$test_dir/install-prefix"
destdir="$test_dir/stage"
mkdir -p "$cmake_source"
cat >"$cmake_source/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.13)
project(bundle_install_test NONE)
set(BUILD_BUNDLE_DIR "${CMAKE_CURRENT_BINARY_DIR}/bundle")
set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(LDDTREE_EXECUTABLE unused)
set(PATCHELF_EXECUTABLE unused)
set(READELF_EXECUTABLE unused)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/installed.txt" "fixture")
EOF
awk '
  /^# Start with a clean build bundle directory/ { capture = 1 }
  /^set\(INSTALL_BUNDLE_DATA_DIR/ { capture = 0 }
  capture { print }
' "$script_dir/CMakeLists.txt" >>"$cmake_source/CMakeLists.txt"
cat >>"$cmake_source/CMakeLists.txt" <<'EOF'
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/installed.txt"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" COMPONENT Runtime)
EOF
awk '
  /^# Fully re-copy the assets directory/ { capture = 1 }
  /^install\(DIRECTORY "\$\{PROJECT_BUILD_DIR\}\/\$\{FLUTTER_ASSET_DIR_NAME\}"/ { capture = 0 }
  /^# Copy libmpv.s runtime closure/ { capture = 1 }
  capture { print }
' "$script_dir/CMakeLists.txt" >>"$cmake_source/CMakeLists.txt"
cat >"$cmake_source/package_linux_libmpv.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -f "$1/lib/installed.txt" ]]
printf '%s\n' "$1" >"$CAPTURE_FILE"
EOF
env -u DESTDIR cmake -S "$cmake_source" -B "$cmake_build" -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
mkdir -p "$prefix/data/flutter_assets" "$destdir$prefix/data/flutter_assets" "$cmake_build/bundle"
printf 'live\n' >"$prefix/data/flutter_assets/keep"
printf 'stale\n' >"$destdir$prefix/data/flutter_assets/stale"
printf 'build\n' >"$cmake_build/bundle/keep"
DESTDIR="$destdir" CAPTURE_FILE="$test_dir/install-path" cmake --install "$cmake_build" >/dev/null
[[ "$(cat "$test_dir/install-path")" == "$destdir$prefix" ]]
[[ -f "$prefix/data/flutter_assets/keep" && -f "$cmake_build/bundle/keep" ]]
[[ ! -e "$destdir$prefix/data/flutter_assets/stale" ]]
env -u DESTDIR CAPTURE_FILE="$test_dir/install-path" cmake --install "$cmake_build" >/dev/null
[[ "$(cat "$test_dir/install-path")" == "$prefix" ]]
echo "PASS: CMake installs into DESTDIR without touching the live prefix or build bundle"

default_build="$test_dir/cmake-default-build"
default_prefix="$default_build/bundle"
env -u DESTDIR cmake -S "$cmake_source" -B "$default_build" -DCMAKE_INSTALL_PREFIX="$default_prefix" >/dev/null
mkdir -p "$default_prefix" "$destdir$default_prefix"
printf 'build\n' >"$default_prefix/keep"
printf 'stale\n' >"$destdir$default_prefix/stale"
DESTDIR="$destdir" CAPTURE_FILE="$test_dir/install-path" cmake --install "$default_build" >/dev/null
[[ -f "$default_prefix/keep" && ! -e "$destdir$default_prefix/stale" ]]
[[ "$(cat "$test_dir/install-path")" == "$destdir$default_prefix" ]]
echo "PASS: default bundle cleanup also respects DESTDIR"
