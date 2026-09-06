#!/bin/sh
# Scroll-stutter + image regression tests on showcase.md (see AGENTS.md §6).
#
# Root causes pinned (2026-09, profiled via --scroll-sweep):
#  1. ImageIO defers full pixel decode until first draw: 3-11ms main-thread
#     hitch per newly visible image. Fixed by force-decoding every frame on
#     the background load queue at load time. Gate: primed == total frames.
#  2. SVG never rendered: the failed ImageIO attempt poisoned rec->failed
#     before the NSImage vector fallback ran. Gate: SVG card pixel colors.
#  3. Scroll layout must stay viewport-cheap at every offset. Gate:
#     layout_us bound on every sweep row (generous; pure-CPU work).
#
# Per-frame paint timings are REPORTED, not gated: wall-clock gates flake
# on loaded machines. The priming gate above is the structural pin for the
# stutter fix (unprimed frames decode on the scroll thread).
#
# Usage: scripts/scroll_profile.sh [binary] [markdown-file]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read-test}"
DOC="${2:-showcase.md}"

probe_hooks() {
    # $1 = binary; succeeds iff it reports a rebuilt record count
    out=$("$1" --screenshot /tmp/scroll_probe.png --dump-records "$DOC" 2>&1) || return 1
    printf '%s\n' "$out" | grep -q '^Text records rebuilt: [0-9][0-9]*$'
}

if ! probe_hooks "$BIN"; then
    echo "note: $BIN lacks test hooks; building a fresh binary (read-test carries the hooks)"
    : "${ZIG_GLOBAL_CACHE_DIR:=$PWD/.zig-cache-global}"
    export ZIG_GLOBAL_CACHE_DIR
    HOOKS_BIN="${TMPDIR:-/tmp}/read-hooks-$$/bin/read-test"
    zig build -Doptimize=ReleaseFast --prefix "${TMPDIR:-/tmp}/read-hooks-$$" >&2
    BIN="$HOOKS_BIN"
    probe_hooks "$BIN" || { echo "FAIL: hooks binary still reports no record count"; exit 2; }
fi

fail=0

# --- 1. Settle drains: every showcase image loads (nothing stuck/failed) ---
settle_out=$("$BIN" --screenshot /tmp/scroll_probe.png --settle-images --dump-records "$DOC" 2>&1)
settle=$(printf '%s\n' "$settle_out" | sed -n 's/^SETTLE pending=\([0-9][0-9]*\) elapsed_ms=[0-9][0-9]*$/\1/p')
if [ -z "$settle" ]; then
    echo "FAIL: no SETTLE status line. Output was:"
    printf '%s\n' "$settle_out"
    exit 2
fi
echo "settle pending=$settle"
if [ "$settle" != "0" ]; then
    echo "FAIL: images still pending after settle ($settle left: load stuck or failed)"
    fail=1
fi

# --- 2. Decode priming: every loaded frame force-decoded off-main ---
primed_line=$(printf '%s\n' "$settle_out" | sed -n 's/^Image frames primed: \([0-9][0-9]*\)\/\([0-9][0-9]*\)$/\1 \2/p')
primed=$(printf '%s' "$primed_line" | awk '{print $1}')
total=$(printf '%s' "$primed_line" | awk '{print $2}')
if [ -z "$primed_line" ]; then
    echo "FAIL: no primed-frames line. Output was:"
    printf '%s\n' "$settle_out"
    exit 2
fi
echo "primed frames: $primed/$total"
if [ "$primed" != "$total" ]; then
    echo "FAIL: $((total - primed)) frames not primed: first scroll into them decodes on the main thread (stutter)"
    fail=1
fi
if [ "$total" -lt 9 ]; then
    echo "FAIL: only $total frames for 9 showcase images (a load regressed to failed)"
    fail=1
fi

# --- 3. SVG renders: card pixel must be gradient purple, not bg/placeholder --
# Pacing: see damage_parity.sh (rapid launches flake in LS startup).
sleep 0.3
svg_out=$("$BIN" --screenshot /tmp/scroll_svg.png --settle-images --scroll 4500 \
    --probe-px=540,750 --probe-px=540,800 "$DOC" 2>&1)
svga=$(printf '%s\n' "$svg_out" | sed -n 's/^PROBE 540,750=\([0-9]*\),\([0-9]*\),\([0-9]*\),[0-9]*$/\1 \2 \3/p')
svgb=$(printf '%s\n' "$svg_out" | sed -n 's/^PROBE 540,800=\([0-9]*\),\([0-9]*\),\([0-9]*\),[0-9]*$/\1 \2 \3/p')
echo "svg px 540,750=($svga) 540,800=($svgb)"
inrange() { # $1=val $2=lo $3=hi
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
svg_ok=1
set -- $svga
if [ $# -ne 3 ] || ! inrange "$1" 100 230 || ! inrange "$2" 40 140 || ! inrange "$3" 170 255; then
    svg_ok=0
fi
if [ "$svg_ok" != "1" ]; then
    echo "FAIL: SVG card pixel out of gradient range (SVG fallback broken again?)"
    fail=1
fi

# --- 4. Sweep: every offset renders; layout stays microsecond-grade -------
sleep 0.3
sweep_out=$("$BIN" --screenshot /tmp/scroll_sweep.png --settle-images \
    --scroll-sweep 0,8000,500 "$DOC" 2>&1)
rows=$(printf '%s\n' "$sweep_out" | grep -c '^SWEEP' || true)
echo "sweep rows=$rows"
if [ "$rows" -ne 17 ]; then
    echo "FAIL: expected 17 sweep rows (0..8000 step 500), got $rows"
    fail=1
fi
max_layout=$(printf '%s\n' "$sweep_out" | sed -n 's/^SWEEP .* layout_us=\([0-9][0-9]*\) .*$/\1/p' | sort -n | tail -1)
echo "max layout_us=$max_layout"
if [ -n "$max_layout" ] && [ "$max_layout" -gt 1000 ]; then
    echo "FAIL: layout exceeded microsecond budget (viewport virtualization regressed?)"
    fail=1
fi
# Report (not gated): worst paint rows; image-region frames must not spike
# the way unprimed first-draws did (3-21ms before the priming fix).
echo "--- slowest paint rows (report only) ---"
printf '%s\n' "$sweep_out" | sed -n 's/^SWEEP \(off=[0-9]*\) \(layout_us=[0-9]*\) \(paint_us=[0-9]*\) .*/\1 \3/p' | sort -t= -k3 -n | tail -5

if [ "$fail" = 0 ]; then
    echo "PASS: settle drains, all frames primed, SVG pixels correct, sweep layout bounded"
fi
exit $fail
