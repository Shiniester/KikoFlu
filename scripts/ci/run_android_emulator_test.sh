#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$2" != "--" ]; then
  echo "Usage: run_android_emulator_test.sh OUTPUT_DIR -- COMMAND [ARG...]" >&2
  exit 2
fi

output_dir=$1
shift 2
if [ "$#" -eq 0 ]; then
  echo 'COMMAND is required.' >&2
  exit 2
fi

mkdir -p "$output_dir"
adb logcat -b all -v threadtime > "$output_dir/logcat-live.txt" 2>&1 &
logcat_pid=$!

finish() {
  status=$?
  trap - EXIT TERM INT
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
  if [ "$status" -ne 0 ]; then
    adb devices -l > "$output_dir/devices.txt" 2>&1 || true
    adb logcat -b all -d -v threadtime > "$output_dir/logcat-final.txt" 2>&1 || true
    adb shell dumpsys activity activities > "$output_dir/activities.txt" 2>&1 || true
    adb shell pm list packages > "$output_dir/packages.txt" 2>&1 || true
  fi
  exit "$status"
}

trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
"$@"
