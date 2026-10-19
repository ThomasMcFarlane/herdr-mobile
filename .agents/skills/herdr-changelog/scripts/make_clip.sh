#!/usr/bin/env bash
# Turn a phone recording into a herdr release clip with HyperFrames.
#
# Usage: make_clip.sh --version X.Y.Z --slug <kebab> --recording <mp4> \
#          --headline "<text>" [--caption "Try it: <path>"] \
#          [--touches <touches.json>] [--trim-start S] [--trim-end S] \
#          [--poster-at S]
#
# The clip is the recording itself: 1080x1920 (9:16, for phones), the whole
# screen fitted and letterboxed on paper or ink, silent. It fades up into the
# first frame, plays, holds the last frame and fades out over 0.4 s.
#
# Two shapes:
#   - One change (no chapters): the trimmed recording must be 3-18.8 s; the
#     last frame holds 0.8 s, so the clip is at most 20 s and 15 MB.
#     --caption is required and is the last caption.
#   - A walkthrough of the release's change list (touches.json has "chapter"
#     steps; use --slug whats-new): the recording may be 3-75 s; the last frame
#     holds 1.2 s, so the clip is at most ~77 s (80 s cap) and 30 MB. A card
#     per chapter shows "2/5" and the change's name, with the current step's
#     label under it, and a progress bar in the top safe zone. --caption is
#     optional: without it the held last frame says "herdr mobile <version>"
#     and "N changes".
#
# --caption: one quiet caption near the bottom; `backticked` UI labels in it
# take the accent. --headline is required but is metadata only (the
# composition's `headline` variable), never drawn.
#
# --touches (optional) adds a camera, touch marks and step captions. Times in
# seconds from the recording's first frame, x/y as 0..1 of the recording:
#   {"steps": [
#     {"t": 0.5, "kind": "chapter", "label": "The tab bar says where you are",
#      "index": 1, "total": 5},
#     {"t": 1.2, "x": 0.5, "y": 0.31, "kind": "tap", "label": "Tap the agent"},
#     {"t": 3.0, "x": 0.8, "y": 0.55, "kind": "drag", "to": {"x": 0.25, "y": 0.55},
#      "until": 4.6, "label": "Drag slowly sideways"},
#     {"t": 4.9, "x": 0.25, "y": 0.55, "kind": "release", "label": "Let go"}]}
# A release ends the drag before it. A chapter starts a new change: the camera
# eases back to 1x and the caption card changes. Captions sit at the bottom,
# or at the top when a touch would be under them; add "place": "top" (or
# "bottom") to a chapter or step whose change happens at the bottom of the
# screen (a toast, a sheet) so the card does not cover it. Trims shift the
# times; steps outside the kept range are dropped (a chapter already running at
# the trim start is kept, from 0). Without --touches (a recording with
# show_touches baked in) the clip gets the caption and a slow settle-in.
#
# Builds local/release-media/<version>/clip-<slug>/ from assets/clip/, runs
# `hyperframes check` (lint, layout, contrast), renders
# local/release-media/<version>/<version>-<slug>.mp4 and prints its duration,
# resolution and size. Run it from inside the repo: the repo root comes from
# `git rev-parse --show-toplevel`. Media under local/ are git-ignored and never
# committed: upload them to the GitHub release.
#
# Poster: next to the mp4 it writes local/release-media/<version>/<version>-<slug>.jpg,
# one frame of the rendered clip, 720 px wide (9:16), JPEG of at most 80 KB
# (the quality is lowered until it fits; it fails if even the lowest does not).
# The app's update sheet and the GitHub release show it as the clip's poster.
# --poster-at S picks the frame, in seconds of the rendered clip. Default: 0.6 s
# after the first chapter's card has fully entered, or 1.0 s without chapters.
# Pick a calm frame: not one where an orange "needs you" card dominates.
set -euo pipefail

HYPERFRAMES="hyperframes@0.8.174"
MIN_SECONDS=3
FADE_SECONDS=0.4 # FADE in assets/clip/index.html
FPS=30
# The canvas in assets/clip/index.html (data-width x data-height).
WIDTH=1080
HEIGHT=1920
PAPER="#FBFBFA" # docs/DESIGN.md bg, paper
INK="#0D0E10"   # docs/DESIGN.md bg, ink

