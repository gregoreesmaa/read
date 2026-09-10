#!/bin/sh
# select_inline_wash.sh — selecting text on a line with inline code must
# not wash the pill (and friends): only runs inside the selection span
# may paint. Regression: the #316 baseline sink moved code runs 1.73px
# below their row's doc_y, so row membership missed them and they fell
# through to the paint-everything middle branch.
#
# Self-calibrating pixel assertions from --dump-commands geometry of the
# same fixture (no font-metric assumptions, no hardcoded coords).
# Blue = wash tint (b-r >= 40); pill bg is not blue, wash over pill is.
set -u
BIN="${HOOKS_BIN:-zig-out/bin/read-test}"
DOC="$(mktemp /tmp/sel_inline_XXXXXX.md)"
OUT="${TMPDIR:-/tmp}/select_inline.png"
trap 'rm -f "$DOC"' EXIT INT TERM

printf '# H `c` T\n\npara aaa `bbb` ccc end\n\n[d](https://example.com) eee fff\n\npara one alpha here\n\npara `mid` two here\n\npara three omega here\n' > "$DOC"

# shellcheck disable=SC2086
DUMP="$(mktemp /tmp/sel_inline_dump_XXXXXX)"
trap 'rm -f "$DOC" "$DUMP"' EXIT INT TERM
"$BIN" --screenshot "$OUT" --force-scale 1 --dump-commands "$DOC" 2>&1 | grep '^CMD' > "$DUMP"

python3 - "$DUMP" "$DOC" "$BIN" "$OUT" <<'PYEOF'
import struct, subprocess, sys, zlib

DUMP, DOC, BIN, OUT = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

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

def rgb(img, x, y):
    w, h, ch, px = img
    o = (y * w + x) * ch
    return px[o], px[o + 1], px[o + 2]

def is_blue(p):
    return (p[2] - p[0]) >= 40

def field(line, key):
    for q in line.split():
        if q.startswith(key):
            v = q[len(key):]
            return v[:-1] if v.endswith("'") else v
    return ''

runs, pills = [], []
for line in open(DUMP).read().splitlines():
    p = line.split()
    if p[1] == 'text_run':
        runs.append({'x': float(p[2]), 'y': float(p[3]), 'w': float(p[4]), 'h': float(p[5]),
                     'fs': float(field(line, 'fs=')), 'txt': field(line, "txt='")})
    elif p[1] == 'inline_code_bg':
        pills.append({'x': float(p[2]), 'y': float(p[3]), 'w': float(p[4]), 'h': float(p[5])})
assert pills, 'no pills emitted'

# Cluster runs into visual rows by y.
rows = []
for r in sorted(runs, key=lambda r: r['y']):
    for row in rows:
        if abs(r['y'] - row[0]['y']) < 6.0:
            row.append(r)
            break
    else:
        rows.append([r])

def pill_row(pill):
    best, bestd = None, 1e9
    for row in rows:
        d = abs(sum(r['y'] for r in row) / len(row) - pill['y'])
        if d < bestd:
            bestd, best = d, row
    return best

def body_fs(row):
    return max(r['fs'] for r in row)

def code_runs(row):
    bfs = body_fs(row)
    return [r for r in row if r['fs'] < bfs - 1.0]

def render(sel):
    subprocess.run([BIN, '--screenshot', OUT, '--force-scale', '1',
                    '--select', sel, DOC],
                   check=True, capture_output=True)
    return read_png(OUT)

def render_plain():
    subprocess.run([BIN, '--screenshot', OUT, '--force-scale', '1', DOC],
                   check=True, capture_output=True)
    return read_png(OUT)

def blues(img, x0, x1, y0, y1):
    w, h, ch, px = img
    n = 0
    for y in range(max(0, int(y0)), min(h, int(y1) + 1)):
        for x in range(max(0, int(x0)), min(w, int(x1) + 1)):
            if is_blue(rgb(img, x, y)):
                n += 1
    return n

def interior(r, pad=3.0):
    return r['x'] + pad, r['x'] + r['w'] - pad, r['y'] + 5.0

fail = []
def check(name, cond, detail=''):
    print(('PASS: ' if cond else 'FAIL: ') + name + ((' (%s)' % detail) if detail else ''))
    if not cond:
        fail.append(name)

# --- locate fixture pieces -------------------------------------------
para = next(row for row in rows if any(r['txt'].startswith('para') for r in row))
pill = next(p for p in pills if pill_row(p) is para)
cr = code_runs(para)[0]
aaa = next(r for r in para if r['txt'].startswith('aaa'))
ccc = next(r for r in para if r['txt'].startswith('ccc'))
head = next(row for row in rows if any(r['txt'] == 'H' for r in row))
hpill = next(p for p in pills if pill_row(p) is head)
hcode = code_runs(head)[0]
hword = next(r for r in head if r is not hcode and r['x'] < hcode['x'])
linkrow = next(row for row in rows if any(r['txt'] == 'eee' for r in row))
linkrun = min(linkrow, key=lambda r: r['x'])
eee = next(r for r in linkrow if r['txt'] == 'eee')
# Three one-row paragraphs; the pill lives in the middle one.
mrow1 = next(row for row in rows if any(r['txt'] == 'alpha' for r in row))
mrow2 = next(row for row in rows if any(r['txt'] == 'mid' for r in row))
mrow3 = next(row for row in rows if any(r['txt'] == 'omega' for r in row))
mpill = next(p for p in pills if pill_row(p) is mrow2)
w1 = next(r for r in mrow1 if r['txt'] == 'one')
w2pre = next(r for r in mrow2 if r['txt'] == 'para')
w2post = next(r for r in mrow2 if r['txt'] == 'two')
w3 = next(r for r in mrow3 if r['txt'] == 'three')

