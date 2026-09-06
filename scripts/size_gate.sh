#!/bin/sh
# Binary footprint gate (see AGENTS.md §1: executable strictly under 180 KiB).
#
# Fails when the ship binary reaches 180 KiB (184320 bytes). Also reports
# __TEXT headroom to the next 16 KiB page: __TEXT is page-padded in the
# file, so even a few dozen bytes of growth can cost a full 16 KiB page
# (observed 2026-09: +988 B of __text became +17 KiB of file). A headroom
# warning is advisory, not a failure — but treat it as a diet order for
# the next platform-glue change. New ship code belongs at end-of-file
# (see the SIZE NOTE on prime_frame_decode in src/platform/macos.m).
#
# Usage: scripts/size_gate.sh [binary]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read}"
[ -f "$BIN" ] || { echo "FAIL: binary not found: $BIN"; exit 2; }

bytes=$(stat -f%z "$BIN")
textseg=$(size -m "$BIN" 2>/dev/null | sed -n 's/^Segment __TEXT: \([0-9][0-9]*\).*/\1/p')
pages=$(( (textseg + 16383) / 16384 ))
headroom=$(( pages * 16384 - textseg ))

echo "binary=$bytes bytes __TEXT=$textseg headroom=${headroom}B"

fail=0
if [ "$bytes" -ge 184320 ]; then
    echo "FAIL: ship binary is $bytes bytes (>= 180 KiB budget)"
    fail=1
fi
if [ "$headroom" -lt 512 ]; then
    echo "WARN: only ${headroom}B of __TEXT headroom to the next page; the next glue change likely costs 16 KiB"
fi

if [ "$fail" = 0 ]; then
    echo "PASS: binary footprint under 180 KiB"
fi
exit $fail
