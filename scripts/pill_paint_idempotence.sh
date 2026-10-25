#!/bin/sh
# Repaint idempotence (pill-cache MISS/HIT parity under a warm cache).
#
# A live scroll frame repaints over warm caches: pill rasters, shape slices
# and the atlas persist across frames. Before the store-then-blit fix, a
# pill-cache miss painted the vector path directly while later hits blitted
# the cached raster — visibly different pixels on fractional-width pills —
# so pill-dense lines (README keybindings, benchmark note) flickered as the
# visible set churned per scroll frame, while device-snapped text stayed
# put. This renders the same scrolled frame twice on one bitmap (the second
# pass hits warm caches, exactly the live-scroll state) and requires
# byte-identical phases, at 1x and forced 2x. Any future MISS/HIT paint
# divergence fails here; damage-culling parity is pinned separately by
# scroll_strip_paint.sh.
#
# Usage: scripts/pill_paint_idempotence.sh [binary]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read-test}"
DOC="README.md"
P0="/tmp/repaint_phase_0.png"
P1="/tmp/repaint_phase_1.png"

probe_hooks() {
    out=$("$1" --screenshot /tmp/idem_probe.png --force-scale 1 --scroll 0 "$DOC" 2>&1) || return 1
    [ -f /tmp/idem_probe.png ]
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

check_repaint() {
    # $1 = scroll, $2 = scale flag, $3 = label
    sleep 0.3
    rm -f "$P0" "$P1"
    # shellcheck disable=SC2086
    "$BIN" --screenshot /tmp/idem_scratch.png $2 --scroll "$1" --repaint-idempotence "$DOC" >/tmp/idem_out.txt 2>&1 || {
        echo "FAIL: $3 render exited nonzero (tail):"
        tail -5 /tmp/idem_out.txt || true
        exit 2
    }
    [ -f "$P0" ] && [ -f "$P1" ] || { echo "FAIL: $3 missing phase PNGs"; exit 2; }
    if ! cmp -s "$P0" "$P1"; then
        echo "FAIL: $3 phases differ (cache-state-dependent paint)"
        exit 1
    fi
    python3 - "$3" "$P0" <<'EOF'
import struct, sys, zlib
label, path = sys.argv[1], sys.argv[2]
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
prev = bytearray(stride)
p = 0
bg = None
ink = 0
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
    if bg is None:
        bg = max(line[0], line[1], line[2])
    for x in range(w):
        o = x * ch
        if max(line[o], line[o + 1], line[o + 2]) - bg > 8:
            ink += 1
    prev = line
print("%s: %dx%d ink=%d" % (label, w, h, ink))
if ink < 10000:
    print("FAIL: %s renders blank (vacuous pass)" % label)
    sys.exit(1)
print("PASS: %s phases byte-identical, non-blank" % label)
EOF
}

check_repaint 0 "--force-scale 1" "1x top (pill lines)"
check_repaint 0 "--force-scale 2" "2x top (pill lines)"
check_repaint 800 "--force-scale 2" "2x scrolled (pill lines)"
check_repaint 200.37 "--force-scale 2" "2x fractional scroll"
