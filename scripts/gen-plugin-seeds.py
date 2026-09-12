#!/usr/bin/env python3
"""Regenerate plugin seed PNGs (issues #330/#329/#328/#326/#327).

Each seed is a faithful static mimic of a real renderer output for its
test_cases/plugin_*.md fixture: d2/graphviz/plantuml draw the fixture's
two-node diagram (labels mirror the fixture), math/mathjax draw the
fixture's formula typeset in STIX. Synthetic-but-plausible stand-ins
(no d2/dot/plantuml/katex binaries in this env); the screenshot path
proven (stat-exists seed -> ready -> stock image decode) is production,
per suite practice (cf. scripts/gen-mermaid-seed.py).

Requires Pillow (fixture generation only, never ships): pip install pillow.
Usage:  python3 scripts/gen-plugin-seeds.py
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("FAIL: gen-plugin-seeds needs Pillow (pip install pillow)")

BG = (255, 255, 255)
FILL = (236, 236, 254)  # lavender box fill (#ececfe)
EDGE = (142, 114, 213)  # purple box border (#8e72d5)
INK = (51, 51, 51)  # labels + arrows (#333333)
EDGE_W = 2

ARIAL = "/System/Library/Fonts/Supplemental/Arial.ttf"
STIX = "/System/Library/Fonts/Supplemental/STIXGeneral.otf"


def load_font(path, size):
    if not os.path.exists(path):
        sys.exit("FAIL: font missing: %s" % path)
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        sys.exit("FAIL: cannot load font: %s" % path)


def arrow_h(d, x0, y, x_tip, half=9, width=2):
    d.line([(x0, y), (x_tip - 12, y)], fill=INK, width=width)
    d.polygon([(x_tip, y), (x_tip - 12, y - half),
               (x_tip - 12, y + half)], fill=INK)


def center_text(d, cx, cy, s, font):
    d.text((cx, cy), s, font=font, fill=INK, anchor="mm")


def d2_seed():
    # Fixture: direction:right, reader -> diagram: opens doc.
    W, H = 476, 280
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    font = load_font(ARIAL, 24)
    font_edge = load_font(ARIAL, 16)
    b1 = (28, 96, 180, 184)
    b2 = (296, 96, 448, 184)
    d.rectangle(b1, fill=FILL, outline=EDGE, width=EDGE_W)
    d.rectangle(b2, fill=FILL, outline=EDGE, width=EDGE_W)
    center_text(d, 104, 140, "reader", font)
    center_text(d, 372, 140, "diagram", font)
    arrow_h(d, 180, 140, 296)
    center_text(d, 238, 112, "opens doc", font_edge)
    return im, "d2-seed.png"


def graphviz_seed():
    # Fixture (dot): rankdir=LR, reader -> diagram. Ellipse nodes are
    # graphviz's default node shape.
    W, H = 476, 280
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    font = load_font(ARIAL, 24)
    e1 = (28, 96, 180, 184)
    e2 = (296, 96, 448, 184)
    d.ellipse(e1, fill=FILL, outline=EDGE, width=EDGE_W)
    d.ellipse(e2, fill=FILL, outline=EDGE, width=EDGE_W)
    center_text(d, 104, 140, "reader", font)
    center_text(d, 372, 140, "diagram", font)
    arrow_h(d, 180, 140, 296)
    return im, "graphviz-seed.png"


def plantuml_seed():
    # Fixture: @startuml / Reader -> Diagram : opens doc / @enduml.
    # Sequence-diagram mimic: participant heads, dashed lifelines, one
    # message arrow carrying the fixture's label.
    W, H = 476, 320
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    font = load_font(ARIAL, 22)
    font_msg = load_font(ARIAL, 16)
    p1 = (40, 28, 180, 68)
    p2 = (296, 28, 436, 68)
    d.rectangle(p1, fill=FILL, outline=EDGE, width=EDGE_W)
    d.rectangle(p2, fill=FILL, outline=EDGE, width=EDGE_W)
    center_text(d, 110, 48, "Reader", font)
    center_text(d, 366, 48, "Diagram", font)
    for x in (110, 366):
        y = 80
        while y < 300:
            d.line([(x, y), (x, min(y + 8, 300))], fill=INK, width=2)
            y += 16
    d.line([(110, 160), (354, 160)], fill=INK, width=2)
    d.polygon([(366, 160), (354, 151), (354, 169)], fill=INK)
    d.text((118, 132), "opens doc", font=font_msg, fill=INK, anchor="lm")
    return im, "plantuml-seed.png"


def _typeset(formula_runs, size=44, small=30, pad=28):
    """Lay out (text, kind) runs on explicit baselines; kind in
    big/body/sup/sub. Sup/sub baselines shift off the body baseline by
    measured ink metrics (never font-metric anchors). Returns image."""
    big = load_font(STIX, size)
    body = load_font(STIX, size - 6)
    script = load_font(STIX, small)
    tmp = Image.new("RGB", (8, 8), BG)
    t = ImageDraw.Draw(tmp)

    def ink(f, s):
        # anchor="ls" so the box is baseline-relative: top <= 0 above,
        # bottom >= 0 below (the default "la" measures off the ascender
        # line, which silently negates every shift).
        l, tp, r, b = t.textbbox((0, 0), s, font=f, anchor="ls")
        return r - l, -tp, b  # width, ascent, descent off baseline

    _, body_asc, body_desc = ink(body, "x")
    _, big_asc, big_desc = ink(big, "\u222b")
    _, script_asc, script_desc = ink(script, "x")
    shift_up = int(body_asc * 0.8)
    shift_down = int(body_desc + script_asc * 0.4)
    top_needed = max(big_asc, body_asc, shift_up + script_asc)
    bot_needed = max(big_desc, body_desc, shift_down + script_desc)
    widths = [ink(script if k in ("sup", "sub")
                  else (big if k == "big" else body), s)[0]
              for s, k in formula_runs]
    y0 = pad + top_needed
    W = sum(widths) + pad * 2 + 8 * len(formula_runs)
    H = y0 + bot_needed + pad
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    x = pad
    for (text, kind), w in zip(formula_runs, widths):
        f = script if kind in ("sup", "sub") else (big if kind == "big" else body)
        y = y0 - shift_up if kind == "sup" else (
            y0 + shift_down if kind == "sub" else y0)
        d.text((x, y), text, font=f, fill=INK, anchor="ls")
        x += w + 8
    return im


def math_seed():
    # Fixture: \int_{0}^{\infty} e^{-x} dx = 1
    im = _typeset([
        ("\u222b", "big"), ("0", "sub"), ("\u221e", "sup"),
        ("e", "body"), ("\u2212x", "sup"), ("dx = 1", "body"),
    ])
    return im, "math-seed.png"


def mathjax_seed():
    # Fixture: a^2 + b^2 = c^2
    im = _typeset([
        ("a", "body"), ("2", "sup"), ("+ b", "body"), ("2", "sup"),
        ("= c", "body"), ("2", "sup"),
    ])
    return im, "mathjax-seed.png"


def main():
    makers = [d2_seed, graphviz_seed, plantuml_seed, math_seed, mathjax_seed]
    if len(sys.argv) > 1:
        wanted = set(sys.argv[1:])
        makers = [m for m in makers if m.__name__ in wanted]
    for make in makers:
        im, name = make()
        out = os.path.join(os.getcwd(), name)
        im.save(out)
        print("wrote %s (%dx%d)" % (out, im.width, im.height))


if __name__ == "__main__":
    main()
