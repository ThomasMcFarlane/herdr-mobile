#!/usr/bin/env python3
"""Renders `tmux capture-pane -e -p` output to a PNG: ANSI colours, bold/dim/italic/underline,
wide characters, a window frame. usage: render_png.py in.ansi out.png [dark|light] [cursor_x cursor_y]"""
import re, sys, unicodedata
from PIL import Image, ImageDraw, ImageFont

DARK = dict(bg="#1a1b26", fg="#c0caf5", frame="#16161e", ansi=["#15161e","#f7768e","#9ece6a","#e0af68","#7aa2f7","#bb9af7","#7dcfff","#a9b1d6",
            "#7480a8","#f7768e","#9ece6a","#e0af68","#7aa2f7","#bb9af7","#7dcfff","#c0caf5"], dim="#7480a8")
LIGHT = dict(bg="#fbf8f1", fg="#3b4252", frame="#ebe7dc", ansi=["#3b4252","#c0392b","#2f8f4e","#a07a00","#2e6fbd","#8e5bb5","#117a8b","#5b6573",
            "#7a8494","#c0392b","#2f8f4e","#a07a00","#2e6fbd","#8e5bb5","#117a8b","#2b303b"], dim="#7a8494")
FONT = "/home/tuannd12/.local/share/fonts/FiraCode/FiraCodeNerdFontMono-Regular.ttf"
BOLD = "/home/tuannd12/.local/share/fonts/FiraCode/FiraCodeNerdFontMono-Bold.ttf"
SIZE = 17
FALLBACK = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FALLBACK_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
# Box-drawing characters drawn as lines, not glyphs: (left, right, up, down, thickness).
BOX = {
    "─": (1, 1, 0, 0, 1), "━": (1, 1, 0, 0, 2), "│": (0, 0, 1, 1, 1), "┃": (0, 0, 1, 1, 2),
    "┌": (0, 1, 0, 1, 1), "┐": (1, 0, 0, 1, 1), "└": (0, 1, 1, 0, 1), "┘": (1, 0, 1, 0, 1),
    "╭": (0, 1, 0, 1, 1), "╮": (1, 0, 0, 1, 1), "╰": (0, 1, 1, 0, 1), "╯": (1, 0, 1, 0, 1),
    "├": (0, 1, 1, 1, 1), "┤": (1, 0, 1, 1, 1), "┬": (1, 1, 0, 1, 1), "┴": (1, 1, 1, 0, 1),
    "┼": (1, 1, 1, 1, 1),
}

def cellw(ch):
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else (0 if unicodedata.combining(ch) else 1)

def parse(text):
    rows = []
    for raw in text.split("\n"):
        cells, fg, bg, bold, dim, ital, ul, rev, strike = [], None, None, False, False, False, False, False, False
        i = 0
        while i < len(raw):
            if raw[i] == "\x1b" and i + 1 < len(raw) and raw[i+1] == "[":
                j = raw.index("m", i) if "m" in raw[i:] else None
                if j is None: break
                params = [int(p) if p else 0 for p in raw[i+2:j].split(";")] or [0]
                k = 0
                while k < len(params):
                    p = params[k]
                    if p == 0: fg = bg = None; bold = dim = ital = ul = rev = strike = False
                    elif p == 1: bold = True
                    elif p == 2: dim = True
                    elif p == 3: ital = True
                    elif p == 4: ul = True
                    elif p == 7: rev = True
                    elif p == 9: strike = True
                    elif p == 22: bold = dim = False
                    elif p == 23: ital = False
                    elif p == 24: ul = False
                    elif p == 27: rev = False
                    elif p == 29: strike = False
                    elif 30 <= p <= 37: fg = p - 30
                    elif p == 39: fg = None
                    elif 40 <= p <= 47: bg = p - 40
                    elif p == 49: bg = None
                    elif 90 <= p <= 97: fg = p - 90 + 8
                    elif 100 <= p <= 107: bg = p - 100 + 8
                    elif p in (38, 48) and k + 1 < len(params):
                        if params[k+1] == 5 and k + 2 < len(params):
                            val = params[k+2]; k += 2
                        elif params[k+1] == 2 and k + 4 < len(params):
                            val = tuple(params[k+2:k+5]); k += 4
                        else: val = None
                        if p == 38: fg = val
                        else: bg = val
                    k += 1
                i = j + 1
                continue
            ch = raw[i]; i += 1
            cells.append((ch, fg, bg, bold, dim, ital, ul, rev, strike))
        rows.append(cells)
    return rows

