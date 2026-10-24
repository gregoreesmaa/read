#!/bin/sh
# Retina text coverage (2026-10 batch-clip regression).
#
# The #389 GPU batcher hoisted one SetFillColor per color group but shared a
# single clip across the group's runs; ClipToMask INTERSECTS the current
# clip, so only the first run per group painted and fills after text (code
# backgrounds, image boxes, pills) vanished the same way. Live Retina
# frames showed Swiss-cheese text that smeared further with every scroll
# blit; 1x (legacy direct draw) and command geometry (fuzz section E) were
# unaffected, which is why no existing test caught it.
#
# This pins PIXELS at 2x against 1x on the same command stream: total bright
# pixels inside text_run rects (and differing pixels inside code_block_bg
# rects) at --force-scale 2 must be within 2x of the 1x render. The broken
# renderer painted ~6% of body text; the fixed one matches 1x. Relative, so
# no hardcoded counts to recalibrate when copy changes.
#
# Usage: scripts/retina_text_coverage.sh [binary]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read-test}"

probe_hooks() {
    out=$("$1" --screenshot /tmp/retina_probe.png --force-scale 1 test_cases/text_wrapping.md 2>&1) || return 1
    [ -f /tmp/retina_probe.png ]
}

if ! probe_hooks "$BIN"; then
    echo "note: $BIN lacks test hooks; building a fresh binary (read-test carries the hooks)"
    : "${ZIG_GLOBAL_CACHE_DIR:=$PWD/.zig-cache-global}"
    export ZIG_GLOBAL_CACHE_DIR
    HOOKS_BIN="${TMPDIR:-/tmp}/read-hooks-$$/bin/read-test"
    zig build -Doptimize=ReleaseFast --prefix "${TMPDIR:-/tmp}/read-hooks-$$" >&2
    BIN="$HOOKS_BIN"
    probe_hooks "$BIN" || { echo "FAIL: hooks binary still reports no screenshot"; exit 2; }
fi

render() {
    # $1 = out png, $2 = doc, $3 = extra scale args; prints CMD stream to stdout
    sleep 0.3
    # shellcheck disable=SC2086
    "$BIN" --screenshot "$1" --settle-images --scroll 0 $3 "$2" --dump-commands 2>&1
}

check_doc() {
    # $1 = doc path
    render /tmp/retina_1x.png "$1" "--force-scale 1" | grep '^CMD' > /tmp/retina_cmds.txt
    render /tmp/retina_2x.png "$1" "--force-scale 2" > /dev/null
    python3 - "$1" /tmp/retina_1x.png /tmp/retina_2x.png /tmp/retina_cmds.txt <<'EOF'
import struct, sys, zlib

doc, p1, p2, cmdf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def load_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a png: " + path
    pos, w, h, depth, ctype, idat = 8, 0, 0, 0, 0, b""
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", data[:10])
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            break
        pos += 12 + ln
    assert depth == 8 and ctype in (2, 6), (path, w, h, depth, ctype)
    ch = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * ch
    px = bytearray(w * h * ch)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        px[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, ch, px

def bright_in(px, w, h, ch, x0, y0, x1, y1, thresh, bg):
    n = 0
    for y in range(max(0, y0), min(h, y1)):
        base = y * w * ch
        for x in range(max(0, x0), min(w, x1)):
            o = base + x * ch
            if max(px[o], px[o + 1], px[o + 2]) - bg > thresh:
                n += 1
    return n

runs, fills = [], []
for ln in open(cmdf):
    f = ln.split()
    if len(f) < 7 or f[0] != "CMD":
        continue
    try:
        x, y, ww, hh = float(f[2]), float(f[3]), float(f[4]), float(f[5])
    except ValueError:
        continue
    if f[1] == "text_run" and ww >= 20.0 and hh >= 8.0:
        runs.append((x, y, ww, hh))
    elif f[1] == "code_block_bg" and ww >= 20.0 and hh >= 8.0:
        fills.append((x, y, ww, hh))

# The batch-clip bug only bites when a line holds several same-color
# runs; a doc of single-run lines would pass vacuously. Refuse that.
if len(runs) < 20:
    print("FAIL: %s has %d text runs, too few to exercise batching" % (doc, len(runs)))
    sys.exit(1)
fail = []
for label, rects, thresh in (("text", runs, 40), ("codebg", fills, 4)):
    if not rects:
        print("note: no %s rects in %s" % (label, doc))
        continue
    w1, h1, _, _ = load_png(p1)
    cov = []
    for path in (p1, p2):
        w, h, ch, px = load_png(path)
        # Window background from the darkest corner (margins stay clear).
        corners = [max(px[o], px[o + 1], px[o + 2])
                   for o in (0, (w - 1) * ch, (h - 1) * w * ch, (h * w - 1) * ch)]
        bg = min(corners)
        # Rects are in points; the 1x bitmap is points==pixels, any forced
        # scale bitmap is a whole multiple of it (truthful backing store).
        sx, sy = w / w1, h / h1
        tot = 0
        for (x, y, ww, hh) in rects:
            tot += bright_in(px, w, h, ch, int(x * sx), int(y * sy),
                             int((x + ww) * sx) + 1, int((y + hh) * sy) + 1,
                             thresh, bg)
        cov.append(tot)
    b1, b2 = cov
    print("%s %s: 1x=%d bright px, 2x=%d" % (doc, label, b1, b2))
    if b1 < 1000:
        fail.append("%s %s: 1x baseline too dim (%d)" % (doc, label, b1))
    elif b2 < b1 // 2:
        fail.append("%s %s: 2x paints %d vs 1x %d (want >= half)" % (doc, label, b2, b1))

if fail:
    for m in fail:
        print("FAIL: " + m)
    sys.exit(1)
print("ok: " + doc)
EOF
}

check_doc "test_cases/text_wrapping.md"
check_doc "test_cases/code_and_tasks.md"
echo "PASS: Retina text coverage holds (2x paints within 2x of 1x)"
