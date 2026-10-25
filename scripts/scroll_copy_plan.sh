#!/bin/sh
# Scroll-copy plan (expose-copy residue rules without a window).
#
# A live scroll frame bit-blits the overlapping pixels (scrollRect:by:)
# and repaints only the exposed strip. Three residue rules harden that
# path: the copy delta is quantized to whole device pixels (a fractional
# shift would resample the whole backing store every frame, and the next
# frame would copy the resampled pixels again — drift that reads as
# residue); a nonzero rubber-band overshoot takes a full repaint (its
# whole-scene translate makes any copy stale at both edges); and a 2pt
# seam band repaints the copy/strip boundary the quantized copy and the
# exact-offset layout paint from opposite sides of. This queries the plan
# (dy,scale,view_h,overshoot) and pins the contract: use_copy, quantized
# copy delta, seam band origin and height.
#
# Usage: scripts/scroll_copy_plan.sh [binary]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read-test}"

probe_hooks() {
    out=$("$1" --screenshot /tmp/plan_probe.png --probe-scroll-plan=40,2,900,0 showcase.md 2>&1) || return 1
    echo "$out" | grep -q '^SCROLLPLAN='
}

if ! probe_hooks "$BIN"; then
    echo "note: $BIN lacks test hooks; building a fresh binary (read-test carries the hooks)"
    : "${ZIG_GLOBAL_CACHE_DIR:=$PWD/.zig-cache-global}"
    export ZIG_GLOBAL_CACHE_DIR
    HOOKS_BIN="${TMPDIR:-/tmp}/read-hooks-$$/bin/read-test"
    zig build -Doptimize=ReleaseFast --prefix "${TMPDIR:-/tmp}/read-hooks-$$" >&2
    BIN="$HOOKS_BIN"
    probe_hooks "$BIN" || { echo "FAIL: hooks binary still reports no plan"; exit 2; }
fi

check_plan() {
    # $1 = "dy,scale,view_h,overshoot" $2 = "use,copy,band_y,band_h" $3 = label
    # NOTE: --screenshot stays on the command line so the binary takes the
    # headless path and exits (flag-only invocations launch the GUI loop).
    # shellcheck disable=SC2086
    GOT=$("$BIN" --screenshot /tmp/plan_scratch.png --probe-scroll-plan="$1" showcase.md 2>&1 | grep '^SCROLLPLAN=' | head -n 1 | cut -d= -f2)
    [ -n "$GOT" ] || { echo "FAIL: $3: no SCROLLPLAN answer"; exit 1; }
    python3 - "$3" "$GOT" "$2" <<'EOF'
import sys
label, got, want = sys.argv[1], sys.argv[2], sys.argv[3]
g = [float(v) for v in got.split(',')]
w = [float(v) for v in want.split(',')]
ok = len(g) == 4 and len(w) == 4 and all(abs(a - b) <= 0.015 for a, b in zip(g, w))
print('%s: got=%s want=%s' % (label, got, want))
if not ok:
    print('FAIL: %s plan mismatch' % label)
    sys.exit(1)
print('PASS: %s' % label)
EOF
}

# Integer scroll: exact copy, seam band atop the exposed bottom strip.
check_plan "40,2,900,0" "1,40.00,858.00,2.00" "down 40pt @2x"
# Upward scroll mirrors: band below the exposed top strip.
check_plan "-40,2,900,0" "1,-40.00,40.00,2.00" "up 40pt @2x"
# Fractional glide step: copy quantized to whole device pixels.
check_plan "40.37,2,900,0" "1,40.50,857.50,2.00" "fractional down @2x"
check_plan "0.30,2,900,0" "1,0.50,897.50,2.00" "sub-point nudge @2x"
# Sub-device-pixel nudge: rounds to zero, full repaint instead.
check_plan "0.10,2,900,0" "0,0.00,0.00,0.00" "sub-pixel nudge @2x"
# Rubber-band overshoot: whole-scene translate, full repaint (both edges).
check_plan "40,2,900,3" "0,0.00,0.00,0.00" "overshoot down @2x"
check_plan "-40,2,900,-3" "0,0.00,0.00,0.00" "overshoot up @2x"
# No shared pixels / nothing moved: full repaint.
check_plan "900,2,900,0" "0,0.00,0.00,0.00" "full-height jump"
check_plan "0,2,900,0" "0,0.00,0.00,0.00" "zero delta"
# 1x backing: whole points are already device pixels.
check_plan "40.37,1,900,0" "1,40.00,858.00,2.00" "fractional down @1x"