die() {
  printf 'make_clip: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

version="" slug="" recording="" headline="" caption="" touches="" trim_start=0 trim_end=0 poster_at=""
while (($#)); do
  case "$1" in
    --version) version="${2-}"; shift 2 ;;
    --slug) slug="${2-}"; shift 2 ;;
    --recording) recording="${2-}"; shift 2 ;;
    --headline) headline="${2-}"; shift 2 ;;
    --caption) caption="${2-}"; shift 2 ;;
    --touches) touches="${2-}"; shift 2 ;;
    --trim-start) trim_start="${2-}"; shift 2 ;;
    --trim-end) trim_end="${2-}"; shift 2 ;;
    --poster-at) poster_at="${2-}"; shift 2 ;;
    -h | --help) usage ;;
    *) printf 'make_clip: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[[ -n "$version" && -n "$slug" && -n "$recording" && -n "$headline" ]] || usage
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "bad --version '$version': use X.Y.Z, the version in the CHANGELOG heading."
[[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
  die "bad --slug '$slug': use lower-case words joined by single hyphens, e.g. pages-inside-herdr."
[[ -f "$recording" ]] ||
  die "no recording at '$recording': record one with scripts/record_clip.sh <out.mp4>."
[[ -z "$touches" || -f "$touches" ]] ||
  die "no touches file at '$touches': drop --touches, or give the steps JSON."
[[ -z "$caption" || "$caption" =~ ^Try\ it:\ .+ ]] ||
  die "bad --caption: start it with 'Try it: ' and give the path, as in the CHANGELOG tip."
for t in "$trim_start" "$trim_end"; do
  [[ "$t" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "bad trim '$t': give seconds, e.g. 1.5."
done
[[ -z "$poster_at" || "$poster_at" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
  die "bad --poster-at '$poster_at': give seconds into the rendered clip, e.g. 1.2."
for tool in git ffmpeg ffprobe node npx; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH."
done

root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die "not inside a git repo: run this from the herdr-mobile checkout."
template="$(cd "$(dirname "${BASH_SOURCE[0]}")/../assets/clip" && pwd)"
fonts="$root/app/assets/fonts"
media="$root/local/release-media/$version"
work="$media/clip-$slug"
out="$media/$version-$slug.mp4"

for weight in Regular SemiBold; do
  [[ -f "$fonts/Inter-$weight.ttf" ]] || die "missing $fonts/Inter-$weight.ttf: run this in the herdr-mobile repo."
done

source_seconds="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$recording")" ||
  die "ffprobe cannot read '$recording': is it an MP4 from record_clip.sh?"
source_size="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$recording")"
src_w="${source_size%x*}"
src_h="${source_size#*x}"
keep="$(awk -v d="$source_seconds" -v s="$trim_start" -v e="$trim_end" 'BEGIN { printf "%.3f", d - s - e }')"
awk -v k="$keep" 'BEGIN { exit !(k > 0) }' ||
  die "trims ($trim_start s + $trim_end s) leave nothing of a ${source_seconds} s recording."

# Touches: validate, shift by the trim, drop what falls outside, and map to
# canvas pixels (the recording is fitted whole and centred in the canvas).
steps_json='{"steps":[]}'
if [[ -n "$touches" ]]; then
  steps_json="$(TOUCHES="$touches" TRIM="$trim_start" KEEP="$keep" SRC_W="$src_w" SRC_H="$src_h" \
    W="$WIDTH" H="$HEIGHT" node - <<'JS'
const fs = require("fs");
const env = process.env;
const fail = (msg) => {
  process.stderr.write(`make_clip: bad --touches ${env.TOUCHES}: ${msg}\n`);
  process.exit(1);
};
let data;
try {
  data = JSON.parse(fs.readFileSync(env.TOUCHES, "utf8"));
} catch (e) {
  fail(`not JSON (${e.message})`);
}
if (!data || !Array.isArray(data.steps)) fail('needs {"steps": [...]}');
const unit = (v) => typeof v === "number" && v >= 0 && v <= 1;
const whole = (v) => Number.isInteger(v) && v >= 1;
const [trim, keep] = [Number(env.TRIM), Number(env.KEEP)];
const [W, H, sw, sh] = [env.W, env.H, env.SRC_W, env.SRC_H].map(Number);
const k = Math.min(W / sw, H / sh);
const [ox, oy] = [(W - sw * k) / 2, (H - sh * k) / 2];
const px = (p) => ({ x: +(ox + p.x * sw * k).toFixed(1), y: +(oy + p.y * sh * k).toFixed(1) });
const r3 = (v) => +v.toFixed(3);
const out = [];
let last = -Infinity;
let running = null; // the chapter already under way at the trim start
data.steps.forEach((s, i) => {
  const at = `step ${i + 1}`;
  if (!["tap", "drag", "release", "chapter"].includes(s.kind)) fail(`${at}: kind must be tap, drag, release or chapter`);
  if (typeof s.t !== "number" || s.t < last) fail(`${at}: t must be a number, in order`);
  last = s.t;
  if (typeof s.label !== "string" || !s.label.trim()) fail(`${at}: needs a label (its caption)`);
  if (s.place !== undefined && s.place !== "top" && s.place !== "bottom") fail(`${at}: "place" is "top" or "bottom"`);
  const place = s.place ? { place: s.place } : {};
  const t = s.t - trim;
  if (s.kind === "chapter") {
    if (!whole(s.index) || !whole(s.total) || s.index > s.total) fail(`${at}: a chapter needs whole "index" <= "total"`);
    const step = { t: r3(t), kind: "chapter", label: s.label.trim(), index: s.index, total: s.total, ...place };
    if (t < 0) running = step;
    else if (t < keep) out.push(step);
    return;
  }
  if (!unit(s.x) || !unit(s.y)) fail(`${at}: x and y must be 0..1 of the recording frame`);
  if (s.kind === "drag") {
    if (!s.to || !unit(s.to.x) || !unit(s.to.y)) fail(`${at}: a drag needs "to": {"x", "y"} in 0..1`);
    if (typeof s.until !== "number" || s.until <= s.t) fail(`${at}: a drag needs "until" after "t"`);
  }
  if (t < 0 || t >= keep) return; // outside the kept range
  const prev = out.filter((o) => o.kind !== "chapter").pop();
  if (s.kind === "release" && !(prev && prev.kind === "drag")) return;
  const step = { t: r3(t), ...px(s), kind: s.kind, label: s.label.trim(), ...place };
  if (s.kind === "drag") {
    step.to = px(s.to);
    step.until = r3(Math.min(s.until - trim, keep));
  }
  out.push(step);
});
if (running) out.unshift({ ...running, t: 0 });
process.stdout.write(JSON.stringify({ steps: out }));
JS
  )" || exit 1
fi
chapters="$(printf '%s' "$steps_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).steps.filter(x=>x.kind==="chapter").length))')"
# Default poster time. Mirrors assets/clip/clip.js: a chapter card starts
# entering at max(t - 0.1, 0.3) and takes 0.25 s (Motion.sheetIn).
if [[ -z "$poster_at" ]]; then
  poster_at="$(printf '%s' "$steps_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s).steps.find(x=>x.kind==="chapter");console.log(c?(Math.max(c.t-0.1,0.3)+0.25+0.6).toFixed(2):"1.00")})')"