def sel_box(x0, x1, y):
    return '%.1f,%.1f,%.1f,%.1f' % (x0, y, x1, y)

# Baseline: no selection. Pill regions must be blue-free here (no
# confounding blue), and the link's own blue text is calibrated out.
base = render_plain()
for p in pills:
    n0 = blues(base, p['x'], p['x'] + p['w'], p['y'], p['y'] + p['h'])
    check('baseline pill region blue-free', n0 == 0, 'pill@%.0f' % p['x'])
base_link = blues(base, linkrun['x'], linkrun['x'] + linkrun['w'],
                  linkrun['y'] - 2, linkrun['y'] + linkrun['h'] + 2)

# --- C1: word before pill ---------------------------------------------
x0, x1, y = interior(aaa)
img = render(sel_box(x0, x1, y))
check('C1 wash covers selected word', blues(img, x0, x1, y - 8, y + 20) > 20)
check('C1 pill stays clean', blues(img, pill['x'], pill['x'] + pill['w'], pill['y'], pill['y'] + pill['h']) == 0)

# --- C2: word after pill ----------------------------------------------
x0, x1, y = interior(ccc)
img = render(sel_box(x0, x1, y))
check('C2 wash covers selected word', blues(img, x0, x1, y - 8, y + 20) > 20)
check('C2 pill stays clean', blues(img, pill['x'], pill['x'] + pill['w'], pill['y'], pill['y'] + pill['h']) == 0)

# --- C3: selection into the pill --------------------------------------
# Cut mid-glyph-run (text spans the pill nearly edge to edge), so the
# uncovered region still holds glyphs that must stay clean.
cut = pill['x'] + 12.0
img = render(sel_box(pill['x'] + 2.0, cut, pill['y'] + 8.0))
check('C3 covered pill part washes', blues(img, pill['x'] + 2, cut - 2, pill['y'], pill['y'] + pill['h']) > 10)
check('C3 uncovered pill part stays clean',
      blues(img, cut + 10, pill['x'] + pill['w'], pill['y'], pill['y'] + pill['h']) == 0)

# --- C4: heading row ---------------------------------------------------
x0, x1, y = interior(hword)
img = render(sel_box(x0, x1, y))
check('C4 wash covers selected heading word', blues(img, x0, x1, y - 8, y + 24) > 20)
check('C4 heading pill stays clean',
      blues(img, hpill['x'], hpill['x'] + hpill['w'], hpill['y'], hpill['y'] + hpill['h']) == 0)

# --- C5: link guard (unshifted runs must stay clipped) ------------------
# The link's own text is blue, so this case diffs against the baseline:
# selection must add zero blue over the link run.
x0, x1, y = interior(eee)
img = render(sel_box(x0, x1, y))
check('C5 wash covers selected word', blues(img, x0, x1, y - 8, y + 20) > 20)
n1 = blues(img, linkrun['x'], linkrun['x'] + linkrun['w'], linkrun['y'] - 2, linkrun['y'] + linkrun['h'] + 2)
check('C5 link run gains no wash', n1 == base_link, 'base=%d sel=%d' % (base_link, n1))

# --- C6: pill row as middle row washes fully (correct) ------------------
a0, a1, ay = interior(w1)
b0, b1, by = interior(w3)
img = render('%.1f,%.1f,%.1f,%.1f' % (a0, ay, b1, by))
check('C6 middle-row pill washes (correct full-row span)',
      blues(img, mpill['x'], mpill['x'] + mpill['w'], mpill['y'], mpill['y'] + mpill['h']) > 20)

# --- C7: pill row as first row, pill left of start ----------------------
a0, a1, ay = interior(w2post)
b0, b1, by = interior(w3)
img = render('%.1f,%.1f,%.1f,%.1f' % (a0, ay, b1, by))
check('C7 first-row pill before start stays clean',
      blues(img, mpill['x'], mpill['x'] + mpill['w'], mpill['y'], mpill['y'] + mpill['h']) == 0)

# --- C8: pill row as last row, pill right of end ------------------------
a0, a1, ay = interior(w1)
b0, b1, by = interior(w2pre)
img = render('%.1f,%.1f,%.1f,%.1f' % (a0, ay, b1, by))
check('C8 last-row pill after end stays clean',
      blues(img, mpill['x'], mpill['x'] + mpill['w'], mpill['y'], mpill['y'] + mpill['h']) == 0)

if fail:
    print('select_inline_wash: FAIL (%d)' % len(fail))
    sys.exit(1)
print('select_inline_wash: PASS (pill clipping exact, all rows)')
PYEOF
