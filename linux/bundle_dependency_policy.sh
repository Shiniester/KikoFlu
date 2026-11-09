#!/usr/bin/env bash

linux_bundle_is_glibc_host_library() {
  case "$1" in
    ld-linux*.so*|libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*|libresolv.so*|libutil.so*|libanl.so*|libnss_*.so*|libthread_db.so*|libBrokenLocale.so*|libpcprofile.so*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

linux_bundle_is_cpp_host_library() {
  case "$1" in
    libstdc++.so*|libgcc_s.so*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

linux_bundle_is_graphics_host_library() {
  # Keep the GTK ABI and display/GPU driver stack with the host. Audio clients,
  # video codecs, and media libraries are bundled because they are not drivers.
  case "$1" in
    libEGL*.so*|libGL*.so*|libGLES*.so*|libgbm.so*|libdrm*.so*|libX*.so*|libxcb*.so*|libwayland*.so*|libxkbcommon*.so*|libgtk*.so*|libgdk*.so*|libatk*.so*|libpango*.so*|libcairo*.so*|libepoxy*.so*|libwebkit*.so*|libjavascriptcore*.so*|libsoup*.so*|libglib-2.0.so*|libgobject-2.0.so*|libgio-2.0.so*|libgmodule-2.0.so*|libgthread-2.0.so*|libharfbuzz*.so*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

linux_bundle_lddtree_flat_paths() {
  local lddtree_bin=$1
  local elf=$2
  local output

  if ! output=$(env -u LD_LIBRARY_PATH "$lddtree_bin" -l "$elf"); then
    return 1
  fi
  printf '%s\n' "$output"
}

linux_bundle_index_flat_paths() {
  local flat_paths=$1
  local map_name=$2
  local -n paths=$map_name
  local path
  local soname

  # Keep lddtree's first actual resolution. Package candidates are looked up
  # separately so a bundled copy cannot mask a host path in this table.
  while IFS= read -r path; do
    [[ "$path" == /* && -e "$path" ]] || continue
    soname=${path##*/}
    [[ -n "${paths[$soname]+present}" ]] || paths[$soname]=$path
  done <<< "$flat_paths"
}

linux_bundle_resolve_flat_path() {
  local soname=$1
  local map_name=$2
  local -n paths=$map_name

  [[ -n "${paths[$soname]+present}" ]] || return 1
  printf '%s\n' "${paths[$soname]}"
}

linux_bundle_resolve_bundle_candidate() {
  local soname=$1
  local lib_dir=$2

  [[ -e "$lib_dir/$soname" ]] || return 1
  printf '%s\n' "$lib_dir/$soname"
}

linux_bundle_find_mpv_soname() {
  local needed_list=$1
  local soname
  local found=

  while IFS= read -r soname; do
    case "$soname" in
      libmpv.so.1|libmpv.so.2)
        [[ -z "$found" ]] || return 1
        found=$soname
        ;;
    esac
  done <<< "$needed_list"

  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}
