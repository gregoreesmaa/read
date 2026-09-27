#!/bin/sh
# Math parity harness (issue #381, upstream zatex#258).
#
# The upstream host-parity kit (canonical TeX corpus + Latin-Modern
# reference PNGs + tolerance comparison) assumes the kit face; Read
# draws through system STIX Two Math, so per the kit's own host recipe
# ("pin YOUR face, keep YOUR reference PNGs, and compare structure")
# this harness keeps Read-side references instead of re-shooting
# upstream goldens on every engine upgrade:
#
# - vendored corpus rows (scripts/math_parity_corpus.json, slimmed from
#   upstream tools/host-parity/corpus.json) render end to end through
#   read-test: every row must render successfully, deterministically
#   (two renders byte-equal), and non-blank (real ink pixels).
# - when a zatex checkout is present (ZATEX_CHECKOUT, ../zatex sibling,
#   third_party/zatex), the vendored rows are freshness-checked against
#   upstream corpus.json first: upstream row drift fails loudly so the
#   vendoring is re-done, keeping both sides honest. The kit's own
#   check.sh stays upstream-CI-owned (it builds zatex-png; nothing
#   Read-side to consume there).
# - without a checkout the local harness runs alone (hermetic default).
#
# Deep layout pins (dims, raster reuse, negotiation) live in the Zig
# suite (MATH355 + engine-negotiation + scripted-double tests), not
# here: read-test documents always take the source-text fallback path
# (liveMathSizeFn is null under test hooks), so this harness pins
# detection, fallback rendering, and determinism across upgrades.
#
# Usage: sh scripts/math_parity.sh [read-test-binary]
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="${1:-$root/zig-out/bin/read-test}"
if [ ! -x "$BIN" ]; then
    echo "math_parity: no read-test binary ($BIN), skipping (Linux portability job)"
    exit 0
fi
checkout="${ZATEX_CHECKOUT:-}"
if [ -z "$checkout" ]; then
    for cand in "$root/../zatex" "$root/third_party/zatex"; do
        if [ -f "$cand/tools/host-parity/corpus.json" ]; then checkout="$cand"; break; fi
    done
fi
export READ_PARITY_BIN="$BIN"
export READ_PARITY_ROOT="$root"
export READ_PARITY_UPSTREAM="${checkout:-}"
exec python3 - "$root/scripts/math_parity_corpus.json" <<'PYEOF'
import json, os, struct, subprocess, sys, tempfile, zlib

corpus_path = sys.argv[1]
bindir = os.environ["READ_PARITY_BIN"]
upstream = os.environ.get("READ_PARITY_UPSTREAM") or None

vendored = json.load(open(corpus_path))
rows = vendored["rows"]

# Freshness against the upstream kit when a checkout is present: row
# drift (added/removed/changed id:tex) fails loudly so the vendored
# corpus is re-slimmed instead of silently rotting.
if upstream:
    kit = json.load(open(os.path.join(upstream, "tools/host-parity/corpus.json")))
    want = {r["id"]: (r["tex"], r["display"]) for r in kit}
    have = {r["id"]: (r["tex"], r["display"]) for r in rows}
    if want != have:
        only_up = sorted(set(want) - set(have))
        only_local = sorted(set(have) - set(want))
        changed = sorted(i for i in set(want) & set(have) if want[i] != have[i])
        sys.stderr.write("math_parity: vendored corpus drifted from upstream kit\n")
        if only_up: sys.stderr.write("  upstream-only: %s\n" % ",".join(only_up))
        if only_local: sys.stderr.write("  local-only: %s\n" % ",".join(only_local))
        if changed: sys.stderr.write("  changed: %s\n" % ",".join(changed))
        sys.stderr.write("  re-slim tools/host-parity/corpus.json into scripts/math_parity_corpus.json\n")
        sys.exit(1)
    print("math_parity: vendored corpus fresh vs upstream kit (%d rows)" % len(rows))
else:
    print("math_parity: no zatex checkout, local harness on %d vendored rows" % len(rows))

def png_pixels(path):
    """Unique RGBA tuples of an 8-bit PNG (stdlib only)."""
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "bad signature"
    off, idat, w, h, bd, ct = 8, bytearray(), 0, 0, 0, 0
    while off < len(d):
        ln, typ = struct.unpack(">I", d[off:off + 4])[0], d[off + 4:off + 8]
        data = d[off + 8:off + 8 + ln]
        if typ == b"IHDR":
            w, h, bd, ct, _, _, _ = struct.unpack(">IIBBBBB", data)
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            break
        off += 12 + ln
    assert bd == 8 and ct in (0, 2, 6), "unhandled PNG form"
    ch = {0: 1, 2: 3, 6: 4}[ct]
    raw = zlib.decompress(bytes(idat))
    stride, px = w * ch, set()
    pos = 0
    prev = bytearray(stride)
    for _ in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos + stride]); pos += stride
        if f == 1:
            for i in range(ch, stride): line[i] = (line[i] + line[i - ch]) & 0xFF
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b, c = prev[i], prev[i - ch] if i >= ch else 0
                p, pa, pb, pc = a + b - c, 0, 0, 0
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        for i in range(0, stride, ch):
            v = tuple(line[i:i + ch])
            if ch == 1: v = (v[0], v[0], v[0], 255)
            elif ch == 3: v = v + (255,)
            px.add(v)
        prev = line
    return px

def render(doc, out):
    r = subprocess.run([bindir, "--screenshot", out, "--force-scale", "1", doc],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError("render failed: %s" % (r.stderr.strip()[-300:]))

tmp = tempfile.mkdtemp(prefix="read-parity-")
fails = []
docs = []
for r in rows:
    tex, disp = r["tex"], r["display"]
    body = "$$%s$$" % tex if disp else "Row %s: $%s$ end." % (r["id"], tex)
    doc = os.path.join(tmp, r["id"] + ".md")
    open(doc, "w").write("# %s\n\n%s\n" % (r["id"], body))
    docs.append(doc)
    out = os.path.join(tmp, r["id"] + ".png")
    try:
        render(doc, out)
        px = png_pixels(out)
        # Non-blank: background plus real ink (at least 2 colors).
        assert len(px) >= 2, "blank render (%d colors)" % len(px)
        print("  row %-12s PASS (%d colors)" % (r["id"], len(px)))
    except Exception as e:
        print("  row %-12s FAIL (%s)" % (r["id"], e))
        fails.append(r["id"])

# Determinism across the whole corpus in one document: two renders
# must be byte-equal (engine upgrades must not introduce jitter).
big = os.path.join(tmp, "corpus.md")
open(big, "w").write("# parity corpus\n\n" + "\n\n".join(
    ("$$%s$$" % r["tex"]) if r["display"] else ("$%s$" % r["tex"]) for r in rows) + "\n")
o1, o2 = os.path.join(tmp, "c1.png"), os.path.join(tmp, "c2.png")
try:
    render(big, o1)
    render(big, o2)
    assert open(o1, "rb").read() == open(o2, "rb").read(), "renders differ"
    px = png_pixels(o1)
    assert len(px) >= 2, "blank corpus render"
    print("  determinism PASS (%d colors)" % len(px))
except Exception as e:
    print("  determinism FAIL (%s)" % e)
    fails.append("determinism")

if fails:
    sys.stderr.write("math_parity: FAIL (%s)\n" % ",".join(fails))
    sys.exit(1)
print("math_parity: PASS (%d rows + determinism)" % len(rows))
PYEOF