fi

# The walkthrough (chapters) is the long shape; everything else stays short.
if ((chapters > 0)); then
  max_footage=75 max_clip=80 max_mb=30 hold=1.2
  # JPEG frame extraction: a long clip's PNG frames would not fit on a small disk.
  frame_format=jpg
else
  max_footage=18.8 max_clip=20 max_mb=15 hold=0.8
  frame_format=png
  [[ -n "$caption" ]] || die "--caption is required unless --touches has chapters: give the Try-it path."
fi
tail_seconds="$(awk -v h="$hold" -v f="$FADE_SECONDS" 'BEGIN { printf "%.1f", h + f }')"
max_bytes=$((max_mb * 1024 * 1024))

check_length() {
  local seconds="$1"
  awk -v x="$seconds" -v max="$max_footage" 'BEGIN { exit !(x <= max) }' ||
    die "the recording after trims is ${seconds} s, over ${max_footage} s (the clip adds ${tail_seconds} s of hold and fade; ${max_clip} s at most): cut it down with --trim-start/--trim-end."
  awk -v x="$seconds" -v min="$MIN_SECONDS" 'BEGIN { exit !(x >= min) }' ||
    die "the recording after trims is ${seconds} s, under ${MIN_SECONDS} s: trim less, or record the whole Try-it path."
}
check_length "$keep"

