#!/bin/sh
# inline_code_metrics.sh — issue #316: inline code must sit ON the body
# baseline (not ~1.7px high from its 0.88em shrink) and its pill must keep
# symmetric spacing (leading edge used to eat the preceding word space).
#
# Exact command-stream assertions on the issue's repro: baselines derived
# from run rects (platform draws every run at y + size*0.85 of its own
# size), pill geometry, and neighbor gaps. One-decimal dump rounding sets
# the tolerances; pre-fix deltas (1.73px baseline, >=2px gap asymmetry)
# sit far outside them.
set -u
BIN="${HOOKS_BIN:-zig-out/bin/read-test}"
DOC="$(mktemp /tmp/inline_code_XXXXXX.md)"
OUT="${TMPDIR:-/tmp}/inline_code.png"
trap 'rm -f "$DOC"' EXIT INT TERM

printf 'something `something` something\n' > "$DOC"

# shellcheck disable=SC2086
DUMP="$(mktemp /tmp/inline_code_dump_XXXXXX)"
trap 'rm -f "$DOC" "$DUMP"' EXIT INT TERM
"$BIN" --screenshot "$OUT" --force-scale 1 --dump-commands "$DOC" 2>&1 | grep '^CMD' > "$DUMP"
grep -q '^CMD inline_code_bg' "$DUMP" || { echo "FAIL: no pill emitted"; exit 1; }

python3 - "$DUMP" <<'EOF'
import sys

bg = None      # (x, y, w, h)
runs = []      # (x, y, w, fs)
for line in open(sys.argv[1]).read().splitlines():
    p = line.split()
    kind = p[1]
    x, y, w, h = float(p[2]), float(p[3]), float(p[4]), float(p[5])
    if kind == 'inline_code_bg':
        bg = (x, y, w, h)
    elif kind == 'text_run':
        fs = float([q[3:] for q in p if q.startswith('fs=')][0])
        runs.append((x, y, w, fs))
assert bg is not None, 'no pill'
fail = []

# Body row: runs at the pill's row share its line box; the code runs sit
# dy below the body y by construction. Recover the body y from non-code
# neighbors (same visual row, y within half a line height).
row = [r for r in runs if abs(r[1] - bg[1]) < 20.0]
body = [r for r in row if abs(r[3] - 17.0) < 0.01]
code = [r for r in row if abs(r[3] - 17.0) >= 0.01]
if not body or not code:
    print('FAIL: row run census failed (body=%d code=%d)' % (len(body), len(code)))
    sys.exit(1)
body_base = body[0][1] + 17.0 * 0.85
for (x, y, w, fs) in code:
    cb = y + fs * 0.85
    if abs(cb - body_base) > 0.15:
        fail.append('code baseline %.2f vs body %.2f (issue #316: rides high)' % (cb, body_base))
    else:
        print('PASS: code baseline on body baseline (%.2f vs %.2f)' % (cb, body_base))

# Pill hangs below_em under the shared baseline.
fsp = code[0][3]
pill_bottom = bg[1] + bg[3]
want_bottom = body_base + fsp * 0.32
if abs(pill_bottom - want_bottom) > 0.15:
    fail.append('pill bottom %.2f, want %.2f (not hung on shared baseline)' % (pill_bottom, want_bottom))
else:
    print('PASS: pill hung on shared baseline (bottom %.2f)' % pill_bottom)

# Symmetric spacing: gaps from pill edges to neighbor words must match
# (leading edge used to eat pad_x out of the preceding space).
prev = [r for r in body if r[0] + r[2] <= bg[0] + 0.05]
nxt = [r for r in body if r[0] >= bg[0] + bg[2] - 0.05]
if not prev or not nxt:
    print('FAIL: pill neighbors not found')
    sys.exit(1)
lead = bg[0] - max(r[0] + r[2] for r in prev)
trail = min(r[0] for r in nxt) - (bg[0] + bg[2])
print('lead gap=%.2f trail gap=%.2f' % (lead, trail))
if abs(lead - trail) > 0.3:
    fail.append('gap asymmetry %.2f vs %.2f (issue #316: tight leading side)' % (lead, trail))
else:
    print('PASS: pill spacing symmetric')
if lead <= 0 or trail <= 0:
    fail.append('non-positive neighbor gap (overlap)')

if fail:
    for f in fail:
        print('FAIL: ' + f)
    print('inline_code_metrics: FAIL')
    sys.exit(1)
print('inline_code_metrics: PASS (baseline + spacing exact)')
EOF
