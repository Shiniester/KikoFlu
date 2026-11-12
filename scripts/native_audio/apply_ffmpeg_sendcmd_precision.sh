#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'FFmpeg sendcmd precision patch: %s\n' "$1" >&2
    exit 1
}

check_patch() {
    local patch_file=$1
    local patch_stat
    local patch_repo_root
    local deleted_line
    local added_line

    [[ -s "$patch_file" ]] || fail "patch file is missing: $patch_file"
    patch_repo_root=$(git -C "$(dirname -- "$patch_file")" rev-parse --show-toplevel) ||
        fail "patch is not in a Git checkout: $patch_file"
    patch_stat=$(git -C "$patch_repo_root" apply --numstat "$patch_file") ||
        fail "patch format is invalid: $patch_file"
    [[ "$patch_stat" == $'1\t1\tlibavfilter/f_sendcmd.c' ]] ||
        fail 'patch must replace one line in libavfilter/f_sendcmd.c only'
    deleted_line=$(grep -E '^-[^-].*cmd_arg = av_asprintf' "$patch_file" || true)
    added_line=$(grep -E '^\+[^+].*cmd_arg = av_asprintf' "$patch_file" || true)
    [[ "$deleted_line" == '-                        cmd_arg = av_asprintf("%g", res);' ]] ||
        fail 'patch does not replace the six-digit format'
    [[ "$added_line" == '+                        cmd_arg = av_asprintf("%.17g", res);' ]] ||
        fail 'patch does not preserve double precision'
}

verify_applied() {
    local source_dir=$1
    local expected_source_commit=$2
    local actual_commit
    local changed_stat
    local deleted_line
    local added_line
    local source_file="$source_dir/libavfilter/f_sendcmd.c"

    actual_commit=$(git -C "$source_dir" rev-parse HEAD) || fail "FFmpeg source is missing: $source_dir"
    [[ "$actual_commit" == "$expected_source_commit" ]] ||
        fail "FFmpeg source is $actual_commit, expected $expected_source_commit"
    [[ "$(git -C "$source_dir" diff --name-only -- libavfilter/f_sendcmd.c)" == 'libavfilter/f_sendcmd.c' ]] ||
        fail 'precision patch did not change libavfilter/f_sendcmd.c'
    changed_stat=$(git -C "$source_dir" diff --numstat -- libavfilter/f_sendcmd.c)
    [[ "$changed_stat" == $'1\t1\tlibavfilter/f_sendcmd.c' ]] ||
        fail 'precision patch changes are not exactly one replacement'
    deleted_line=$(git -C "$source_dir" diff --unified=0 -- libavfilter/f_sendcmd.c | grep -E '^-[^-].*cmd_arg = av_asprintf' || true)
    added_line=$(git -C "$source_dir" diff --unified=0 -- libavfilter/f_sendcmd.c | grep -E '^\+[^+].*cmd_arg = av_asprintf' || true)
    [[ "$deleted_line" == '-                        cmd_arg = av_asprintf("%g", res);' ]] ||
        fail 'applied patch did not replace the six-digit format'
    [[ "$added_line" == '+                        cmd_arg = av_asprintf("%.17g", res);' ]] ||
        fail 'applied patch does not preserve double precision'
    [[ "$(grep -Fc 'cmd_arg = av_asprintf("%.17g", res);' "$source_file")" == 1 ]] ||
        fail 'the FFmpeg source does not contain exactly one %.17g sendcmd formatter'
    if grep -Fq 'cmd_arg = av_asprintf("%g", res);' "$source_file"; then
        fail 'the six-digit sendcmd formatter remains in the FFmpeg source'
    fi
}

case ${1:-} in
    --check-patch)
        [[ $# == 2 ]] || fail 'usage: apply_ffmpeg_sendcmd_precision.sh --check-patch <patch>'
        check_patch "$2"
        ;;
    --apply)
        [[ $# == 4 ]] || fail 'usage: apply_ffmpeg_sendcmd_precision.sh --apply <ffmpeg-source> <ffmpeg-commit> <patch>'
        source_dir=$2
        expected_source_commit=$3
        patch_file=$4
        check_patch "$patch_file"
        actual_commit=$(git -C "$source_dir" rev-parse HEAD) || fail "FFmpeg source is missing: $source_dir"
        [[ "$actual_commit" == "$expected_source_commit" ]] ||
            fail "FFmpeg source is $actual_commit, expected $expected_source_commit"
        [[ -z "$(git -C "$source_dir" diff --numstat -- libavfilter/f_sendcmd.c)" ]] ||
            fail 'libavfilter/f_sendcmd.c already has local changes'
        [[ "$(grep -Fc 'cmd_arg = av_asprintf("%g", res);' "$source_dir/libavfilter/f_sendcmd.c")" == 1 ]] ||
            fail 'the pinned FFmpeg source does not contain exactly one six-digit sendcmd formatter'
        git -C "$source_dir" apply --check "$patch_file" || fail 'precision patch does not apply to pinned FFmpeg source'
        git -C "$source_dir" apply "$patch_file" || fail 'precision patch application failed'
        verify_applied "$source_dir" "$expected_source_commit"
        ;;
    --verify)
        [[ $# == 4 ]] || fail 'usage: apply_ffmpeg_sendcmd_precision.sh --verify <ffmpeg-source> <ffmpeg-commit> <patch>'
        check_patch "$4"
        verify_applied "$2" "$3"
        ;;
    *)
        fail 'expected --check-patch, --apply, or --verify'
        ;;
esac
