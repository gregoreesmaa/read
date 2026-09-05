#!/bin/sh
# Damage parity regression test (see src/layout/damage.zig).
#
# The text-record model backing selection/hover/link painting must be
# rebuilt identically on full and partial-damage draws. If partial damage
# ever starves it again, record counts diverge and this fails.
#
# Usage: scripts/damage_parity.sh [binary] [markdown-file]
#
# The --damage/--select/--dump-records probes only exist in -Dtest-hooks=true
# builds (ship builds compile them out for size). When BIN lacks hooks, build
# a throwaway hooks binary automatically; the draw/record code under test is
# identical in both (TEST_HOOKS only adds setters plus the pending-damage
# override and the record-count getter).
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read}"
DOC="${2:-showcase.md}"

probe_hooks() {
    # $1 = binary; succeeds iff it reports a rebuilt record count
    out=$("$1" --screenshot /tmp/parity_probe.png --dump-records "$DOC" 2>&1) || return 1
    printf '%s\n' "$out" | grep -q '^Text records rebuilt: [0-9][0-9]*$'
}

if ! probe_hooks "$BIN"; then
    echo "note: $BIN lacks test hooks; building a throwaway -Dtest-hooks=true binary"
    : "${ZIG_GLOBAL_CACHE_DIR:=$PWD/.zig-cache-global}"
    export ZIG_GLOBAL_CACHE_DIR
    HOOKS_BIN="${TMPDIR:-/tmp}/read-hooks-$$/bin/read"
    zig build -Doptimize=ReleaseFast -Dtest-hooks=true --prefix "${TMPDIR:-/tmp}/read-hooks-$$" >&2
    BIN="$HOOKS_BIN"
    probe_hooks "$BIN" || { echo "FAIL: hooks binary still reports no record count"; exit 2; }
fi

records() {
    # $1 = extra args; prints the rebuilt text-record count
    # shellcheck disable=SC2086
    out=$("$BIN" --screenshot /tmp/parity_probe.png --dump-records $1 "$DOC" 2>&1)
    n=$(printf '%s\n' "$out" | sed -n 's/^Text records rebuilt: \([0-9][0-9]*\)$/\1/p')
    if [ -z "$n" ]; then
        echo "FAIL: could not read record count (binary error?). Output was:"
        printf '%s\n' "$out"
        exit 2
    fi
    printf '%s' "$n"
}

full=$(records "")
partial=$(records "--damage 680,100,80,60")
partial_sel=$(records "--damage 680,100,80,60 --select 300,320,800,420")

echo "full=$full partial=$partial partial+select=$partial_sel"

fail=0
if [ "$full" != "$partial" ]; then
    echo "FAIL: partial damage changed rebuilt record count ($full vs $partial)"
    fail=1
fi
if [ "$full" != "$partial_sel" ]; then
    echo "FAIL: partial damage + selection changed rebuilt record count ($full vs $partial_sel)"
    fail=1
fi

shot() {
    # $1 = output png, rest = extra args; render headless at scroll 0
    # shellcheck disable=SC2086
    "$BIN" --screenshot "$1" --scroll 0 $2 "$DOC" >/dev/null 2>&1
}

# Pixel stability: a damage rect covering the whole view must repaint every
# pixel exactly as the plain full render does (2026-09 flicker regression:
# partial draws dropped or moved pixels near damage edges).
shot /tmp/parity_plain.png ""
shot /tmp/parity_fulldmg.png "--damage 0,0,1200,900"
if ! cmp -s /tmp/parity_plain.png /tmp/parity_fulldmg.png; then
    echo "FAIL: full-view damage render differs pixel-wise from plain render"
    fail=1
fi

# Selection rendering determinism: the same --select capture twice must be
# byte-identical (2026-09 regression: multi-row highlight painted a bare
# start-end rectangle / flickered between frames).
shot /tmp/parity_sel_a.png "--select 300,320,800,420"
shot /tmp/parity_sel_b.png "--select 300,320,800,420"
if ! cmp -s /tmp/parity_sel_a.png /tmp/parity_sel_b.png; then
    echo "FAIL: repeated selection captures differ"
    fail=1
fi

if [ "$fail" = 0 ]; then
    echo "PASS: record model is damage-invariant, pixels stable, selection deterministic"
fi
exit $fail
