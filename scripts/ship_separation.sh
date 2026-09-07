#!/bin/sh
# Ship/test separation proof (see AGENTS.md §1 Lean Production Build).
#
# The ship binary (`read`) must contain zero headless test CLI: every
# `--*` flag is rejected with exit 2 before any platform code runs, and
# no hook flag literal (--screenshot, --scroll-sweep, --damage,
# --dump-*, --select*, --probe-px=, --force-scale, --settle-images,
# --scroll-x-end) survives the comptime gate in `src/main.zig` into the
# ship bytes. The read-test binary carries the hooks; this script pins
# that both directions hold.
#
# Usage: scripts/ship_separation.sh [ship-binary] [hooks-binary] [doc]
set -eu

cd "$(dirname "$0")/.."

SHIP="${1:-zig-out/bin/read}"
HOOKS="${2:-zig-out/bin/read-test}"
DOC="${3:-showcase.md}"

[ -f "$SHIP" ] || { echo "FAIL: ship binary not found: $SHIP"; exit 2; }

fail=0
deny() { echo "FAIL: $1"; fail=1; }

# 1. Ship rejects every hook-shaped flag with exit 2 and writes nothing.
rm -f /tmp/ship_sep_probe.png
for flag in --screenshot --scroll --scroll-x-end --scroll-sweep --damage \
    --dump-records --dump-commands --settle-images --select --select-drag \
    --force-scale "--probe-px=1,1"; do
    # Never pass a document path: a bare doc would launch the GUI.
    if "$SHIP" "$flag" /tmp/ship_sep_probe.png >/dev/null 2>&1; then
        deny "ship binary accepted $flag (want exit 2)"
    else
        code=$?
        [ "$code" = "2" ] || deny "ship binary exited $code on $flag (want 2)"
    fi
done
[ ! -f /tmp/ship_sep_probe.png ] || deny "ship binary wrote output for a hook flag"
rm -f /tmp/ship_sep_probe.png

# 2. No hook flag literal in the ship bytes (comptime gate stripped them).
for lit in --screenshot --scroll-sweep --dump-records --dump-commands \
    --settle-images --probe-px= --select-drag --force-scale --scroll-x-end; do
    if grep -q -a -F -- "$lit" "$SHIP"; then
        deny "ship binary contains hook literal $lit"
    fi
done

# 3. The hooks binary still answers (guards against "proving" separation
# by deleting the hooks instead of gating them). Headless only.
if [ -f "$HOOKS" ]; then
    out=$("$HOOKS" --screenshot /tmp/ship_sep_hooks.png --dump-records "$DOC" 2>&1) || \
        deny "hooks binary failed its own probe"
    printf '%s\n' "$out" | grep -q '^Text records rebuilt: [0-9][0-9]*$' || \
        deny "hooks binary reports no record count"
    rm -f /tmp/ship_sep_hooks.png
else
    echo "note: hooks binary not found ($HOOKS); skipping hooks-alive check"
fi

if [ "$fail" = 0 ]; then
    echo "PASS: ship binary carries no test hooks; hooks binary alive"
fi
exit $fail