# Letterbox on paper for a light recording, on ink for a dark one, so the
# bars read as the app's own background. Judged on the middle frame.
middle="$(awk -v s="$trim_start" -v k="$keep" 'BEGIN { printf "%.3f", s + k / 2 }')"
luma="$(ffmpeg -nostdin -v error -ss "$middle" -i "$recording" -frames:v 1 \
  -vf "scale=1:1:flags=area,format=gray" -f rawvideo - | od -An -tu1 | tr -d ' \n')"
[[ "$luma" =~ ^[0-9]+$ ]] || die "could not read a frame of '$recording' at ${middle} s."
if ((luma >= 128)); then backdrop="$PAPER"; else backdrop="$INK"; fi

# With touches the camera punches in, so prepare the footage at 1.25x the
# canvas to keep it sharp; without, at the canvas size.
if [[ -n "$touches" ]]; then scale=1.25; else scale=1; fi
prep_w="$(awk -v w="$WIDTH" -v s="$scale" 'BEGIN { printf "%d", w * s }')"
prep_h="$(awk -v h="$HEIGHT" -v s="$scale" 'BEGIN { printf "%d", h * s }')"

# A rerun rebuilds the working project, but only one this script made.
if [[ -e "$work" ]]; then
  grep -q '"herdr-release-clip"' "$work/meta.json" 2>/dev/null ||
    die "$work exists and is not a clip project made by this script: move it away first."
  rm -rf "$work"
fi
mkdir -p "$work/assets" "$work/fonts"
cp "$template/index.html" "$template/clip.js" "$template/hyperframes.json" "$template/meta.json" "$work/"
for weight in Regular SemiBold; do
  cp "$fonts/Inter-$weight.ttf" "$work/fonts/"
done

# Trim, fit the whole screen in, hold the last frame for the ending, constant
# frame rate, no audio, and a keyframe every second (the renderer seeks the
# video frame by frame).
ffmpeg -nostdin -v error -y -ss "$trim_start" -t "$keep" -i "$recording" -an \
  -vf "scale=${prep_w}:${prep_h}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,pad=${prep_w}:${prep_h}:(ow-iw)/2:(oh-ih)/2:color=0x${backdrop#\#},fps=${FPS},tpad=stop_mode=clone:stop_duration=${tail_seconds},format=yuv420p,setsar=1" \
  -c:v libx264 -preset medium -crf 14 -g "$FPS" -keyint_min "$FPS" -movflags +faststart "$work/assets/recording.mp4"

prepared="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$work/assets/recording.mp4")"
total="$(awk -v d="$prepared" -v f="$FPS" 'BEGIN { printf "%.3f", int(d * f + 0.5) / f }')"
check_length "$(awk -v x="$total" -v t="$tail_seconds" 'BEGIN { printf "%.3f", x - t }')"

# Fill the variables' defaults (so check, preview and render all see them)
# and the clip's length.
HEADLINE="$headline" CAPTION="$caption" VERSION="$version" BACKDROP="$backdrop" \
  STEPS="$steps_json" HOLD="$hold" TOTAL="$total" INDEX="$work/index.html" node - <<'JS'
const fs = require("fs");
const env = process.env;
let html = fs.readFileSync(env.INDEX, "utf8");

