#!/usr/bin/env python3
"""Builds herdr's own icon font: glyphs drawn for herdr where icons sit as peers.

    pip install fonttools skia-pathops            # once (pillow numpy for --measure)
    python3 tool/icons/build_icons.py             # writes the font and the Dart constants
    python3 tool/icons/build_icons.py --measure   # also prints each glyph's weight

Why drawn: Lucide draws on one 24 grid with no keylines, so peers in one bar
differ in visual weight (its `server` encloses 1.7x the area of its `bot`; its
`x` half the ink of `circleStop`). These glyphs share Lucide's grammar and are
written the way Lucide's SVGs are: centre lines on the 24 grid in SVG path
syntax, stroked 2 wide with round caps and joins. Each fits a keyline and is
tuned until peers weigh the same: `--measure` prints silhouette (sqrt of the
area the shape encloses), ink (stroke area) and squint (what stays dark after a
1.5 dp blur at 30%: size and density together). Peers in one bar keep their
squint within ~1.5 (docs/DESIGN.md, "Drawn icons").

The strokes are outlined and merged by Skia (skia-pathops) into one contour
set without overlaps: FreeType, which draws text on Android, can leave seams
where contours of one glyph overlap. The font and the Dart file are committed,
so building the app never needs Python.
"""
import argparse
import math
import pathlib

import pathops
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path

ROOT = pathlib.Path(__file__).resolve().parents[2]
FONT = ROOT / 'app/assets/fonts/HerdrIcons.ttf'
DART = ROOT / 'app/lib/ui/core/herdr_icons.dart'
FAMILY = 'HerdrIcons'
UPM = 960
S = UPM / 24  # font units per grid unit
STROKE = 2.0  # grid units: Lucide's


# --- path helpers (SVG path data on the 24 grid, y down) -------------------

def rrect(x0, y0, x1, y1, r):
    return (f'M{x0 + r} {y0}H{x1 - r}A{r} {r} 0 0 1 {x1} {y0 + r}V{y1 - r}A{r} {r} 0 0 1 {x1 - r} {y1}'
            f'H{x0 + r}A{r} {r} 0 0 1 {x0} {y1 - r}V{y0 + r}A{r} {r} 0 0 1 {x0 + r} {y0}Z')


def circle(cx, cy, r):
    # Four quarter arcs: a half arc is ambiguous for the arc parser.
    return (f'M{cx + r} {cy}A{r} {r} 0 0 1 {cx} {cy + r}A{r} {r} 0 0 1 {cx - r} {cy}'
            f'A{r} {r} 0 0 1 {cx} {cy - r}A{r} {r} 0 0 1 {cx + r} {cy}Z')


def gear(cx, cy, teeth, r_out, r_in, top, flank, n=360):
    """A gear's centre line on a smooth tooth profile (raised-cosine flanks)."""
    def radius(t):
        f = (t * teeth / (2 * math.pi)) % 1.0
        d = min(f, 1 - f)
        if d <= top / 2:
            return r_out
        if d >= top / 2 + flank:
            return r_in
        k = (d - top / 2) / flank
        return r_in + (r_out - r_in) * (0.5 + 0.5 * math.cos(math.pi * k))
    pts = [(cx + radius(2 * math.pi * i / n) * math.cos(2 * math.pi * i / n),
            cy + radius(2 * math.pi * i / n) * math.sin(2 * math.pi * i / n)) for i in range(n)]
    return 'M' + 'L'.join(f'{x:.3f} {y:.3f}' for x, y in pts) + 'Z'


# --- glyphs ------------------------------------------------------------------
# strokes: centre lines stroked STROKE wide; rings: (cx, cy, r) circles of
# that stroke, built as a disc less a disc (Skia's stroker squares off a
# small circle's inner edge); fills: solid shapes; cut: an
# "off" slash (a, b, gap): the strokes are cleared within gap of it, then it
# is stroked.

GLYPHS = [
    dict(cp=0xE000, name='agents', doc='An agent: the Agents tab, subagents, agent rows.',
         # A head on the landscape keyline, a short antenna (clear of the badge,
         # which sits on the icon's top right) and two eyes.
         strokes=[rrect(2.5, 8, 21.5, 20.5, 4.5), 'M12 8V5.5', 'M8.75 12.5V16', 'M15.25 12.5V16'],
         fills=[circle(12, 4.2, 1.45)]),
    dict(cp=0xE001, name='machines', doc='A machine: the Machines tab, machine rows and pickers, what lives on it.',
         # A screen on a stand: "a machine" (a Mac, a dev box, a Pi with a
         # display). One box with a slot read as a toggle; a terminal window as a pane.
         strokes=[rrect(2.5, 4, 21.5, 15.5, 2.5), 'M12 15.5V19.5', 'M8 19.5H16']),
    dict(cp=0xE003, name='machinesOff', doc='A machine the app cannot reach: the machine, slashed.',
         strokes=[rrect(2.5, 4, 21.5, 15.5, 2.5), 'M12 15.5V19.5', 'M8 19.5H16'],
         cut=((2.5, 2.5), (21.5, 21.5), 2.4)),
    dict(cp=0xE002, name='settings', doc='Settings.',
         # Six teeth: eight made the darkest mass in the tab bar.
         strokes=[gear(12, 12, 6, 9.1, 7.5, top=0.30, flank=0.12)], rings=[(12, 12, 2.5)]),
    dict(cp=0xE010, name='stop', doc='Stop agents (the selection bar).',
         rings=[(12, 12, 9)], fills=[rrect(8.75, 8.75, 15.25, 15.25, 1.5)]),
    dict(cp=0xE011, name='message', doc='Message agents (the selection bar).',
         # A speech bubble whose left edge runs on into the tail, as Lucide's does.
         strokes=['M6 4H18A3 3 0 0 1 21 7V13.5A3 3 0 0 1 18 16.5H8L3.5 20.5V7A3 3 0 0 1 6 4Z']),
    dict(cp=0xE012, name='close', doc='Close agents (the selection bar).',
         # A bare x, larger than Lucide's 14 so it weighs with a ring and a
         # bubble, and keeps a shape of its own next to Stop.
         strokes=['M5 5L19 19', 'M19 5L5 19']),
]


