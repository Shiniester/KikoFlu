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
checker="$(dirname "${BASH_SOURCE[0]}")/check_linux_bundle.sh"
script_dir=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_dir/bundle_dependency_policy.sh"

fail() {
  echo "Linux libmpv packaging failed: $*" >&2
  exit 1
}

[[ -d "$bundle_dir/lib" ]] || fail "bundle library directory does not exist: $bundle_dir/lib"
bundle_dir=$(cd -- "$bundle_dir" && pwd -P)
lib_dir="$bundle_dir/lib"
plugin="$lib_dir/libmedia_kit_video_plugin.so"
[[ -f "$plugin" ]] || fail "media_kit_video plugin is missing: $plugin"
command -v "$lddtree_bin" >/dev/null 2>&1 || fail "lddtree is required (Ubuntu package: pax-utils)"
command -v "$patchelf_bin" >/dev/null 2>&1 || fail "patchelf is required (Ubuntu package: patchelf)"
command -v "$readelf_bin" >/dev/null 2>&1 || fail "readelf is required (Ubuntu package: binutils)"

plugin_needed=$("$patchelf_bin" --print-needed "$plugin") || fail "cannot read DT_NEEDED from $plugin"
mpv_soname=$(linux_bundle_find_mpv_soname "$plugin_needed") || fail "media_kit_video plugin must declare exactly one supported libmpv dependency (libmpv.so.1 or libmpv.so.2)"

if [[ -f "$lib_dir/$mpv_soname" && ! -L "$lib_dir/$mpv_soname" &&
      -L "$lib_dir/libmpv.so" && "$(readlink -- "$lib_dir/libmpv.so")" == "$mpv_soname" ]]; then
  # shortcut: repeat installs reuse libmpv; use a clean prefix to refresh it.
  "$patchelf_bin" --set-rpath '$ORIGIN' "$plugin" || fail "cannot set relocatable RUNPATH on media_kit_video plugin"
  exec bash "$checker" "$bundle_dir" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
fi

plugin_flat=$(linux_bundle_lddtree_flat_paths "$lddtree_bin" "$plugin") || fail "lddtree could not inspect $plugin"
declare -A plugin_paths=()
linux_bundle_index_flat_paths "$plugin_flat" plugin_paths || fail "cannot index dependencies of $plugin"
mpv_source=$(linux_bundle_resolve_flat_path "$mpv_soname" plugin_paths) || fail "$mpv_soname is not available; install the matching libmpv runtime (or libmpv-dev for a build)"
[[ -f "$mpv_source" ]] || fail "$mpv_soname is not available; install the matching libmpv runtime (or libmpv-dev for a build)"

for existing_mpv in libmpv.so libmpv.so.1 libmpv.so.2; do
  [[ ! -e "$lib_dir/$existing_mpv" && ! -L "$lib_dir/$existing_mpv" ]] || fail "bundle already contains $existing_mpv; refusing to overwrite an existing library"
done

stage_dir=$(mktemp -d)
trap 'rm -rf -- "$stage_dir"' EXIT
mkdir -p "$stage_dir/lib"
cp -L -- "$mpv_source" "$stage_dir/lib/$mpv_soname"
"$patchelf_bin" --set-rpath '$ORIGIN' "$stage_dir/lib/$mpv_soname" || fail "cannot set relocatable RUNPATH on $mpv_soname"

mpv_source_real=$(readlink -f -- "$mpv_source") || fail "cannot resolve source path for $mpv_soname"
declare -A staged_sources=()
staged_sources["$mpv_soname"]=$mpv_source_real
declare -A visited=()
queue=("$mpv_source")
queue_index=0

while ((queue_index < ${#queue[@]})); do
  current=${queue[$queue_index]}
  ((queue_index += 1))
  current_real=$(readlink -f -- "$current") || fail "cannot resolve source path for ${current##*/}"
  [[ -n "${visited[$current_real]+present}" ]] && continue
  visited[$current_real]=1

  needed_list=$("$patchelf_bin" --print-needed "$current") || fail "cannot read DT_NEEDED from $current"
  while IFS= read -r soname; do
    [[ -n "$soname" ]] || continue
    linux_bundle_is_glibc_host_library "$soname" && continue

    if linux_bundle_is_cpp_host_library "$soname"; then
      linux_bundle_resolve_flat_path "$soname" plugin_paths >/dev/null || fail "missing host C++ runtime dependency $soname"
      continue
    fi

    dependency_source=$(linux_bundle_resolve_flat_path "$soname" plugin_paths) || {
      if linux_bundle_is_graphics_host_library "$soname"; then
        fail "host graphics/display dependency $soname is unavailable; install the system GTK and display stack"
      fi
      fail "unresolved libmpv dependency $soname"
    }
    if linux_bundle_is_graphics_host_library "$soname"; then
      continue
    fi
    [[ -f "$dependency_source" ]] || fail "unresolved libmpv dependency $soname"

    dependency_source_real=$(readlink -f -- "$dependency_source") || fail "cannot resolve source path for $soname"
    if [[ -n "${staged_sources[$soname]+present}" ]]; then
      if [[ "$dependency_source_real" == "${staged_sources[$soname]}" ]]; then
        continue
      fi
      fail "libmpv dependency graph resolves $soname to more than one binary"
    fi
    if [[ -e "$lib_dir/$soname" ]]; then
      fail "bundle already contains $soname; refusing to overwrite an existing library"
    fi

    staged_sources[$soname]=$dependency_source_real
    staged_library="$stage_dir/lib/$soname"
    cp -- "$dependency_source_real" "$staged_library"
    "$patchelf_bin" --set-rpath '$ORIGIN' "$staged_library" || fail "cannot set relocatable RUNPATH on $soname"
    queue+=("$dependency_source")
  done <<< "$needed_list"
done

cp -- "$stage_dir"/lib/* "$lib_dir/"
ln -s -- "$mpv_soname" "$lib_dir/libmpv.so"
"$patchelf_bin" --set-rpath '$ORIGIN' "$plugin" || fail "cannot set relocatable RUNPATH on media_kit_video plugin"

bash "$checker" "$bundle_dir" "$lddtree_bin" "$patchelf_bin" "$readelf_bin"
