#!/usr/bin/env bash
# What watching an agent costs the desk, deterministic, no terminal, no phone:
# the real `herdr-tui` render path (ratatui, TestBackend) draws 600 frames of a
# fixed 160-turn conversation — 300 following the newest output (an agent
# streaming), then 300 walking up through the whole scrollback the way the
# wheel does. Nothing is modelled; every frame is the real `ui::draw`.
#
#   frame_peak_us       THE number (lower is better): the slowest frame of the
#                       600, in microseconds. A frame over ~16 ms is a visible
#                       stutter; this is what scroll smoothness is made of.
#   frame_p95_us        the frame 95 % of frames beat
#   frame_mean_us       all 600 frames
#   follow_mean_us      the 300 follow-the-bottom frames
#   scroll_mean_us      the 300 scrollback frames
#   scroll_over_follow  how many times a scroll frame costs a follow frame:
#                       the jank a person feels when the wheel meets history
#   bytes_per_frame     the characters a drawn frame holds: what a real frame
#                       would put on the wire
#   peak_rss_kib        peak resident memory of the whole run: the "low
#                       memory" half of the ask
# The theme and motion switch on ambient env; pin them so the frames are the same every run.
unset NO_COLOR COLORFGBG HERDR_TUI_THEME HERDR_TUI_MOTION HERDR_TUI_INPUT
# A run takes ~5 s once built (a cold release build of the workspace is ~40 s).
set -euo pipefail

cd "$(dirname "$0")/rust"

cargo build --release --benches -p herdr-tui >/dev/null 2>&1 || {
  echo "build failed" >&2
  exit 1
}
bin="$(find target/release/deps -maxdepth 1 -name 'scroll-*' -type f -perm -u+x | head -1)"
[ -n "$bin" ] || { echo "no bench binary" >&2; exit 1; }

"$bin"
