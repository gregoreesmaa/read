#!/bin/sh
# copy_button_damage.sh — copy-button 1px ghost outline on disappear.
#
# Root cause: the pill paints a 1px stroke CENTERED on its edge (0.5px of
# ink plus antialiasing fall outside), but visibility flips invalidated
# the EXACT button rect, so the fringe never repainted.
#
# Two pins (paint is untouched by the fix, so pixels alone cannot tell
# pre/post apart — the contract assertion is the discriminator):
#   1. Contract: --button-damage for the block frame must equal the pill
#      rect inflated by 2px. Pre-fix it equals the exact pill (FAIL).
#   2. Paint: with --hover parked over the block, pill ink is present at
#      the pill rect and its bounding box stays inside the padded damage
#      rect (end-to-end sanity; the measured fringe is reported so the
#      padding is visibly load-bearing, never vacuous).
set -u
BIN="${HOOKS_BIN:-zig-out/bin/read-test}"
DOC="$(mktemp /tmp/copy_btn_XXXXXX.md)"
OUT="${TMPDIR:-/tmp}/copy_button.png"
trap 'rm -f "$DOC"' EXIT INT TERM

# Multiline fenced block, per the report.
printf '# t\n\n```\nline one here\nline two here\nline three here\nline four here\n```\n\ntail text\n' > "$DOC"

# shellcheck disable=SC2086
RECT=$("$BIN" --screenshot "$OUT" --force-scale 1 --dump-commands "$DOC" 2>&1 | awk '/^CMD code_block_bg/{print $3, $4, $5, $6; exit}')
[ -n "$RECT" ] || { echo "FAIL: no code block emitted"; exit 1; }
set -- $RECT
BX=$1; BY=$2; BW=$3; BH=$4
echo "block=$BX,$BY,${BW}x$BH"

# --- 1. damage contract -----------------------------------------------
# NOTE: --screenshot stays on the command line so the binary takes the
# headless one-shot path and exits (flag-only invocations launch the GUI
# event loop and hang forever).
# shellcheck disable=SC2086
GOT=$("$BIN" --screenshot "${TMPDIR:-/tmp}/btndmg.png" --button-damage "$BX,$BY,$BW,$BH" "$DOC" 2>&1 | grep '^BTNDMG=' | head -n 1 | cut -d= -f2)
[ -n "$GOT" ] || { echo "FAIL: no BTNDMG answer"; exit 1; }
python3 - "$GOT" "$BX" "$BY" "$BW" <<'EOF'
import sys
gx, gy, gw, gh = (float(v) for v in sys.argv[1].split(','))
bx, by, bw = float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
# Pill contract, mirroring copy_button_rect_for_block + 2px damage pad.
ex, ey, ew, eh = bx + bw - 72.0 - 2.0, by + 8.0 - 2.0, 68.0, 28.0
ok = abs(gx - ex) <= 0.15 and abs(gy - ey) <= 0.15 and abs(gw - ew) <= 0.15 and abs(gh - eh) <= 0.15
print('damage=%s want=%.1f,%.1f,%.1fx%.1f' % (sys.argv[1], ex, ey, ew, eh))
if not ok:
    print('FAIL: damage rect is the exact pill (ghost fringe not covered)')
    sys.exit(1)
print('PASS: damage rect pads the pill by 2px')
EOF
[ $? -eq 0 ] || { echo "copy_button_damage: FAIL"; exit 1; }

# --- 2. paint presence + ink inside damage -----------------------------
HX=$(python3 -c "print($BX + 100.0)")
HY=$(python3 -c "print($BY + 30.0)")
# shellcheck disable=SC2086
"$BIN" --screenshot "$OUT" --force-scale 1 --hover "$HX,$HY" "$DOC" >/dev/null 2>&1 || { echo "FAIL: hover render failed"; exit 1; }

python3 - "$OUT" "$BX" "$BY" "$BW" <<'EOF'
import struct, sys, zlib

def read_png(path):
    d = open(path, 'rb').read()
    pos = 8
    idat = b''
    while pos < len(d):
        (ln,) = struct.unpack('>I', d[pos:pos + 4])
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, bitd, ctype, comp, filt, inter = struct.unpack('>IIBBBBB', data)
        elif typ == b'IDAT':
            idat += data
        elif typ == b'IEND':
            break
        pos += 12 + ln
    assert bitd == 8 and inter == 0
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * ch
    px = bytearray(w * h * ch)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(ch, stride): line[i] = (line[i] + line[i - ch]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                q = a + b - c
                pa, pb, pc = abs(q - a), abs(q - b), abs(q - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        px[y * stride:(y + 1) * stride] = line
        prev = bytes(line)
    return w, h, ch, px

w, h, ch, px = read_png(sys.argv[1])
bx, by, bw = float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
px0, py0 = bx + bw - 72.0, by + 8.0  # pill rect (copy_button_rect_for_block)

def rgb(x, y):
    o = (y * w + x) * ch
    return px[o], px[o + 1], px[o + 2]

def dist(p, q):
    return abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2])

FILL, STROKE = (51, 56, 66), (76, 83, 98)
def is_ink(p):
    if dist(p, FILL) <= 75 or dist(p, STROKE) <= 75:
        return True
    return (p[0] + p[1] + p[2]) >= 550 and (p[2] - p[0]) >= 10  # label

x0, x1 = int(px0) - 8, int(px0 + 64) + 8
y0, y1 = int(py0) - 8, int(py0 + 24) + 8
inside = 0
blo, bhi, bloy, bhiy = w, -1, h, -1
for y in range(max(0, y0), min(h, y1 + 1)):
    for x in range(max(0, x0), min(w, x1 + 1)):
        if is_ink(rgb(x, y)):
            blo, bhi = min(blo, x), max(bhi, x)
            bloy, bhiy = min(bloy, y), max(bhiy, y)
            if px0 <= x <= px0 + 64 and py0 <= y <= py0 + 24:
                inside += 1
if bhi < 0:
    print('FAIL: no button ink painted under hover')
    sys.exit(1)
print('ink inside pill=%d bbox=(%d..%d, %d..%d)' % (inside, blo, bhi, bloy, bhiy))
over = max(px0 - blo, bhi - (px0 + 64), py0 - bloy, bhiy - (py0 + 24))
print('fringe beyond exact pill=%.1fpx (padding is load-bearing)' % max(0.0, over))
fail = []
if inside < 400:
    fail.append('button ink missing (inside=%d)' % inside)
else:
    print('PASS: button paints at pill rect')
if blo < px0 - 2.0 or bhi > px0 + 64 + 2.0 or bloy < py0 - 2.0 or bhiy > py0 + 24 + 2.0:
    fail.append('ink escapes padded damage rect')
else:
    print('PASS: all ink inside padded damage rect')
if fail:
    for f in fail:
        print('FAIL: ' + f)
    sys.exit(1)
print('copy_button_damage: PASS (contract + paint)')
EOF
