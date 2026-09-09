#!/bin/sh
# select_scrolled.sh — issue #314: selection must lock to document content
# across horizontal block scroll (highlight tracks the scrolled text;
# pre-fix it visually "sticks" while the code scrolls away).
#
# Self-calibrating: every coordinate comes from pixel analysis of renders
# on this machine (stdlib-python PNG decode, no probes, no font-metric
# assumptions). Four renders of a one-long-line fixture:
#   R1 plain, unparked  -> code row y, unscrolled text edge, control gap
#   R2 plain, parked     -> max scroll M, selection gap in parked view
#   R3 parked + select   -> highlight must sit exactly on the dragged view
#                           range (absolute assertion, not a shift delta)
#   R4 unparked + select -> control: same machinery at scroll 0
set -u
BIN="${HOOKS_BIN:-zig-out/bin/read-test}"
DOC="$(mktemp /tmp/sel_scroll_XXXXXX.md)"
OUT="${TMPDIR:-/tmp}/select_scrolled.png"
trap 'rm -f "$DOC"' EXIT INT TERM

printf '# t\n\n```\nAAA WORD BBB CCC DDD EEE FFF GGG HHH III JJJ KKK LLL MMM NNN OOO PPP QQQ RRR SSS TTT UUU VVV WWW XXX YYY ZZZ 111 222 333 444 555 666 777 888 999 000 END\nshort\n```\n' > "$DOC"

# shellcheck disable=SC2086
R1P="$OUT.r1.png"; R2P="$OUT.r2.png"; R3P="$OUT.r3.png"; R4P="$OUT.r4.png"
"$BIN" --screenshot "$R1P" --force-scale 1 "$DOC" >/dev/null 2>&1 || { echo "FAIL: R1 render failed"; exit 1; }
# R2 also dumps the command stream: the parked block's max scroll comes
# from the same process that rendered the pixels, so no drift is possible.
R2LOG=$(mktemp /tmp/sel_scroll_log_XXXXXX)
trap 'rm -f "$DOC" "$R2LOG"' EXIT INT TERM
"$BIN" --screenshot "$R2P" --force-scale 1 --scroll-x-end --dump-commands "$DOC" >"$R2LOG" 2>&1 || { echo "FAIL: R2 render failed"; exit 1; }
M=$(awk '/^CMD register_scrollable_block/{ for (i=1;i<=NF;i++) if ($i ~ /^max=/) { print int(substr($i,5)+0.5); exit } }' "$R2LOG")
# M_OVERRIDE (same-fixture replays, e.g. negative controls on binaries
# whose dump lacks sid/max): same layout => same max scroll.
[ -n "${M_OVERRIDE:-}" ] && M=$M_OVERRIDE
[ -n "$M" ] && [ "$M" -gt 200 ] || { echo "FAIL: max scroll too small for a locking test (M=$M)"; exit 1; }
echo "max scroll M=$M"

# R1/R2 analysis: row y, text edges, gaps, max scroll M, selections.
EVAL=$(python3 - "$R1P" "$R2P" "$M" <<'EOF'
import struct, sys, zlib

def read_png(path):
    d = open(path, 'rb').read()
    pos = 8
    w = h = ctype = bitd = inter = None
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
    assert bitd == 8 and inter == 0, 'unhandled PNG kind'
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
        prev = line
    return w, h, ch, px

def rgb(img, x, y):
    w, h, ch, px = img
    o = (y * w + x) * ch
    return px[o], px[o + 1], px[o + 2]

def is_blue(p): return (p[2] - p[0]) >= 40
def is_text(p): return (not is_blue(p)) and (p[0] + p[1] + p[2]) >= 120

r1 = read_png(sys.argv[1])
r2 = read_png(sys.argv[2])
W = r1[0]

# Code row: y with the most text pixels in the content band.
best_y, best_n = -1, -1
for y in range(150, 450):
    n = sum(1 for x in range(250, 950) if is_text(rgb(r1, x, y)))
    if n > best_n: best_n, best_y = n, y
assert best_n > 100, 'code row not found'
row = best_y

def first_text(img, y, x0=100, x1=None):
    for x in range(x0, x1 or W):
        if is_text(rgb(img, x, y)): return x
    return -1

t0_u = first_text(r1, row)
assert t0_u > 0, 'text edge not found'

def widest_gap(img, y, lo, hi, need=6):
    best = (-1, -1)
    x = lo
    while x < hi:
        if not is_text(rgb(img, x, y)):
            x0 = x
            while x < hi and not is_text(rgb(img, x, y)): x += 1
            if x - x0 >= need and (x - x0) > (best[1] - best[0]): best = (x0, x)
        else:
            x += 1
    assert best[0] >= 0, 'no gap found'
    return (best[0] + best[1]) // 2

# Control selection: gap near the unscrolled text start.
g_u = widest_gap(r1, row, t0_u + 60, t0_u + 200)
# Locked selection: gap mid-container in parked view -> doc via +M (M from
# the same-process command dump, passed on the command line).
M = int(sys.argv[3])
g_s = widest_gap(r2, row, 380, 520)
print('ROW=%d M=%d GU=%d GS=%d' % (row, M, g_u, g_s))
EOF
) || { echo "FAIL: calibration failed: $EVAL"; exit 1; }
echo "calibration: $EVAL"
eval "$EVAL"

