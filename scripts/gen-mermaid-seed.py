#!/usr/bin/env python3
"""Regenerate mermaid seed PNGs (issue #323).

mermaid-seed.png is a faithful static mimic of a real `flowchart TD`
mermaid render of the test_cases/plugin_mermaid.md fixture ("Reader opens
doc" --> "Diagram renders"): vertical layout, two lavender-filled
purple-bordered boxes, vertical arrow, smooth sans-serif labels.

mermaid-seed-tall.png is the huge-rendered-image companion for the
test_cases/plugin_mermaid_tall.md fixture: same style and column width,
but a genuinely complex 26-node flowchart (~3140px tall: auth/cache
branches, parallel tokenize/index fan-out with join, image/plugin
decisions, cache seed/fallback split, overlay fan-in, bypass rail),
mirroring the fixture node-for-node and proving oversize-image geometry
(clamp/fit, scrollbar/height math, no blowup). No mermaid renderer binary
exists in this env, so both draw reference geometry directly
(synthetic-but-plausible, per suite practice).

Requires Pillow (fixture generation only, never ships): pip install pillow.
Usage:  python3 scripts/gen-mermaid-seed.py
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("FAIL: gen-mermaid-seed needs Pillow (pip install pillow)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "test_cases", "assets", "mermaid-seed.png")
OUT_TALL = os.path.join(ROOT, "test_cases", "assets", "mermaid-seed-tall.png")

# Sampled from the reference mermaid render (/tmp/ref-mermaid.png, 476x424).
W, H = 476, 424
BG = (255, 255, 255)
FILL = (236, 236, 254)  # lavender box fill (#ececfe)
EDGE = (142, 114, 213)  # purple box border (#8e72d5)
INK = (51, 51, 51)  # dark clean-sans labels + arrow (#333333)
EDGE_W = 2

BOX1 = (53, 54, 427, 163)  # "Reader opens doc"
BOX2 = (61, 262, 418, 370)  # "Diagram renders"
ARROW_X = 240
ARROW_TOP = 164
ARROW_HEAD_BASE = 246
ARROW_TIP = 261
ARROW_HALF = 9

FONT_SIZE = 30
FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def load_font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size), path
            except OSError:
                continue
    sys.exit("FAIL: no clean sans TTF found (%s)" % ", ".join(FONT_CANDIDATES))


def main():
    font, font_path = load_font(FONT_SIZE)
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    for box in (BOX1, BOX2):
        d.rectangle(box, fill=FILL, outline=EDGE, width=EDGE_W)
    d.line([(ARROW_X, ARROW_TOP), (ARROW_X, ARROW_HEAD_BASE)],
           fill=INK, width=2)
    d.polygon([(ARROW_X, ARROW_TIP),
               (ARROW_X - ARROW_HALF, ARROW_HEAD_BASE),
               (ARROW_X + ARROW_HALF, ARROW_HEAD_BASE)], fill=INK)
    for box, label in ((BOX1, "Reader opens doc"),
                       (BOX2, "Diagram renders")):
        cx = (box[0] + box[2]) // 2
        cy = (box[1] + box[3]) // 2
        d.text((cx, cy), label, font=font, fill=INK, anchor="mm")
    im.save(OUT)
    print("wrote %s (%dx%d) font=%s" % (OUT, W, H, font_path))
    tall = draw_tall(font)
    tall.save(OUT_TALL)
    print("wrote %s (%dx%d) font=%s" % (OUT_TALL, TALL_W, TALL_H, font_path))


# Huge-rendered-image companion (issue #323, PR #340 owner request): same
# column width and style as the standard seed, but a genuinely complex
# 26-node flowchart mirroring test_cases/plugin_mermaid_tall.md
# node-for-node: full-width spine boxes, two-column branch pairs, decision
# diamonds, and a right-edge bypass rail collecting the Deny/Serve/Skip
# side branches into the terminal node. All coordinates are explicit
# constants — fully deterministic (fixed geometry, labels, font, colors;
# Pillow writes no timestamps).
TALL_W, TALL_H = 476, 3140

_T_FULL_X0, _T_FULL_X1, _T_FULL_H = 53, 427, 88
_T_DIA_CX, _T_DIA_HW, _T_DIA_HH = 238, 130, 52
_T_RAIL_X = 466
_T_ARROW_H = 15

# Full-width spine boxes: (label, top).
_T_FULL = [
    ("Request arrives", 36),
    ("Plan layout", 640),
    ("Join text runs", 1150),
    ("Apply styles", 1300),
    ("Paint viewport", 1620),
    ("Hash fence source", 1930),
    ("Composite layers", 2240),
    ("Join overlays", 2550),
    ("Track scroll", 2700),
    ("Idle await input", 3000),
]

# Branch boxes: (label, x0, x1, top, h).
_T_BRANCH = [
    ("Deny", 300, 448, 300, 64),
    ("Serve cached", 300, 448, 560, 64),
    ("Tokenize blocks", 28, 230, 790, 84),
    ("Index lines", 246, 448, 790, 84),
    ("Split bidi runs", 28, 230, 936, 84),
    ("Find code spans", 246, 448, 936, 84),
    ("Decode images", 316, 460, 1530, 56),
    ("Skip plugins", 300, 448, 1860, 64),
    ("Seed cache hit", 28, 230, 2080, 84),
    ("Render fallback", 246, 448, 2080, 84),
    ("Selection layer", 28, 230, 2390, 84),
    ("Find markers", 246, 448, 2390, 84),
]

# Decision diamonds: (label, center_y).
_T_DIA = [
    ("Auth check", 230),
    ("Cache lookup", 480),
    ("Images?", 1500),
    ("Mermaid?", 1820),
]

# Vertical arrows: (x, y0, y_tip).
_T_VLINES = [
    (238, 124, 178),
    (238, 282, 428),
    (238, 532, 640),
    (129, 728, 790), (347, 728, 790),
    (129, 874, 936), (347, 874, 936),
    (129, 1020, 1150), (347, 1020, 1150),
    (238, 1238, 1300),
    (238, 1388, 1448),
    (238, 1552, 1620),
    (388, 1586, 1620),
    (238, 1708, 1768),
    (238, 1872, 1930),
    (129, 2018, 2080), (347, 2018, 2080),
    (129, 2164, 2240), (347, 2164, 2240),
    (129, 2328, 2390), (347, 2328, 2390),
    (129, 2474, 2550), (347, 2474, 2550),
    (238, 2638, 2700),
    (238, 2788, 3000),
]

# Elbow edges (horizontal out of a diamond, then down into a box top):
# (x0, y0, x1, y_tip).
_T_ELBOWS = [
    (368, 230, 420, 300),  # deny -> Deny
    (368, 480, 420, 560),  # hit -> Serve cached
    (368, 1500, 400, 1530),  # yes -> Decode images
    (368, 1820, 420, 1860),  # no -> Skip plugins
]

# Bypass rail: side branches meet it at these y values (x=448 -> rail),
# run down the right edge, and rejoin the terminal box top.
_T_RAIL_JOINS = (332, 592, 1892)

# Edge labels: (text, x, y), drawn left-anchored past the edge.
_T_EDGE_LABELS = [
    ("allow", 246, 352),
    ("deny", 376, 212),
    ("hit", 376, 462),
    ("miss", 246, 584),
    ("yes", 372, 1482),
    ("no", 246, 1584),
    ("yes", 246, 1899),
    ("no", 376, 1802),
]


def _t_arrow(d, x, y_tip):
    base = y_tip - _T_ARROW_H
    d.polygon([(x, y_tip),
               (x - ARROW_HALF, base),
               (x + ARROW_HALF, base)], fill=INK)


def draw_tall(font):
    font_branch, _ = load_font(20)
    font_dia, _ = load_font(22)
    font_edge, _ = load_font(16)
    im = Image.new("RGB", (TALL_W, TALL_H), BG)
    d = ImageDraw.Draw(im)
    for label, top in _T_FULL:
        d.rectangle((_T_FULL_X0, top, _T_FULL_X1, top + _T_FULL_H),
                    fill=FILL, outline=EDGE, width=EDGE_W)
        d.text(((_T_FULL_X0 + _T_FULL_X1) // 2, top + _T_FULL_H // 2),
               label, font=font, fill=INK, anchor="mm")
    for label, x0, x1, top, h in _T_BRANCH:
        d.rectangle((x0, top, x1, top + h),
                    fill=FILL, outline=EDGE, width=EDGE_W)
        d.text(((x0 + x1) // 2, top + h // 2),
               label, font=font_branch, fill=INK, anchor="mm")
    for label, cy in _T_DIA:
        d.polygon([(_T_DIA_CX, cy - _T_DIA_HH),
                   (_T_DIA_CX + _T_DIA_HW, cy),
                   (_T_DIA_CX, cy + _T_DIA_HH),
                   (_T_DIA_CX - _T_DIA_HW, cy)],
                  fill=FILL, outline=EDGE, width=EDGE_W)
        d.text((_T_DIA_CX, cy), label, font=font_dia, fill=INK, anchor="mm")
    for x, y0, y_tip in _T_VLINES:
        d.line([(x, y0), (x, y_tip - _T_ARROW_H)], fill=INK, width=2)
        _t_arrow(d, x, y_tip)
    for x0, y0, x1, y_tip in _T_ELBOWS:
        d.line([(x0, y0), (x1, y0), (x1, y_tip - _T_ARROW_H)],
               fill=INK, width=2)
        _t_arrow(d, x1, y_tip)
    for y in _T_RAIL_JOINS:
        d.line([(448, y), (_T_RAIL_X, y)], fill=INK, width=2)
    d.line([(_T_RAIL_X, _T_RAIL_JOINS[0]),
            (_T_RAIL_X, 2960), (350, 2960), (350, 3000 - _T_ARROW_H)],
           fill=INK, width=2)
    _t_arrow(d, 350, 3000)
    for text, x, y in _T_EDGE_LABELS:
        d.text((x, y), text, font=font_edge, fill=INK, anchor="lm")
    return im


if __name__ == "__main__":
    main()
