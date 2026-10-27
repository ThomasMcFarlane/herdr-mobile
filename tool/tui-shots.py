#!/usr/bin/env python3
"""Pictures of herdr-tui's screens, from the real frames the UI draws.

    python3 tool/tui-shots.py [light|dark ...]       # default: light dark

The frames come from an ignored test (rust/crates/viewer/src/shots.rs) that draws scripted
conversations into a test buffer, so the colours are exactly what the UI produces, whatever
terminal would show them. tool/tui-render-png.py turns each into a PNG in docs/tui/.
Needs python3 with Pillow and the Fira Code Nerd Font (see tool/tui-render-png.py).
"""
import os, subprocess, sys, tempfile, glob

TOOL = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOL)
OUT = REPO + "/docs/tui"
os.makedirs(OUT, exist_ok=True)
themes = sys.argv[1:] or ["light", "dark"]
for theme in themes:
    if theme not in ("light", "dark"):
        sys.exit("usage: tui-shots.py [light|dark ...]")
    tmp = tempfile.mkdtemp(prefix="herdr-tui-shots-")
    env = dict(os.environ, HERDR_TUI_SHOTS=tmp, HERDR_TUI_SHOTS_THEME=theme)
    subprocess.run(["cargo", "test", "--manifest-path", REPO + "/rust/Cargo.toml", "-p", "herdr-tui", "--release", "--quiet",
                    "shots", "--", "--ignored"], env=env, check=True, capture_output=True)
    for ansi in sorted(glob.glob(tmp + "/*.ansi")):
        png = OUT + "/" + os.path.basename(ansi)[:-5] + ".png"
        subprocess.run([sys.executable, TOOL + "/tui-render-png.py", ansi, png, theme], check=True)
