#!/usr/bin/env bash
# Mermaid benchmark, on a real phone: what diagrams cost while a chat scrolls
# over them (app/benchmark/mermaid_device_bench.dart). It builds a profile APK
# of the real Markdown renderer over 36 rows of prose and diagrams, installs it
# BESIDE the shipped app (own application id `...herdr_mobile.mermaidbench`, own
# data; the shipped app is never touched), scrolls it with real touch (`adb
# shell input swipe`) and turns what it logged into METRIC lines:
#
#   layout_wall_{p50,p95,max}_ms   cold, per diagram: asking the cache until the
#                                  result is back (isolate spawn + layout + copy)
#   record_{p50,p95,max}_ms        recording the picture, on the UI thread
#   diagrams_drawn                 how many of the 12 fixtures were drawn (11)
#   cold_*, warm_*                 scrolled 25 s with an empty cache, then 25 s
#                                  with the cache the first pass filled:
#                                  frames, build_{p50,p95,max}_ms,
#                                  raster_{p50,p95,max}_ms, late_frames (over
#                                  16.7 ms), pictures_held
#   thermal_status, battery_temp_c noise context: the phone throttles when hot
#
# Budgets (the stream bench's, on a profile build): while scrolling over
# diagrams build p95 < 4 ms, raster p95 < 8 ms, no late frames; layout_wall p95
# < 120 ms; record p95 < 12 ms; warm build p95 < 2 ms.
#
# Needs an adb device that is awake and unlocked. HERDR_BENCH_DEVICE=host:port
# picks one (default: the only connected device); for a phone on Wi-Fi:
# `adb connect host:port` first (Developer options > Wireless debugging).
#
#   MERMAID_RUNS=1          runs on the device (medians are reported); default 1
#   MERMAID_NO_BUILD=1      reuse the APK of the last build
#   MERMAID_TIMEOUT=300     seconds to wait for one run
set -euo pipefail

# Needs flutter and adb on PATH and ANDROID_HOME set (the Android SDK).
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
export ANDROID_HOME
cd "$(dirname "$0")/app"

pkg=dev.herdrmobile.herdr_mobile.mermaidbench
activity=dev.herdrmobile.herdr_mobile.MainActivity
built=build/app/outputs/flutter-apk/app-profile.apk
apk=build/mermaid-bench.apk
runs="${MERMAID_RUNS:-1}"
timeout_s="${MERMAID_TIMEOUT:-300}"

dev="${HERDR_BENCH_DEVICE:-$(adb devices | awk 'NR > 1 && $2 == "device" {print $1}' | head -1)}"
if [ -z "$dev" ]; then
  echo "no adb device: wake the phone, turn on Wireless debugging, adb connect host:port (or set HERDR_BENCH_DEVICE)" >&2
  exit 2
fi
phone() { adb -s "$dev" "$@"; }
echo "device: $dev $(phone shell getprop ro.product.model | tr -d '\r') (Android $(phone shell getprop ro.build.version.release | tr -d '\r'))" >&2

work="$(mktemp -d)"
stayon="$(phone shell settings get global stay_on_while_plugged_in | tr -d '\r')"
cleanup() {
  [ -n "${logpid:-}" ] && kill "$logpid" 2>/dev/null || true
  [ -n "${swipepid:-}" ] && kill "$swipepid" 2>/dev/null || true
  phone shell am force-stop "$pkg" >/dev/null 2>&1 || true
  [ -e /tmp/herdr-kb-keep-awake ] || phone shell settings put global stay_on_while_plugged_in "${stayon:-0}" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if [ "${MERMAID_NO_BUILD:-}" != 1 ]; then
  flutter build apk --profile --target-platform android-arm64 \
    -t benchmark/mermaid_device_bench.dart \
    --android-project-arg=appIdSuffix=.mermaidbench >&2
  # The other benches build to the same path: keep this one apart.
  cp "$built" "$apk"
fi
[ -f "$apk" ] || { echo "no $apk: run without MERMAID_NO_BUILD=1 first" >&2; exit 1; }
timeout 300 adb -s "$dev" install -r -t "$apk" >&2

size="$(phone shell wm size | tr -d '\r' | sed -n 's/.*: *\([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)"
w="${size% *}"; h="${size#* }"
x=$((w / 2)); top=$((h / 4)); bottom=$((h * 3 / 4))

# Real touch: six swipes up the list, six back, for as long as the app logs
# that it is being measured.
swipe_loop() {
  local n=0
  while true; do
    if [ $((n % 12)) -lt 6 ]; then
      phone shell input swipe "$x" "$bottom" "$x" "$top" 400
    else
      phone shell input swipe "$x" "$top" "$x" "$bottom" 400
    fi
    n=$((n + 1))
    sleep 0.8
  done
}

phone shell svc power stayon true >/dev/null
for i in $(seq 1 "$runs"); do
  log="$work/log.$i"
  : >"$log"
  phone shell input keyevent KEYCODE_WAKEUP
  phone shell am force-stop "$pkg"
  phone logcat -c
  adb -s "$dev" logcat -v brief -s flutter:I >"$log" &
  logpid=$!
  phone shell am start -W -n "$pkg/$activity" >/dev/null
  swipepid=
  for _ in $(seq 1 "$timeout_s"); do
    sleep 1
    if [ -z "$swipepid" ] && grep -q 'MERMAIDBENCH_READY' "$log"; then
      swipe_loop &
      swipepid=$!
    fi
    grep -qE 'MERMAIDBENCH_(DONE|ERROR)' "$log" && break
  done
  [ -n "$swipepid" ] && kill "$swipepid" 2>/dev/null || true
  swipepid=
  sleep 1
  kill "$logpid" 2>/dev/null || true
  logpid=
  sed -E 's/^[A-Z]\/flutter *\( *[0-9]+\): //' "$log" | grep MERMAIDBENCH >"$work/run.$i" || true
  cat "$work/run.$i" >&2
  if grep -q 'MERMAIDBENCH_ERROR' "$work/run.$i" || ! grep -q 'MERMAIDBENCH_DONE' "$work/run.$i"; then
    echo "run $i did not finish (phone locked or asleep? app crashed?)" >&2
    exit 1
  fi
done

thermal="$(phone shell dumpsys thermalservice | tr -d '\r' | sed -n 's/.*Thermal Status: *\([0-9]*\).*/\1/p' | head -1)"
temp="$(phone shell dumpsys battery | tr -d '\r' | sed -n 's/.*temperature: *\([0-9]*\).*/\1/p' | head -1)"

# Median of every metric across the runs.
python3 - "$work" "$runs" <<'PY'
import re, statistics, sys
work, runs = sys.argv[1], int(sys.argv[2])
values = {}
order = []
for i in range(1, runs + 1):
    for line in open(f"{work}/run.{i}"):
        m = re.match(r"MERMAIDBENCH_METRIC ([a-z0-9_]+)=(-?[0-9.]+)", line)
        if m:
            name = m.group(1)
            if name not in values:
                values[name] = []
                order.append(name)
            values[name].append(float(m.group(2)))
for name in order:
    v = statistics.median(values[name])
    print(f"METRIC {name}={v:.3f}")
PY
echo "METRIC thermal_status=${thermal:-0}"
echo "METRIC battery_temp_c=$(LC_ALL=C awk "BEGIN {print ${temp:-0} / 10}")"
