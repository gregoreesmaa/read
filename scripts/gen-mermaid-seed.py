#!/usr/bin/env python3
"""Regenerate mermaid seed PNGs (issue #323).

mermaid-seed.png is a faithful static mimic of a real `flowchart TD`
mermaid render of the test_cases/plugin_mermaid.md fixture ("Reader opens
doc" --> "Diagram renders"): vertical layout, two lavender-filled
purple-bordered boxes, vertical arrow, smooth sans-serif labels.

mermaid-seed-tall.png is the huge-rendered-image companion for the
test_cases/plugin_mermaid_tall.md fixture: same style and column width,
but ~2000px tall (eight stacked boxes), proving oversize-image geometry
(clamp/fit, scrollbar/height math, no blowup). No mermaid renderer binary
exists in this env, so both draw reference geometry directly.

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
# column width and style as the standard seed, but TALL_H px tall — eight
# stacked boxes with arrows, fully deterministic (fixed geometry, labels,
# font, colors; Pillow writes no timestamps).
TALL_W, TALL_H = 476, 2000
TALL_BOXES = 8
TALL_BOX_H = 110
TALL_TOP = 54
TALL_STEP = 230
TALL_X0, TALL_X1 = 53, 427


def draw_tall(font):
    im = Image.new("RGB", (TALL_W, TALL_H), BG)
    d = ImageDraw.Draw(im)
    tops = [TALL_TOP + s * TALL_STEP for s in range(TALL_BOXES)]
    for top in tops:
        d.rectangle((TALL_X0, top, TALL_X1, top + TALL_BOX_H),
                    fill=FILL, outline=EDGE, width=EDGE_W)
    for top, nxt in zip(tops, tops[1:]):
        base = nxt - 16
        d.line([(ARROW_X, top + TALL_BOX_H + 1), (ARROW_X, base)],
               fill=INK, width=2)
        d.polygon([(ARROW_X, nxt - 1),
                   (ARROW_X - ARROW_HALF, base),
                   (ARROW_X + ARROW_HALF, base)], fill=INK)
    for n, top in enumerate(tops, 1):
        cx = (TALL_X0 + TALL_X1) // 2
        d.text((cx, top + TALL_BOX_H // 2), "Tall step %d" % n,
               font=font, fill=INK, anchor="mm")
    return im


if __name__ == "__main__":
    main()