def _path(d):
    p = pathops.Path()
    parse_path(d, p.getPen())
    p.convertConicsToQuads(0.005)
    return p


def _stroked(d):
    p = _path(d)
    p.stroke(STROKE, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    p.convertConicsToQuads(0.005)
    return p


def outline(g):
    shape = pathops.Path()
    for d in g.get('strokes', []):
        shape = pathops.op(shape, _stroked(d), pathops.PathOp.UNION)
    if 'cut' in g:
        (ax, ay), (bx, by), gap = g['cut']
        band = _path(f'M{ax} {ay}L{bx} {by}')
        band.stroke(gap * 2, pathops.LineCap.BUTT_CAP, pathops.LineJoin.MITER_JOIN, 4)
        band.convertConicsToQuads(0.005)
        shape = pathops.op(shape, band, pathops.PathOp.DIFFERENCE)
        shape = pathops.op(shape, _stroked(f'M{ax} {ay}L{bx} {by}'), pathops.PathOp.UNION)
    for cx, cy, r in g.get('rings', []):
        disc = pathops.op(_path(circle(cx, cy, r + STROKE / 2)), _path(circle(cx, cy, r - STROKE / 2)), pathops.PathOp.DIFFERENCE)
        shape = pathops.op(shape, disc, pathops.PathOp.UNION)
    for d in g.get('fills', []):
        shape = pathops.op(shape, _path(d), pathops.PathOp.UNION)
    shape.simplify()
    return shape


def build():
    names = ['.notdef'] + [g['name'] for g in GLYPHS]
    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({g['cp']: g['name'] for g in GLYPHS})
    glyphs = {'.notdef': TTGlyphPen(None).glyph()}
    for g in GLYPHS:
        pen = TTGlyphPen(None)
        # Grid (y down) to font units (y up, the em's bottom at 0); cubic arcs to quadratics.
        outline(g).draw(TransformPen(Cu2QuPen(pen, max_err=0.5, reverse_direction=True), (S, 0, 0, -S, 0, UPM)))
        glyphs[g['name']] = pen.glyph()
    fb.setupGlyf(glyphs)
    glyf = fb.font['glyf']
    lsb = {}
    for n in names:
        gl = glyf[n]
        if gl.numberOfContours:
            gl.recalcBounds(glyf)
        lsb[n] = getattr(gl, 'xMin', 0)
    # The left side bearing must equal xMin, or rasterisers shift the glyph to x = 0.
    fb.setupHorizontalMetrics({n: (UPM, lsb[n]) for n in names})
    fb.setupHorizontalHeader(ascent=UPM, descent=0)
    fb.setupNameTable({'familyName': FAMILY, 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=UPM, sTypoDescender=0, usWinAscent=UPM, usWinDescent=0)
    fb.setupPost(keepGlyphNames=False)
    FONT.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(FONT))

    lines = [
        '// GENERATED by tool/icons/build_icons.py. Do not edit: change the',
        '// drawing there and run it again (docs/DESIGN.md, "Drawn icons").',
        '',
        "import 'package:flutter/widgets.dart';",
        '',
        "/// herdr's own glyphs: the agent and the machine everywhere, and icons that",
        "/// sit as peers in one bar (Lucide's differ in visual weight there). Same",
        '/// grammar as Lucide: 24 grid, stroke 2, round caps; any [IconSize].',
        'abstract final class HerdrIcons {',
    ]
    for g in GLYPHS:
        lines += [f"  /// {g['doc']}", f"  static const IconData {g['name']} = IconData(0x{g['cp']:04X}, fontFamily: '{FAMILY}');", '']
    lines[-1] = '}'
    DART.write_text('\n'.join(lines) + '\n')


def measure():
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter, ImageFont

    dpr, dp = 3, 24
    px = dp * dpr
    font = ImageFont.truetype(str(FONT), px)

    def fill_holes(mask):
        im = Image.fromarray(np.pad((mask * 255).astype(np.uint8), 1)).copy()
        ImageDraw.floodfill(im, (0, 0), 128)
        return np.asarray(im)[1:-1, 1:-1] != 128

    def close(mask, r):
        im = Image.fromarray((mask * 255).astype(np.uint8))
        k = 2 * r + 1
        return np.asarray(im.filter(ImageFilter.MaxFilter(k)).filter(ImageFilter.MinFilter(k))) > 127

    print(f'{"glyph":12} silhouette   ink  squint')
    for g in GLYPHS:
        im = Image.new('L', (px * 3, px * 3), 0)
        ImageDraw.Draw(im).text((px, px), chr(g['cp']), font=font, fill=255)
        a = np.asarray(im).astype(float) / 255
        area = fill_holes(close(a > 0.5, round(1.5 * dpr))).sum() / dpr / dpr
        blurred = np.asarray(im.filter(ImageFilter.GaussianBlur(1.5 * dpr))).astype(float) / 255
        squint = ((blurred > 0.30).sum() / dpr / dpr) ** 0.5
        print(f"{g['name']:12} {area ** 0.5:10.1f} {a.sum() / dpr / dpr:5.0f} {squint:7.1f}")


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--measure', action='store_true')
    args = ap.parse_args()
    build()
    if args.measure:
        measure()
