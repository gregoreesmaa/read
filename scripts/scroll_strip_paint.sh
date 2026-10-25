#!/bin/sh
# Scroll expose-strip paint (live scroll frame shape).
#
# A live scroll frame is scrolled layout plus strip damage: the platform
# bit-blts the overlapping pixels and AppKit asks for just the exposed
# strip, which the Zig pass repaints from the y-shifted layout. This pins
# that the strip repaints byte-identically to a full render at the same
# scroll offset, and non-blank. A strip that paints nothing (or the wrong
# rows) reads live as sliding content with blank strips below the fold.
#
# Usage: scripts/scroll_strip_paint.sh [binary]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read-test}"
DOC="showcase.md"
W=1200
H=900

probe_hooks() {
    out=$("$1" --screenshot /tmp/strip_probe.png --force-scale 1 --scroll 500 "$DOC" 2>&1) || return 1
    [ -f /tmp/strip_probe.png ]
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
    # $1 = out png, rest = extra args; binary chatter goes to stdout
    # so callers can harvest --dump-commands, stderr stays for DBGLOG.
    # --dump-commands rides after the doc, same position as fuzz_render.
    sleep 0.3
    # shellcheck disable=SC2086
    "$BIN" --screenshot "$1" --settle-images $2 "$DOC" --dump-commands 2>/dev/null
}

check_strip() {
    # $1 = scroll, $2 = scale flag, $3 = strip "x,y,w,h", $4 = label
    render /tmp/strip_full.png "--scroll $1 $2" > /tmp/strip_full_cmds.txt
    render /tmp/strip_part.png "--scroll $1 $2 --damage $3" > /tmp/strip_part_cmds.txt
    if ! cmp -s /tmp/strip_full_cmds.txt /tmp/strip_part_cmds.txt; then
        echo "note: $4 command streams differ under damage:"
        diff /tmp/strip_full_cmds.txt /tmp/strip_part_cmds.txt | head -20 || true
    fi
    python3 - "$4" /tmp/strip_full.png /tmp/strip_part.png "$3" <<'EOF'
import struct, sys, zlib

label, pf, pp, spec = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sx, sy, sw, sh = (int(float(v)) for v in spec.split(","))

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

def rows_nonbg(px, w, h, ch, y0, y1, bg):
    n = 0
    for y in range(max(0, y0), min(h, y1)):
        base = y * w * ch
        for x in range(w):
            o = base + x * ch
            if max(px[o], px[o + 1], px[o + 2]) - bg > 8:
                n += 1
    return n

wf, hf, chf, full = load_png(pf)
wp, hp, chp, part = load_png(pp)
# Reference and strip renders share one backing multiple here (same
# scale flag), so device-px strips line up 1:1; keep the ratio anyway.
fx, fy = wp / wf, hp / hf
bgf = min(max(full[o], full[o + 1], full[o + 2])
          for o in (0, (wf - 1) * chf, (hf - 1) * wf * chf, (hf * wf - 1) * chf))
# Strip in device px, end-exclusive (points times backing multiple): the
# first row past the damage edge must stay out — the strip render
# correctly leaves it blank under its hard clip.
x0, y0 = int(sx * fx), int(sy * fy)
x1, y1 = int((sx + sw) * fx), int((sy + sh) * fy)
ref = rows_nonbg(full, wf, hf, chf, y0, y1, bgf)
if ref < 1000:
    print("FAIL: %s reference strip has no paint (%d)" % (label, ref))
    sys.exit(1)
got = rows_nonbg(part, wp, hp, chp, y0, y1, bgf)
print("%s: reference=%d strip=%d" % (label, ref, got))
if got < ref // 2:
    print("FAIL: %s strip paints %d vs reference %d (want >= half)" % (label, got, ref))
    sys.exit(1)
# Pixel-identity inside the strip (damage must not move a pixel), with
# a row profile so failures say WHERE (edge-only fringe vs shifted rows
# vs scattered image-timing noise).
bad = 0
rows = {}
for y in range(max(0, y0), min(hf, hp, y1)):
    n = 0
    for x in range(max(0, x0), min(wf, wp, x1)):
        of = (y * wf + x) * chf
        op = (y * wp + x) * chp
        if full[of:of + 3] != part[op:op + 3]:
            bad += 1
            n += 1
    if n:
        rows[y] = n
if bad > 100:
    ys = sorted(rows)
    print("FAIL: %s strip differs from full render (%d px)" % (label, bad))
    print("diff rows %d-%d, worst rows: %s" % (
        ys[0], ys[-1],
        ", ".join("%d:%d" % (y, rows[y]) for y in sorted(rows, key=rows.get, reverse=True)[:8])))
    sys.exit(1)
print("ok: " + label)
EOF
}

check_strip 500 "--force-scale 1" "0,820,1200,80" "1x scroll-500 bottom-strip"
check_strip 500 "--force-scale 1" "0,0,1200,80" "1x scroll-500 top-strip"
check_strip 500 "--force-scale 2" "0,820,1200,80" "2x scroll-500 bottom-strip"
check_strip 500 "--force-scale 2" "0,0,1200,80" "2x scroll-500 top-strip"
check_strip 3000 "--force-scale 2" "0,820,1200,80" "2x scroll-3000 bottom-strip"
echo "PASS: scroll expose strips repaint identically to full renders"