def color(spec, pal, default):
    if spec is None: return default
    if isinstance(spec, tuple): return "#%02x%02x%02x" % spec
    if spec < 16: return pal["ansi"][spec]
    if spec < 232:  # the 6x6x6 colour cube
        n = spec - 16; level = lambda v: 0 if v == 0 else 55 + v * 40
        return "#%02x%02x%02x" % (level(n // 36), level(n // 6 % 6), level(n % 6))
    g = 8 + (spec - 232) * 10  # the grey ramp
    return "#%02x%02x%02x" % (g, g, g)

def main():
    src, out = sys.argv[1], sys.argv[2]
    pal = LIGHT if len(sys.argv) > 3 and sys.argv[3] == "light" else DARK
    cur = (int(sys.argv[4]), int(sys.argv[5])) if len(sys.argv) > 5 else None
    rows = parse(open(src, encoding="utf-8").read().rstrip("\n"))
    font, bfont = ImageFont.truetype(FONT, SIZE), ImageFont.truetype(BOLD, SIZE)
    fb, fbb = ImageFont.truetype(FALLBACK, SIZE), ImageFont.truetype(FALLBACK_BOLD, SIZE)
    def glyph(ch):
        im = Image.new("L", (28, 28)); ImageDraw.Draw(im).text((2, 2), ch, font=font, fill=255); return im.tobytes()
    notdef = glyph("\U0010fffd")
    def pick(ch, bold):
        if ch.isascii() or glyph(ch) != notdef:
            return bfont if bold else font
        return fbb if bold else fb
    cw = font.getlength("M"); lh = int(SIZE * 1.42)
    cols = max(sum(cellw(c[0]) for c in r) for r in rows)
    pad, bar = 22, 38
    W, H = int(cols * cw) + pad * 2, len(rows) * lh + pad * 2 + bar
    img = Image.new("RGB", (W, H), pal["frame"]); d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=12, fill=pal["bg"], outline=pal["frame"])
    d.rectangle([0, 0, W, bar], fill=pal["frame"])
    for n, c in enumerate(["#ff5f56", "#ffbd2e", "#27c93f"]):
        d.ellipse([16 + n * 22, 13, 28 + n * 22, 25], fill=c)
    d.text((W / 2, 19), "herdr-tui", font=font, fill=pal["dim"], anchor="mm")
    for y, row in enumerate(rows):
        x = 0
        for ch, fg, bg, bold, dim, ital, ul, rev, strike in row:
            w = cellw(ch)
            if w == 0: continue
            f = color(fg, pal, pal["fg"]); b = color(bg, pal, None)
            if dim and fg is None: f = pal["dim"]
            if rev: f, b = (b or pal["bg"]), (f)
            px, py = pad + x * cw, bar + pad + y * lh
            if b: d.rectangle([px, py, px + w * cw, py + lh], fill=b)
            if ch in BOX:
                # As a terminal does: from the cell's centre to its edges, so lines meet across
                # cells and rows (a font's glyph stops short of the taller row and leaves gaps).
                l, r, u, dn, t = BOX[ch]
                cx, cy = int(px + cw / 2), py + lh // 2
                if l: d.line([px, cy, cx, cy], fill=f, width=t)
                if r: d.line([cx, cy, px + cw, cy], fill=f, width=t)
                if u: d.line([cx, py, cx, cy], fill=f, width=t)
                if dn: d.line([cx, cy, cx, py + lh], fill=f, width=t)
            elif ch != " ":
                d.text((px, py + 2), ch, font=pick(ch, bold), fill=f)
            if ul: d.line([px, py + lh - 3, px + w * cw, py + lh - 3], fill=f, width=1)
            if strike: d.line([px, py + lh // 2, px + w * cw, py + lh // 2], fill=f, width=1)
            x += w
    if cur:
        px, py = pad + cur[0] * cw, bar + pad + cur[1] * lh
        d.rectangle([px, py + 3, px + cw, py + lh - 2], outline=pal["fg"], width=1)
    img.save(out)
    print(out, img.size)

main()
