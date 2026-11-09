#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'mpv audio reinit patch: %s\n' "$1" >&2
    exit 1
}

check_patch() {
    local patch_file=$1
    local expected_patch_commit=$2
    local patch_stat
    local patch_repo_root
    local deleted_lines
    local expected_deleted_lines

    [[ -s "$patch_file" ]] || fail "patch file is missing: $patch_file"
    grep -Fqx "From $expected_patch_commit Mon Sep 17 00:00:00 2001" "$patch_file" ||
        fail "patch does not identify upstream commit $expected_patch_commit"
    patch_repo_root=$(git -C "$(dirname -- "$patch_file")" rev-parse --show-toplevel) ||
        fail "patch is not in a Git checkout: $patch_file"
    patch_stat=$(git -C "$patch_repo_root" apply --numstat "$patch_file") ||
        fail "patch format is invalid: $patch_file"
    [[ "$patch_stat" == $'0\t5\tplayer/audio.c' ]] ||
        fail "patch must delete five lines from player/audio.c only"

    deleted_lines=$(grep -E '^-[^-]' "$patch_file" || true)
    expected_deleted_lines=$'-    // Wait until all played.\n-    if (mpctx->ao && ao_is_playing(mpctx->ao)) {\n-        talloc_free(out_fmt);\n-        return 0;\n-    }'
    [[ "$deleted_lines" == "$expected_deleted_lines" ]] ||
        fail "patch does not remove only the ao_is_playing early return"
}

verify_applied() {
    local source_dir=$1
    local expected_source_commit=$2
    local actual_commit
    local changed_stat
    local deleted_lines
    local expected_deleted_lines

    actual_commit=$(git -C "$source_dir" rev-parse HEAD) || fail "mpv source is missing: $source_dir"
    [[ "$actual_commit" == "$expected_source_commit" ]] ||
        fail "mpv source is $actual_commit, expected $expected_source_commit"
    [[ "$(git -C "$source_dir" diff --name-only -- player/audio.c)" == 'player/audio.c' ]] ||
        fail 'patch did not change player/audio.c'
    changed_stat=$(git -C "$source_dir" diff --numstat -- player/audio.c)
    [[ "$changed_stat" == $'0\t5\tplayer/audio.c' ]] ||
        fail "patch changes to player/audio.c are not exactly five deletions"

    deleted_lines=$(git -C "$source_dir" diff --unified=0 -- player/audio.c | grep -E '^-[^-]' || true)
    expected_deleted_lines=$'-    // Wait until all played.\n-    if (mpctx->ao && ao_is_playing(mpctx->ao)) {\n-        talloc_free(out_fmt);\n-        return 0;\n-    }'
    [[ "$deleted_lines" == "$expected_deleted_lines" ]] ||
        fail "applied change does not remove only the ao_is_playing early return"
    if grep -Fq 'if (mpctx->ao && ao_is_playing(mpctx->ao))' "$source_dir/player/audio.c"; then
        fail "ao_is_playing early return remains in player/audio.c"
    fi
}

case ${1:-} in
    --check-patch)
        [[ $# == 3 ]] || fail 'usage: apply_mpv_audio_reinit.sh --check-patch <patch> <upstream-commit>'
        check_patch "$2" "$3"
        ;;
    --apply)
        [[ $# == 5 ]] || fail 'usage: apply_mpv_audio_reinit.sh --apply <mpv-source> <mpv-commit> <patch> <upstream-commit>'
        source_dir=$2
        expected_source_commit=$3
        patch_file=$4
        expected_patch_commit=$5
        check_patch "$patch_file" "$expected_patch_commit"
        [[ -z "$(git -C "$source_dir" diff --numstat -- player/audio.c)" ]] ||
            fail 'player/audio.c already has local changes'
        git -C "$source_dir" apply --check "$patch_file" || fail 'patch does not apply to pinned mpv source'
        git -C "$source_dir" apply "$patch_file" || fail 'patch application failed'
        verify_applied "$source_dir" "$expected_source_commit"
        ;;
    *)
        fail 'expected --check-patch or --apply'
        ;;
esac