const unescape = (s) =>
  s.replace(/&#39;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
const escape = (s) =>
  s.replace(/&/g, "&amp;").replace(/'/g, "&#39;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const varsRe = /data-composition-variables='([^']*)'/;
const match = html.match(varsRe);
if (!match) throw new Error("template has no data-composition-variables");
const vars = JSON.parse(unescape(match[1]));
const values = {
  headline: env.HEADLINE,
  caption: env.CAPTION,
  version: env.VERSION,
  backdrop: env.BACKDROP,
  touches: env.STEPS,
  hold: Number(env.HOLD),
};
for (const v of vars) if (v.id in values) v.default = values[v.id];
html = html.replace(varsRe, () => `data-composition-variables='${escape(JSON.stringify(vars))}'`);

// A timed element's attribute, by id. The id must exist, or the template changed.
const setAttr = (id, attr, value) => {
  const re = new RegExp(`(<[^>]*\\bid="${id}"[^>]*?\\b${attr}=")[^"]*(")`);
  if (!re.test(html)) throw new Error(`template: no ${attr} on #${id}`);
  html = html.replace(re, `$1${value}$2`);
};
setAttr("root", "data-duration", env.TOTAL);
setAttr("recording", "data-duration", env.TOTAL);
fs.writeFileSync(env.INDEX, html);
JS

steps_count="$(printf '%s' "$steps_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).steps.length))')"
printf 'make_clip: project %s (%s s, %s steps, %s chapters, letterbox %s)\n' \
  "$work" "$total" "$steps_count" "$chapters" "$backdrop"

npx --yes "$HYPERFRAMES" check "$work" ||
  die "hyperframes check failed (findings above). A long caption or label overflows: shorten it; otherwise fix assets/clip/index.html and rerun."

# No shared frame cache: the disk on the release machine is small.
npx --yes "$HYPERFRAMES" render "$work" --output "$out" --fps "$FPS" --quality looks \
  --video-frame-format "$frame_format" --frames-cache-dir off --strict --quiet ||
  die "hyperframes render failed (output above)."
[[ -s "$out" ]] || die "render produced no file at $out."

# Silent: a release clip carries no audio track.
if [[ -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$out")" ]]; then
  ffmpeg -nostdin -v error -y -i "$out" -map 0:v -c copy -movflags +faststart "$out.silent.mp4"
  mv "$out.silent.mp4" "$out"
fi

duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$out")"
resolution="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$out")"
codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$out")"
bytes="$(wc -c <"$out" | tr -d ' ')"
size="$(awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }')"
# The poster: one frame, 720 px wide, JPEG, at most 80 KB.
poster="${out%.mp4}.jpg"
awk -v p="$poster_at" -v d="$duration" 'BEGIN { exit !(p < d) }' ||
  die "--poster-at ${poster_at} s is past the end of the ${duration} s clip."
poster_bytes=""
for q in $(seq 2 31); do
  ffmpeg -nostdin -v error -y -ss "$poster_at" -i "$out" -frames:v 1 \
    -vf "scale=720:-2:flags=lanczos" -q:v "$q" "$poster"
  poster_bytes="$(wc -c <"$poster" | tr -d ' ')"
  ((poster_bytes <= 80 * 1024)) && break
done
((poster_bytes <= 80 * 1024)) ||
  die "poster at ${poster_at} s is $((poster_bytes / 1024)) KB even at the lowest JPEG quality, over 80 KB: pick a calmer frame with --poster-at."

printf '%s\n' "$out"
printf 'duration:   %.2f s\n' "$duration"
printf 'resolution: %s (%s, no audio)\n' "$resolution" "$codec"
printf 'size:       %s (%s bytes)\n' "$size" "$bytes"
printf 'poster:     %s (%s s, %s KB, JPEG q %s)\n' "$poster" "$poster_at" "$((poster_bytes / 1024))" "$q"

[[ "$resolution" == "${WIDTH}x${HEIGHT}" ]] ||
  die "rendered $resolution, expected ${WIDTH}x${HEIGHT}: check data-width/data-height in assets/clip/index.html."
[[ "$codec" == "h264" ]] || die "rendered $codec, expected h264."
awk -v d="$duration" -v max="$max_clip" 'BEGIN { exit !(d <= max + 0.05) }' ||
  die "clip is ${duration} s, over ${max_clip} s: trim the recording with --trim-start/--trim-end."
((bytes <= max_bytes)) ||
  die "clip is $size, over ${max_mb} MB: trim the recording, or record with less motion (scrolling costs bits)."
