#!/usr/bin/env bash
# Record the phone's screen for a release clip, with a clean status bar.
#
# Usage: record_clip.sh <out.mp4> [max-seconds, default 30]
#
# Needs exactly one adb device. While recording, the status bar is in
# SystemUI demo mode (12:00, full battery, full wifi, no notifications) and
# touches are shown; both are put back on every exit, Ctrl-C included.
# Press Enter to stop (or wait for max-seconds). Writes <out.mp4> and
# <out>.sheet.png, a contact sheet of one frame per second: look at every
# frame for private data (names, hosts, tokens, paths) before uploading.
set -euo pipefail

die() {
  printf 'record_clip: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '4p' "$0" | sed 's/^# //' >&2
  exit 1
}

(($# >= 1 && $# <= 2)) || usage
out="$1"
limit="${2:-30}"
[[ "$out" == *.mp4 ]] || die "the output must end in .mp4: $out"
if ! [[ "$limit" =~ ^[0-9]+$ ]] || ((limit < 1 || limit > 180)); then
  die "max-seconds must be 1-180 (screenrecord's own limit), got '$limit'."
fi
for tool in adb ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH."
done
mkdir -p "$(dirname "$out")"
sheet="${out%.mp4}.sheet.png"

# Exactly one device, so nothing lands on the wrong phone.
devices=()
while read -r serial state _; do
  [[ -n "$serial" && "$state" == "device" ]] && devices+=("$serial")
done < <(adb devices | tail -n +2)
if ((${#devices[@]} != 1)); then
  adb devices -l >&2 || true
  die "need exactly one adb device in state 'device', found ${#devices[@]}. Connect one phone (USB debugging allowed), or unplug the others." 2
fi
export ANDROID_SERIAL="${devices[0]}"

remote="/sdcard/herdr-clip-$$.mp4"
log="$(mktemp -t record_clip.XXXXXX)"
local_pid=""
remote_pid=""
prev_demo=""
prev_touches=""
changed=0

demo() {
  adb shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null
}

# Put an Android setting back as it was; "null" means it was never set.
restore_setting() {
  local ns="$1" key="$2" value="$3"
  if [[ "$value" == "null" || -z "$value" ]]; then
    adb shell settings delete "$ns" "$key" >/dev/null || true
  else
    adb shell settings put "$ns" "$key" "$value" || true
  fi
}

stop_recording() {
  # Only the screenrecord this script started, by its remote PID, and only
  # while it still runs (its adb client is alive), so a reused PID is safe.
  if [[ -n "$remote_pid" && -n "$local_pid" ]] && kill -0 "$local_pid" 2>/dev/null; then
    adb shell kill -INT "$remote_pid" 2>/dev/null || true
  fi
  remote_pid=""
  if [[ -n "$local_pid" ]]; then
    wait "$local_pid" 2>/dev/null || true
    local_pid=""
  fi
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  stop_recording
  if ((changed)); then
    demo exit || true
    restore_setting global sysui_demo_allowed "$prev_demo"
    restore_setting system show_touches "$prev_touches"
    printf 'record_clip: status bar and show_touches restored.\n' >&2
  fi
  adb shell rm -f "$remote" >/dev/null 2>&1 || true
  rm -f "$log"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prev_demo="$(adb shell settings get global sysui_demo_allowed | tr -d '\r')"
prev_touches="$(adb shell settings get system show_touches | tr -d '\r')"
changed=1
adb shell settings put global sysui_demo_allowed 1
adb shell settings put system show_touches 1
demo enter
demo clock -e hhmm 1200
demo battery -e level 100 -e plugged false
demo network -e wifi show -e level 4 -e fully true
demo network -e mobile hide
demo notifications -e visible false

# `exec` keeps the shell's PID for screenrecord, so the first line is its PID.
adb shell "echo \$\$; exec screenrecord --bit-rate 8000000 --time-limit $limit $remote" </dev/null >"$log" 2>&1 &
local_pid=$!
for _ in $(seq 50); do
  remote_pid="$(head -n 1 "$log" | tr -d '\r')"
  [[ "$remote_pid" =~ ^[0-9]+$ ]] && break
  remote_pid=""
  kill -0 "$local_pid" 2>/dev/null || break
  sleep 0.1
done
[[ -n "$remote_pid" ]] || die "screenrecord did not start: $(cat "$log")"

printf 'record_clip: recording (up to %s s). Follow the Try-it path, then press Enter.\n' "$limit"
while kill -0 "$local_pid" 2>/dev/null; do
  read -r -t 1 _ && break
  # A timeout (status > 128) loops at once; end of input waits instead of spinning.
  (($? > 128)) || sleep 1
done
stop_recording
# screenrecord writes the file's index as it exits; give the filesystem a beat.
sleep 1

adb pull "$remote" "$out" >/dev/null || die "could not pull $remote from the phone."
adb shell rm -f "$remote"

seconds="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$out")" ||
  die "the recording at $out is unreadable (stopped too early?). Record again."
frames="$(awk -v d="$seconds" 'BEGIN { n = int(d); if (n < d) n++; if (n < 1) n = 1; print n }')"
cols=6
rows=$(((frames + cols - 1) / cols))
ffmpeg -nostdin -v error -y -i "$out" \
  -vf "fps=1,scale=270:-2,tile=${cols}x${rows}:padding=8:margin=8:color=white" \
  -frames:v 1 "$sheet"

printf '%s\n' "$out"
printf '%s  (one frame per second, left to right: check every frame for private data)\n' "$sheet"
