#!/usr/bin/env python3
"""Regenerate plugin seed PNGs (issues #330/#329/#328/#326/#327).

mathjax seeds are genuine MathJax-engine renders of their
test_cases/plugin_mathjax*.md fixture fence sources (MathJax 3.2.1 SVG
output via a pinned npm bootstrap, rasterized in headless Chrome;
*_seed functions fail loudly without node/npm/Chrome). Remaining seeds
are faithful static mimics of real renderer output: d2/graphviz/plantuml
draw the fixture's diagram (labels mirror the fixture), math draws the
fixture's formula typeset in STIX. Tall/wide companions
(*-seed-tall.png, *-seed-wide.png) mirror the tall/wide fixtures
node-for-node the same way; math-seed.png draws the simplified fixture
formula, *-seed-complex.png the complex companions.
Synthetic-but-plausible stand-ins (no d2/dot/plantuml binaries in this
env); the screenshot path proven (stat-exists seed -> ready -> stock
image decode) is production, per suite practice
(cf. scripts/gen-mermaid-seed.py).

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
    # Fixture test_cases/plugin_math.md (owner: simpler formula): E = mc^2.
    im = _typeset([
        ("E = mc", "body"), ("2", "sup"),
    ])
    return im, "math-seed.png"


def _real_mathjax_render(fixture_md, out_name):
    # Genuine engine render (round-two revision: seeds are real engine
    # output, never Pillow mimics). Bootstraps the pinned mathjax-full
    # npm package into a temp dir, typesets the fixture tex to SVG with
    # the real MathJax engine, screenshots headless Chrome, and autocrops
    # to content. Needs node+npm and Chrome; fails loudly without them.
    # Verified deterministic (reruns pixel-identical) for 3.2.1.
    import shutil
    import subprocess
    import tempfile
    npm_pkg = "mathjax-full@3.2.1"
    for bin_name in ("node", "npm"):
        if shutil.which(bin_name) is None:
            sys.exit("FAIL: %s not found (needed for %s)" %
                     (bin_name, out_name))
    chrome = (os.environ.get("CHROME_BIN") or
              shutil.which("google-chrome") or
              shutil.which("chromium") or shutil.which("chromium-browser") or
              "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if not (os.path.exists(chrome) if os.sep in chrome else
            shutil.which(chrome)):
        sys.exit("FAIL: Chrome not found (needed for %s)" % out_name)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    lines = open(os.path.join(root, fixture_md)).read().split('\n')
    start = next(i for i, l in enumerate(lines)
                 if l.lstrip().startswith('```') and
                 l.lstrip()[3:].strip().split(' ')[:1] == ['mathjax'])
    end = next(i for i in range(start + 1, len(lines))
               if lines[i].lstrip().startswith('```'))
    tex = '\n'.join(lines[start + 1:end])
    workdir = tempfile.mkdtemp()
    pkgdir = os.path.join(workdir, "pkg")
    os.mkdir(pkgdir)
    r = subprocess.run(["npm", "init", "-y"], cwd=pkgdir,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("FAIL: npm init: %s" % (r.stderr or '').strip())
    r = subprocess.run(["npm", "install", npm_pkg], cwd=pkgdir,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("FAIL: npm install %s: %s" %
                 (npm_pkg, (r.stderr or '').strip()))
    mj = os.path.join(pkgdir, "node_modules", "mathjax-full", "js")
    render_js = (
        "const fs = require('fs');\n"
        "const { mathjax } = require(%s);\n"
        "const { TeX } = require(%s);\n"
        "const { SVG } = require(%s);\n"
        "const { liteAdaptor } = require(%s);\n"
        "const { RegisterHTMLHandler } = require(%s);\n"
        "const adaptor = liteAdaptor();\n"
        "RegisterHTMLHandler(adaptor);\n"
        "const tex = new TeX({ packages: ['base', 'ams'] });\n"
        "const svg = new SVG({ fontCache: 'local' });\n"
        "const doc = mathjax.document('', "
        "{ InputJax: tex, OutputJax: svg });\n"
        "const src = fs.readFileSync(%s, 'utf8');\n"
        "const node = doc.convert(src, { display: true });\n"
        "const body = '<div id=\"f\" style=\"background:white\">' +\n"
        "  adaptor.innerHTML(node) + '</div>';\n"
        "const html = '<!DOCTYPE html><html><head>"
        "<meta charset=\"utf-8\">' +\n"
        "  '<style>html,body{margin:0;padding:0;background:#fff;}' +\n"
        "  '#f{display:inline-block;padding:28px;font-size:44px;color:#333;}' +\n"
        "  '</style></head><body>' + body + '</body></html>';\n"
        "fs.writeFileSync(%s, html);\n" % tuple(
            __import__('json').dumps(p) for p in (
                os.path.join(mj, "mathjax.js"),
                os.path.join(mj, "input", "tex.js"),
                os.path.join(mj, "output", "svg.js"),
                os.path.join(mj, "adaptors", "liteAdaptor.js"),
                os.path.join(mj, "handlers", "html.js"),
                os.path.join(workdir, "formula.tex"),
                os.path.join(workdir, "formula.html"),
            )))
    with open(os.path.join(workdir, "formula.tex"), 'w') as f:
        f.write(tex)
    with open(os.path.join(workdir, "render.js"), 'w') as f:
        f.write(render_js)
    r = subprocess.run(["node", "render.js"], cwd=workdir,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("FAIL: mathjax render %s: %s" %
                 (fixture_md, (r.stderr or '').strip()))
    shot = os.path.join(workdir, "shot.png")
    page = "file://" + os.path.join(workdir, "formula.html")
    r = subprocess.run([chrome, "--headless", "--disable-gpu",
                        "--no-sandbox", "--screenshot=" + shot,
                        "--window-size=1200,500", "--hide-scrollbars",
                        page], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(shot):
        sys.exit("FAIL: chrome screenshot %s: %s" %
                 (fixture_md, (r.stderr or '').strip()))
    from PIL import ImageChops
    im = Image.open(shot).convert('RGB')
    bg = Image.new('RGB', im.size, (255, 255, 255))
    bbox = ImageChops.difference(im, bg).getbbox()
    if bbox is None:
        sys.exit("FAIL: empty mathjax render for %s" % fixture_md)
    pad = 28
    x0, y0, x1, y1 = bbox
    box = (max(0, x0 - pad), max(0, y0 - pad),
           min(im.width, x1 + pad), min(im.height, y1 + pad))
    out = os.path.join(os.getcwd(), out_name)
    im.crop(box).save(out)
    shutil.rmtree(workdir, ignore_errors=True)
    return Image.open(out), out_name


def mathjax_seed():
    # Fixture: a^2 + b^2 = c^2. Genuine MathJax 3.2.1 output.
    return _real_mathjax_render("test_cases/plugin_mathjax.md",
                                "mathjax-seed.png")


# --- Tall/wide companions (owner request 2026-09-12, mimicking the mermaid
# 4g/4h cases): rank-based grid layout computed from the node/edge tables
# below, mirroring each tall/wide fixture node-for-node. Fixed inputs give
# fixed pixels (explicit integer geometry; Pillow writes no timestamps).
# Tall stacks ranks top-down (multi-node ranks sit side-by-side, joined by
# elbows); wide runs the chain left-to-right with a branch lane plus a
# collection rail into the terminal node (mermaid-wide rail precedent).
# Styles reuse the base seeds: rectangles for d2, ellipses for graphviz
# (dot's default node shape), sequence actors/arrows for PlantUML.


def _shape_box(d, rect, label, font, shape):
    if shape == "ellipse":
        d.ellipse(rect, fill=FILL, outline=EDGE, width=EDGE_W)
    else:
        d.rectangle(rect, fill=FILL, outline=EDGE, width=EDGE_W)
    center_text(d, (rect[0] + rect[2]) // 2, (rect[1] + rect[3]) // 2,
                label, font)


def _varrow(d, x, y0, y1):
    # Vertical arrow down from (x, y0) to (x, y1).
    d.line([(x, y0), (x, y1 - 12)], fill=INK, width=2)
    d.polygon([(x, y1), (x - 9, y1 - 12), (x + 9, y1 - 12)], fill=INK)


def _arrow_up(d, x, y0, y1):
    # Vertical arrow up from (x, y0) to (x, y1).
    d.line([(x, y0), (x, y1 + 12)], fill=INK, width=2)
    d.polygon([(x, y1), (x - 9, y1 + 12), (x + 9, y1 + 12)], fill=INK)


def _elbow(d, x0, y0, x1, y1, jog=14):
    # Parent bottom (x0, y0) to child top (x1, y1): horizontal jog below
    # the parent, then down into the child.
    jy = y0 + jog
    d.line([(x0, y0), (x0, jy), (x1, jy), (x1, y1 - 12)], fill=INK, width=2)
    d.polygon([(x1, y1), (x1 - 9, y1 - 12), (x1 + 9, y1 - 12)], fill=INK)


# Tall pipeline fixture node sets (test_cases/plugin_{d2,graphviz}_tall.md):
# 22 nodes in 18 ranks; rank 5 fans out to four classifiers, rank 8 to
# three inline kinds, rejoining at para/image. Edges mirror the fixture.
_TALL_RANKS = [
    ["Reader Opens Document"],
    ["Memory Map File"],
    ["Scan Line Breaks"],
    ["Index Lines"],
    ["Classify Blocks"],
    ["Fenced Code", "GFM Tables", "Block Quotes", "Bullet Lists"],
    ["Paragraph Flow"],
    ["Inline Spans"],
    ["Emphasis Pairs", "Links Autolinks", "Code Spans"],
    ["Image Placeholders"],
    ["Layout Viewport"],
    ["Virtualized Window"],
    ["Paint Commands"],
    ["Scroll Position"],
    ["Find Matches"],
    ["Selection Range"],
    ["Copy To Clipboard"],
    ["Idle Await Input"],
]
# (parent_label, child_label, jog) for non-vertical edges; verticals are
# derived from rank adjacency (same-lane consecutive ranks).
_TALL_FAN = [
    ("Classify Blocks", "Fenced Code", 14),
    ("Classify Blocks", "GFM Tables", 24),
    ("Classify Blocks", "Block Quotes", 34),
    ("Classify Blocks", "Bullet Lists", 44),
    ("Fenced Code", "Paragraph Flow", 14),
    ("GFM Tables", "Paragraph Flow", 24),
    ("Block Quotes", "Paragraph Flow", 34),
    ("Bullet Lists", "Paragraph Flow", 44),
    ("Inline Spans", "Emphasis Pairs", 14),
    ("Inline Spans", "Links Autolinks", 24),
    ("Inline Spans", "Code Spans", 34),
    ("Emphasis Pairs", "Image Placeholders", 14),
    ("Links Autolinks", "Image Placeholders", 24),
    ("Code Spans", "Image Placeholders", 34),
]

TALL_W, TALL_H = 476, 3008
_TALL_TOP, _TALL_PITCH, _TALL_BOXH = 40, 168, 72


def _tall_layout(shape):
    # Returns (boxes, edges): boxes maps label -> rect, edges is a list of
    # ("v", x, y0, y1) verticals and ("e", x0, y0, x1, y1, jog) elbows.
    boxes = {}
    for r, rank in enumerate(_TALL_RANKS):
        y = _TALL_TOP + r * _TALL_PITCH
        if len(rank) == 1:
            boxes[rank[0]] = (68, y, 408, y + _TALL_BOXH)
        elif len(rank) == 4:
            for k, label in enumerate(rank):
                x0 = 14 + k * 114
                boxes[label] = (x0, y, x0 + 106, y + _TALL_BOXH)
        else:
            for k, label in enumerate(rank):
                x0 = 10 + k * 158
                boxes[label] = (x0, y, x0 + 140, y + _TALL_BOXH)
    # Center x per label for edge routing.
    cx = {label: (r[0] + r[2]) // 2 for label, r in boxes.items()}
    # Rank index per label for vertical derivation.
    rank_of = {}
    for r, rank in enumerate(_TALL_RANKS):
        for label in rank:
            rank_of[label] = r
    edges = []
    fan = {(a, b): jog for a, b, jog in _TALL_FAN}
    for r in range(len(_TALL_RANKS) - 1):
        for a in _TALL_RANKS[r]:
            for b in _TALL_RANKS[r + 1]:
                y0 = boxes[a][3]
                y1 = boxes[b][1]
                if (a, b) in fan:
                    edges.append(("e", cx[a], y0, cx[b], y1, fan[(a, b)]))
                elif cx[a] == cx[b]:
                    edges.append(("v", cx[a], y0, y1))
    return boxes, edges


def _draw_tall(shape):
    font = load_font(ARIAL, 20)
    font_small = load_font(ARIAL, 15)
    im = Image.new("RGB", (TALL_W, TALL_H), BG)
    d = ImageDraw.Draw(im)
    boxes, edges = _tall_layout(shape)
    for r, rank in enumerate(_TALL_RANKS):
        f = font if len(rank) == 1 else font_small
        for label in rank:
            _shape_box(d, boxes[label], label, f, shape)
    for e in edges:
        if e[0] == "v":
            _, x, y0, y1 = e
            _varrow(d, x, y0, y1)
        else:
            _, x0, y0, x1, y1, jog = e
            _elbow(d, x0, y0, x1, y1, jog)
    return im


def d2_seed_tall():
    # Fixture test_cases/plugin_d2_tall.md (direction: down reader pipeline).
    return _draw_tall("rect"), "d2-seed-tall.png"


def graphviz_seed_tall():
    # Same node set in dot idiom; ellipses are dot's default node shape.
    return _draw_tall("ellipse"), "graphviz-seed-tall.png"


# Wide pipeline fixture node sets (test_cases/plugin_{d2,graphviz}_wide.md):
# 13-column main chain plus deny/serve on the branch lane, collected by a
# bottom rail into the terminal node.
_WIDE_CHAIN = ["Request In", "Auth Check", "Cache Lookup", "Plan Layout",
               "Tokenize", "Index", "Bidi Split", "Code Spans", "Join Runs",
               "Apply Styles", "Images", "Paint", "Idle"]
_WIDE_BRANCH = [("Auth Check", "Deny"), ("Cache Lookup", "Serve Hit")]
WIDE_W, WIDE_H = 2000, 600
_WIDE_X0, _WIDE_PITCH, _WIDE_BOXW = 40, 150, 120
_WIDE_MAIN_Y, _WIDE_BRANCH_Y, _WIDE_RAIL_Y = 120, 400, 530
_WIDE_BOXH = 72


def _wide_layout(shape):
    boxes = {}
    for k, label in enumerate(_WIDE_CHAIN):
        x = _WIDE_X0 + k * _WIDE_PITCH
        boxes[label] = (x, _WIDE_MAIN_Y, x + _WIDE_BOXW,
                        _WIDE_MAIN_Y + _WIDE_BOXH)
    cx = {label: (r[0] + r[2]) // 2 for label, r in boxes.items()}
    branch = {}
    for parent, label in _WIDE_BRANCH:
        branch[label] = (cx[parent] - _WIDE_BOXW // 2, _WIDE_BRANCH_Y,
                         cx[parent] + _WIDE_BOXW // 2,
                         _WIDE_BRANCH_Y + _WIDE_BOXH)
    return boxes, branch


def _draw_wide(shape):
    font = load_font(ARIAL, 17)
    im = Image.new("RGB", (WIDE_W, WIDE_H), BG)
    d = ImageDraw.Draw(im)
    boxes, branch = _wide_layout(shape)
    for label, rect in boxes.items():
        _shape_box(d, rect, label, font, shape)
    for label, rect in branch.items():
        _shape_box(d, rect, label, font, shape)
    cy = _WIDE_MAIN_Y + _WIDE_BOXH // 2
    for k in range(len(_WIDE_CHAIN) - 1):
        r0 = boxes[_WIDE_CHAIN[k]]
        arrow_h(d, r0[2], cy, boxes[_WIDE_CHAIN[k + 1]][0])
    for parent, label in _WIDE_BRANCH:
        x = (boxes[parent][0] + boxes[parent][2]) // 2
        _varrow(d, x, boxes[parent][3], branch[label][1])
        d.line([(x, branch[label][3]), (x, _WIDE_RAIL_Y)],
               fill=INK, width=2)
    idle = boxes["Idle"]
    idle_cx = (idle[0] + idle[2]) // 2
    first_x = (boxes[_WIDE_BRANCH[0][0]][0] +
               boxes[_WIDE_BRANCH[0][0]][2]) // 2
    d.line([(first_x, _WIDE_RAIL_Y), (idle_cx, _WIDE_RAIL_Y)],
           fill=INK, width=2)
    _arrow_up(d, idle_cx, _WIDE_RAIL_Y, idle[3])
    return im


def d2_seed_wide():
    # Fixture test_cases/plugin_d2_wide.md (direction: right pipeline).
    return _draw_wide("rect"), "d2-seed-wide.png"


def graphviz_seed_wide():
    # Same node set in dot idiom (rankdir=LR); ellipses are dot's default.
    return _draw_wide("ellipse"), "graphviz-seed-wide.png"


# PlantUML tall/wide companions use the sequence-diagram idiom of the base
# seed (participant heads, dashed lifelines, message arrows): tall is a long
# 14-message exchange (lifelines run the full height), wide spreads eight
# participants across the 2000px sheet.
_PLANT_TALL_MSGS = [
    ("Reader", "Mmap", "zero-copy open"),
    ("Mmap", "Blocks", "byte window"),
    ("Blocks", "Para", "other lines"),
    ("Para", "Blocks", "styled runs"),
    ("Blocks", "Para", "cell text"),
    ("Para", "Mmap", "sized boxes"),
    ("Mmap", "Reader", "frame ready"),
    ("Reader", "Blocks", "find query"),
    ("Blocks", "Para", "match text"),
    ("Para", "Reader", "match range"),
    ("Reader", "Mmap", "copy bytes"),
    ("Mmap", "Blocks", "reindex"),
    ("Blocks", "Para", "tokenize"),
    ("Para", "Reader", "await input"),
]
_PLANT_TALL_PARTS = ["Reader", "Mmap", "Blocks", "Para"]
_PLANT_WIDE_PARTS = ["In", "Auth", "Cache", "Plan", "Tok", "Join", "Paint",
                     "Idle"]
_PLANT_WIDE_MSGS = [
    ("In", "Auth", "request"),
    ("Auth", "Cache", "allow"),
    ("Cache", "Plan", "miss"),
    ("Plan", "Tok", "split"),
    ("Tok", "Join", "runs"),
    ("Join", "Paint", "draw"),
    ("Paint", "Idle", "ready"),
]


def _plant_heads(d, parts, x_of, font, top=28, h=40):
    for p in parts:
        x = x_of[p]
        d.rectangle((x - 70, top, x + 70, top + h), fill=FILL,
                    outline=EDGE, width=EDGE_W)
        center_text(d, x, top + h // 2, p, font)


def _plant_lifeline(d, x, y0, y1):
    y = y0
    while y < y1:
        d.line([(x, y), (x, min(y + 8, y1))], fill=INK, width=2)
        y += 16


def _plant_msg(d, x0, x1, y, label, font_msg):
    if x1 >= x0:
        d.line([(x0, y), (x1 - 12, y)], fill=INK, width=2)
        d.polygon([(x1, y), (x1 - 12, y - 9), (x1 - 12, y + 9)], fill=INK)
        d.text((x0 + 8, y - 28), label, font=font_msg, fill=INK,
               anchor="lm")
    else:
        d.line([(x0, y), (x1 + 12, y)], fill=INK, width=2)
        d.polygon([(x1, y), (x1 + 12, y - 9), (x1 + 12, y + 9)], fill=INK)
        d.text((x1 + 8, y - 28), label, font=font_msg, fill=INK,
               anchor="lm")


def plantuml_seed_tall():
    # Fixture test_cases/plugin_plantuml_tall.md (14-message exchange
    # across four participants).
    W, H = 476, 2080
    parts = _PLANT_TALL_PARTS
    xs = [60, 180, 300, 420]
    x_of = dict(zip(parts, xs))
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    font = load_font(ARIAL, 16)
    font_msg = load_font(ARIAL, 13)
    for p in parts:
        x = x_of[p]
        d.rectangle((x - 48, 28, x + 48, 68), fill=FILL,
                    outline=EDGE, width=EDGE_W)
        center_text(d, x, 48, p, font)
    for x in xs:
        _plant_lifeline(d, x, 80, H - 24)
    y = 200
    for a, b, label in _PLANT_TALL_MSGS:
        _plant_msg(d, x_of[a], x_of[b], y, label, font_msg)
        y += 130
    return im, "plantuml-seed-tall.png"


def plantuml_seed_wide():
    # Fixture test_cases/plugin_plantuml_wide.md (eight participants).
    W, H = 2000, 600
    parts = _PLANT_WIDE_PARTS
    n = len(parts)
    xs = [110 + i * (1780 // (n - 1)) for i in range(n)]
    x_of = dict(zip(parts, xs))
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    font = load_font(ARIAL, 22)
    font_msg = load_font(ARIAL, 16)
    _plant_heads(d, parts, x_of, font)
    for x in xs:
        _plant_lifeline(d, x, 80, H - 24)
    y = 190
    for a, b, label in _PLANT_WIDE_MSGS:
        _plant_msg(d, x_of[a], x_of[b], y, label, font_msg)
        y += 56
    return im, "plantuml-seed-wide.png"


def math_seed_complex():
    # Fixture test_cases/plugin_math_complex.md: sum of squares.
    im = _typeset([
        ("\u2211", "big"), ("k=1", "sub"), ("n", "sup"),
        (" k", "body"), ("2", "sup"),
        (" = n(n+1)(2n+1)/6", "body"),
    ])
    return im, "math-seed-complex.png"


def mathjax_seed_complex():
    # Fixture test_cases/plugin_mathjax_complex.md: Gaussian integral.
    # Genuine MathJax 3.2.1 output (display-style integral limits).
    return _real_mathjax_render("test_cases/plugin_mathjax_complex.md",
                                "mathjax-seed-complex.png")


def main():
    makers = [d2_seed, graphviz_seed, plantuml_seed, math_seed, mathjax_seed,
              d2_seed_tall, d2_seed_wide, graphviz_seed_tall,
              graphviz_seed_wide, plantuml_seed_tall, plantuml_seed_wide,
              math_seed_complex, mathjax_seed_complex]
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
