#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 4 ]]; then
  echo "Usage: $0 <bundle-directory> [lddtree] [patchelf] [readelf]" >&2
  exit 2
fi

bundle_dir=${1%/}
lddtree_bin=${2:-lddtree}
patchelf_bin=${3:-patchelf}
readelf_bin=${4:-readelf}
script_dir=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_dir/bundle_dependency_policy.sh"

fail() {
  echo "Linux bundle check failed: $*" >&2
  exit 1
}

[[ -d "$bundle_dir" ]] || fail "bundle directory does not exist: $bundle_dir"
bundle_dir=$(cd -- "$bundle_dir" && pwd -P)
lib_dir="$bundle_dir/lib"
app="$bundle_dir/KikoFlu"
plugin="$lib_dir/libmedia_kit_video_plugin.so"
[[ -f "$app" ]] || fail "bundle executable is missing: $app"
[[ -f "$plugin" ]] || fail "media_kit_video plugin is missing: $plugin"
command -v "$lddtree_bin" >/dev/null 2>&1 || fail "lddtree is required (Ubuntu package: pax-utils)"
command -v "$patchelf_bin" >/dev/null 2>&1 || fail "patchelf is required (Ubuntu package: patchelf)"
command -v "$readelf_bin" >/dev/null 2>&1 || fail "readelf is required (Ubuntu package: binutils)"

assert_runpath() {
  local file=$1
  local expected=$2
  local dynamic
  local runpath

  dynamic=$("$readelf_bin" -d "$file") || fail "cannot read dynamic section from $file"
  if grep -Fq '(RPATH)' <<<"$dynamic"; then
    fail "${file##*/} must use non-transitive DT_RUNPATH, not DT_RPATH"
  fi
  runpath=$("$patchelf_bin" --print-rpath "$file") || fail "cannot read RUNPATH from $file"
  [[ "$runpath" == "$expected" ]] || fail "${file##*/} RUNPATH must be $expected, found: ${runpath:-<empty>}"
  grep -Fq '(RUNPATH)' <<<"$dynamic" || fail "${file##*/} must use DT_RUNPATH"
}

assert_runpath "$plugin" '$ORIGIN'
assert_runpath "$app" '$ORIGIN/lib'

plugin_needed=$("$patchelf_bin" --print-needed "$plugin") || fail "cannot read DT_NEEDED from $plugin"
mpv_soname=$(linux_bundle_find_mpv_soname "$plugin_needed") || fail "media_kit_video plugin must declare exactly one supported libmpv dependency (libmpv.so.1 or libmpv.so.2)"
mpv="$lib_dir/$mpv_soname"
[[ -f "$mpv" ]] || fail "media_kit_video requires $mpv_soname, but the bundle is missing it"
assert_runpath "$mpv" '$ORIGIN'

for bundled_library in "$lib_dir"/*.so*; do
  [[ -e "$bundled_library" ]] || continue
  bundled_soname=${bundled_library##*/}
  if linux_bundle_is_glibc_host_library "$bundled_soname" || linux_bundle_is_cpp_host_library "$bundled_soname" || linux_bundle_is_graphics_host_library "$bundled_soname"; then
    fail "host runtime library $bundled_soname must not be bundled"
  fi
done

if [[ ! -L "$lib_dir/libmpv.so" || "$(readlink -- "$lib_dir/libmpv.so")" != "$mpv_soname" ]]; then
  fail "libmpv.so must be a relative symlink to $mpv_soname"
fi
app_needed=$("$patchelf_bin" --print-needed "$app") || fail "cannot read DT_NEEDED from $app"
grep -Fxq 'libmedia_kit_video_plugin.so' <<<"$app_needed" || fail "application does not declare DT_NEEDED libmedia_kit_video_plugin.so"

