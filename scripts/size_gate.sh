#!/bin/sh
# Two-account binary footprint gate (see AGENTS.md §7: the ship binary
# carries a core account and a plugin account, measured via the
# differential twin).
#
# Builds the ship binary and its no-plugins twin, then compares __TEXT
# segment bytes (never file bytes — page padding lies: file bytes can jump
# a full 16 KiB page on a few dozen bytes of __text):
#   plugin_bytes = __TEXT(ship) - __TEXT(twin)
#   core_bytes   = __TEXT(ship) - plugin_bytes (= __TEXT(twin))
# FAILs when core exceeds CORE_BUDGET or plugin exceeds PLUGIN_BUDGET.
# Also reports __TEXT headroom to the next 16 KiB page: a headroom warning
# is advisory, not a failure — but treat it as a diet order for the next
# platform-glue change. New ship code belongs at end-of-file (see the SIZE
# NOTE on prime_frame_decode in src/platform/macos.m).
#
# Usage: scripts/size_gate.sh [ship-binary]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read}"
TWIN="zig-out/twin/read-noplugins"
OPTIMIZE="${SIZE_GATE_OPTIMIZE:-ReleaseFast}"

# Budgets (see AGENTS.md §7 budget history).
CORE_BUDGET=$((200 * 1024))
# Plugin account: twin-measured 8062 bytes on 2026-09-12 + 4 KiB headroom,
# rounded up to a whole KiB.
PLUGIN_BUDGET_KIB=12
PLUGIN_BUDGET=$((PLUGIN_BUDGET_KIB * 1024))

# Build both accounts; zig-cache incrementality makes this a fast no-op
# when artifacts are current (no caching hacks here).
zig build -Doptimize="$OPTIMIZE"
zig build -Doptimize="$OPTIMIZE" -Dplugin_stub=true

[ -f "$BIN" ] || { echo "FAIL: ship binary not found: $BIN"; exit 2; }
[ -f "$TWIN" ] || { echo "FAIL: twin binary not found: $TWIN"; exit 2; }

textseg() {
    size -m "$1" 2>/dev/null | sed -n 's/^Segment __TEXT: \([0-9][0-9]*\).*/\1/p'
}

ship_text=$(textseg "$BIN")
twin_text=$(textseg "$TWIN")
[ -n "$ship_text" ] || { echo "FAIL: no __TEXT segment in $BIN"; exit 2; }
[ -n "$twin_text" ] || { echo "FAIL: no __TEXT segment in $TWIN"; exit 2; }

plugin=$((ship_text - twin_text))
[ "$plugin" -ge 0 ] || { echo "FAIL: twin __TEXT ($twin_text) exceeds ship __TEXT ($ship_text)"; exit 2; }
core=$((ship_text - plugin))

bytes=$(stat -f%z "$BIN")
pages=$(( (ship_text + 16383) / 16384 ))
headroom=$(( pages * 16384 - ship_text ))

echo "core=$core bytes plugin=$plugin bytes total __TEXT=$ship_text bytes (file=$bytes bytes)"
echo "budgets: core<=$CORE_BUDGET plugin<=$PLUGIN_BUDGET"

fail=0
if [ "$core" -gt "$CORE_BUDGET" ]; then
    echo "FAIL: core account is $core bytes (> $CORE_BUDGET = 200 KiB budget)"
    fail=1
fi
if [ "$plugin" -gt "$PLUGIN_BUDGET" ]; then
    echo "FAIL: plugin account is $plugin bytes (> $PLUGIN_BUDGET = ${PLUGIN_BUDGET_KIB} KiB budget)"
    fail=1
fi
if [ "$headroom" -lt 512 ]; then
    echo "WARN: only ${headroom}B of __TEXT headroom to the next page; the next glue change likely costs 16 KiB"
fi

if [ "$fail" = 0 ]; then
    echo "PASS: core and plugin accounts within budget"
fi
exit $fail