# R3 parked + select(doc GS+M .. GS+M+250): highlight must sit on GS view.
SEL_S="$((GS + M)),$ROW,$((GS + M + 250)),$ROW"
# shellcheck disable=SC2086
"$BIN" --screenshot "$R3P" --force-scale 1 --scroll-x-end --select "$SEL_S" "$DOC" >/dev/null 2>&1 || { echo "FAIL: R3 render failed"; exit 1; }
# R4 control: unparked + select(doc GU .. GU+200).
SEL_U="$GU,$ROW,$((GU + 200)),$ROW"
# shellcheck disable=SC2086
"$BIN" --screenshot "$R4P" --force-scale 1 --select "$SEL_U" "$DOC" >/dev/null 2>&1 || { echo "FAIL: R4 render failed"; exit 1; }

python3 - "$R3P" "$R4P" "$GS" "$GU" "$ROW" <<'EOF'
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
        prev = line
    return w, h, ch, px

def rgb(img, x, y):
    w, h, ch, px = img
    o = (y * w + x) * ch
    return px[o], px[o + 1], px[o + 2]

def is_blue(p): return (p[2] - p[0]) >= 40

r3 = read_png(sys.argv[1])
r4 = read_png(sys.argv[2])
GS, GU, ROW = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
W = r3[0]
fail = []

def first_blue(img, y):
    for x in range(0, W):
        if is_blue(rgb(img, x, y)): return x
    return -1

# Locked: leading wash edge on the dragged view x (gap-picked). Left slop
# covers char-start snap (up to one mono advance) + 2px wash insets + AA;
# right slop is tight: overshoot means the highlight lags the scroll.
h0 = first_blue(r3, ROW)
if h0 < 0:
    fail.append('scrolled highlight missing entirely (paints off-screen: #314 stuck-selection)')
elif not (GS - 12 <= h0 <= GS + 2):
    fail.append('scrolled highlight edge at %d, want dragged view x %d (#314)' % (h0, GS))
else:
    print('PASS: scrolled highlight leading edge on dragged content (x=%d)' % h0)

# Locked: wash mass inside the dragged box (glyph-hole-proof).
box = [is_blue(rgb(r3, x, y))
       for y in range(ROW - 10, ROW + 11) for x in range(GS + 10, GS + 240)]
mass = sum(box) / len(box)
if mass < 0.30:
    fail.append('scrolled wash mass %.2f in dragged box (want >= 0.30: #314)' % mass)
else:
    print('PASS: scrolled wash fills dragged box (mass=%.2f)' % mass)

# Control: unparked machinery sane (same char-snap slop as above).
c0 = first_blue(r4, ROW)
if c0 < 0 or not (GU - 12 <= c0 <= GU + 2):
    fail.append('control highlight edge at %s, want %d (fixture drift?)' % (c0, GU))
else:
    print('PASS: unparked control edge exact (x=%d)' % c0)

if fail:
    for f in fail: print('FAIL: ' + f)
    sys.exit(1)
print('select_scrolled: PASS (highlight locks to scrolled content)')
EOF
