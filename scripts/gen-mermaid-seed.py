#!/usr/bin/env python3
"""Regenerate test_cases/assets/mermaid-seed.png (issue #323).

The seed is a faithful static mimic of a real `flowchart TD` mermaid render
of the test_cases/plugin_mermaid.md fixture ("Reader opens doc" -->
"Diagram renders"): vertical layout, two lavender-filled purple-bordered
boxes, vertical arrow, smooth sans-serif labels. No mermaid renderer binary
exists in this env, so this draws the reference geometry directly.

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


if __name__ == "__main__":
    main()
