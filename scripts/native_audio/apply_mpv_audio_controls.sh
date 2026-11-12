#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
    printf 'mpv audio controls patch: %s\n' "$1" >&2
    exit 1
}

absolute_patch_file() {
    local patch_file=$1
    local patch_dir

    patch_dir=$(cd -- "$(dirname -- "$patch_file")" && pwd) ||
        fail "patch file is missing: $patch_file"
    [[ -f "$patch_dir/$(basename -- "$patch_file")" ]] ||
        fail "patch file is missing: $patch_file"
    printf '%s/%s\n' "$patch_dir" "$(basename -- "$patch_file")"
}

check_patch() {
    local patch_file=$1
    local source_root=${2:-}
    local patch_stat

    [[ -s "$patch_file" ]] || fail "patch file is missing: $patch_file"
    if [[ -z "$source_root" ]]; then
        source_root=$(git -C "$script_dir" rev-parse --show-toplevel) ||
            fail 'cannot locate repository root for patch validation'
    fi
    patch_stat=$(git -C "$source_root" apply --numstat "$patch_file") ||
        fail "patch format is invalid: $patch_file"
    [[ "$patch_stat" == $'110\t1\tfilters/f_lavfi.c' ]] ||
        fail "patch must update filters/f_lavfi.c only"
}

verify_applied() {
    local source_dir=$1
    local expected_commit=$2
    local source_file="$source_dir/filters/f_lavfi.c"
    local actual_commit
    local changed_stat
    local configure_line
    local replay_line
    local initialized_line
    local cache_line
    local cache_predecessor
    local replay_failure_block

    actual_commit=$(git -C "$source_dir" rev-parse HEAD) ||
        fail "mpv source is missing: $source_dir"
    [[ "$actual_commit" == "$expected_commit" ]] ||
        fail "mpv source is $actual_commit, expected $expected_commit"
    [[ "$(git -C "$source_dir" diff --name-only -- filters/f_lavfi.c)" == 'filters/f_lavfi.c' ]] ||
        fail 'patch did not change filters/f_lavfi.c'
    changed_stat=$(git -C "$source_dir" diff --numstat -- filters/f_lavfi.c)
    [[ "$changed_stat" == $'110\t1\tfilters/f_lavfi.c' ]] ||
        fail 'filters/f_lavfi.c changes differ from the expected cache patch'

    grep -Fq 'lavfi_command_target_has_index(target, "equalizer@eq_band")' "$source_file" ||
        fail 'equalizer targets are not limited to named bands'
    grep -Fq 'lavfi_command_target_has_index(target, "eq_band")' "$source_file" ||
        fail 'bare equalizer band aliases are not supported'
    grep -Fq 'strcmp(cmd, "g") == 0 || strcmp(cmd, "enable") == 0' "$source_file" ||
        fail 'equalizer command allowlist changed'
    for target in channel_mode guard_mix scene_amount mono_amount stereo_amount; do
        grep -Fqx "        \"$target\"," "$source_file" ||
            fail "volume target $target is missing from the allowlist"
    done
    grep -Fq 'strcmp(cmd, "volume") == 0' "$source_file" ||
        fail 'volume command allowlist changed'
    grep -Fq 'strtod(arg, &end)' "$source_file" ||
        fail 'command arguments are not parsed as numeric literals'
    grep -Fq "*end == '\0' && isfinite(value)" "$source_file" ||
        fail 'command arguments must be fully consumed finite numbers'
    grep -Fq 'strcmp(entry->target, cmd->target) == 0' "$source_file" ||
        fail 'cache key does not include the command target'
    grep -Fq 'strcmp(entry->cmd, cmd->cmd) == 0' "$source_file" ||
        fail 'cache key does not include the command name'
    grep -Fq 'talloc_free(entry->arg);' "$source_file" ||
        fail 'cache updates do not replace the owned argument'
    grep -Fq 'entry->arg = arg;' "$source_file" ||
        fail 'cache updates do not retain the latest argument'
    grep -Fq 'talloc_zero(c, struct lavfi_command_cache)' "$source_file" ||
        fail 'command cache entries must be owned by the lavfi filter'
    grep -Fq 'avfilter_graph_send_command(c->graph, entry->target, entry->cmd,' "$source_file" ||
        fail 'cached commands are not replayed to their exact target'

    configure_line=$(grep -Fn 'if (avfilter_graph_config(c->graph, NULL) < 0)' "$source_file" | cut -d: -f1)
    replay_line=$(grep -Fn 'if (!replay_lavfi_commands(c))' "$source_file" | cut -d: -f1)
    initialized_line=$(grep -Fn 'c->initialized = true;' "$source_file" | cut -d: -f1)
    [[ -n "$configure_line" && -n "$replay_line" && -n "$initialized_line" ]] ||
        fail 'graph command replay or initialization point is missing'
    [[ "$configure_line" -lt "$replay_line" && "$replay_line" -lt "$initialized_line" ]] ||
        fail 'cached commands must replay after graph configuration and before initialization'
    replay_failure_block=$(sed -n "${replay_line},$((replay_line + 5))p" "$source_file")
    for required in 'free_graph(c);' 'c->failed = true;' 'return;'; do
        grep -Fq "$required" <<<"$replay_failure_block" ||
            fail 'failed command replay must use graph initialization failure cleanup'
    done

    cache_line=$(grep -Fn 'cache_lavfi_command(c, cmd);' "$source_file" | cut -d: -f1)
    [[ -n "$cache_line" ]] || fail 'successful commands are not cached'
    cache_predecessor=$(sed -n "$((cache_line - 1))p" "$source_file")
    [[ "$cache_predecessor" == *'>= 0 &&'* ]] ||
        fail 'failed commands can enter the replay cache'

    if sed -n '/^static void free_graph/,/^static void add_pad/p' "$source_file" |
        grep -Fq 'command_cache'; then
        fail 'graph reset must retain the per-filter command cache'
    fi

}

case ${1:-} in
    --check-patch)
        [[ $# == 2 ]] || fail 'usage: apply_mpv_audio_controls.sh --check-patch <patch>'
        check_patch "$(absolute_patch_file "$2")"
        ;;
    --apply)
        [[ $# == 4 ]] ||
            fail 'usage: apply_mpv_audio_controls.sh --apply <mpv-source> <mpv-commit> <patch>'
        source_dir=$2
        expected_commit=$3
        patch_file=$(absolute_patch_file "$4")
        check_patch "$patch_file" "$source_dir"
        actual_commit=$(git -C "$source_dir" rev-parse HEAD) ||
            fail "mpv source is missing: $source_dir"
        [[ "$actual_commit" == "$expected_commit" ]] ||
            fail "mpv source is $actual_commit, expected $expected_commit"
        [[ -z "$(git -C "$source_dir" diff --numstat -- filters/f_lavfi.c)" ]] ||
            fail 'filters/f_lavfi.c already has local changes'
        git -C "$source_dir" apply --check "$patch_file" ||
            fail 'patch does not apply to pinned mpv source'
        git -C "$source_dir" apply "$patch_file" ||
            fail 'patch application failed'
        verify_applied "$source_dir" "$expected_commit"
        ;;
    *)
        fail 'expected --check-patch or --apply'
        ;;
esac