app_flat=$(linux_bundle_lddtree_flat_paths "$lddtree_bin" "$app") || fail "lddtree could not inspect $app"
declare -A app_paths=()
linux_bundle_index_flat_paths "$app_flat" app_paths || fail "cannot index application dependencies"
app_plugin_path=$(linux_bundle_resolve_flat_path 'libmedia_kit_video_plugin.so' app_paths) || fail "application does not resolve the media_kit_video plugin"
[[ "$app_plugin_path" == "$plugin" ]] || fail "application resolves the media_kit_video plugin outside the bundle"
while IFS= read -r soname; do
  [[ -n "$soname" ]] || continue
  dependency=$(linux_bundle_resolve_flat_path "$soname" app_paths) || {
    if linux_bundle_is_graphics_host_library "$soname"; then
      fail "missing host graphics/display dependency $soname; install the system GTK and display stack"
    fi
    if linux_bundle_is_glibc_host_library "$soname"; then
      fail "missing host glibc dependency $soname"
    fi
    if linux_bundle_is_cpp_host_library "$soname"; then
      fail "missing host C++ runtime dependency $soname; install libstdc++6"
    fi
    fail "unresolved application dependency $soname"
  }
done <<< "$app_needed"

plugin_mpv_path=$(linux_bundle_resolve_flat_path "$mpv_soname" app_paths) || fail "unresolved plugin dependency $mpv_soname"
[[ "$plugin_mpv_path" == "$mpv" ]] || fail "plugin resolves libmpv outside the bundle; refusing a host-library fallback"
while IFS= read -r soname; do
  [[ -n "$soname" ]] || continue
  dependency=$(linux_bundle_resolve_flat_path "$soname" app_paths) || {
    if linux_bundle_is_graphics_host_library "$soname"; then
      fail "missing host graphics/display dependency $soname; install the system GTK and display stack"
    fi
    if linux_bundle_is_glibc_host_library "$soname"; then
      fail "missing host glibc dependency $soname"
    fi
    if linux_bundle_is_cpp_host_library "$soname"; then
      fail "missing host C++ runtime dependency $soname; install libstdc++6"
    fi
    fail "unresolved plugin dependency $soname; install the matching Linux runtime library"
  }
done <<< "$plugin_needed"

# Check libmpv's non-host closure as a direct dependency graph. A flat
# `lddtree -l` result is indexed once; each ELF's DT_NEEDED entries are then
# visited once, without expanding duplicate dependency subtrees.
queue=("$mpv")
queue_index=0
declare -A visited=()

while ((queue_index < ${#queue[@]})); do
  current=${queue[$queue_index]}
  ((queue_index += 1))
  current_real=$(readlink -f -- "$current") || fail "cannot resolve bundled library path: $current"
  [[ -n "${visited[$current_real]+present}" ]] && continue
  visited[$current_real]=1

  current_needed=$("$patchelf_bin" --print-needed "$current") || fail "cannot read DT_NEEDED from $current"
  while IFS= read -r soname; do
    [[ -n "$soname" ]] || continue
    if linux_bundle_is_glibc_host_library "$soname"; then
      dependency=$(linux_bundle_resolve_flat_path "$soname" app_paths) || fail "missing host glibc dependency $soname"
      continue
    fi
    if linux_bundle_is_cpp_host_library "$soname"; then
      dependency=$(linux_bundle_resolve_flat_path "$soname" app_paths) || fail "missing host C++ runtime dependency $soname; install libstdc++6"
      continue
    fi
    if linux_bundle_is_graphics_host_library "$soname"; then
      dependency=$(linux_bundle_resolve_flat_path "$soname" app_paths) || fail "missing host graphics/display dependency $soname; install the system GTK and display stack"
      continue
    fi

    bundle_candidate=$(linux_bundle_resolve_bundle_candidate "$soname" "$lib_dir" || true)
    if [[ -n "$bundle_candidate" ]]; then
      assert_runpath "$bundle_candidate" '$ORIGIN'
      queue+=("$bundle_candidate")
      continue
    fi

    dependency=$(linux_bundle_resolve_flat_path "$soname" app_paths) || fail "unresolved libmpv dependency $soname"
    case "$dependency" in
      "$lib_dir"/*)
        fail "unresolved libmpv bundle dependency $soname"
        ;;
      *)
        fail "unexpected host fallback: $soname resolved to $dependency but must be bundled"
        ;;
    esac
  done <<< "$current_needed"
done

echo "Linux bundle check passed: the app resolves the bundled player plugin and libmpv; bundle copies have relocatable RUNPATHs and declared dependencies resolve."
