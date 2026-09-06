#!/bin/sh
# select_clip.sh — selection highlight must stay inside scroll-container
# cards (code blocks, tables). The painter runs outside the graphics-state
# clip, so unclipped fills paint past text that was clipped away (used to
# draw a blue bar across the full window past the card edge).
# Pure pixel ground truth via --probe-px on test_cases/code_and_tasks.md
# (1200x900 at --force-scale 1). Card: x=288..912, y=225.8..406.9; the
# stdout.print line (view y=342.5, h=26.2) overflows the card to the right.
set -u
BIN="${HOOKS_BIN:-zig-out/bin/read-test}"
DOC="test_cases/code_and_tasks.md"
OUT="${TMPDIR:-/tmp}/select_clip.png"

shot() {
    # $1 = select, $2... = extra args; prints PROBE lines
    # shellcheck disable=SC2086
    "$BIN" --screenshot "$OUT" --force-scale 1 --scroll 0 \
        --select "$1" $2 "$DOC" 2>&1 | grep '^PROBE'
}

fail=0
check() {
    # $1 = description, $2 = want(blue|clean), rest = PROBE lines
    desc=$1; want=$2; shift 2
    echo "$@" | while read -r line; do
        rgb=$(echo "$line" | sed 's/.*=//; s/,255$//')
        r=$(echo "$rgb" | cut -d, -f1); b=$(echo "$rgb" | cut -d, -f3)
        tint=$((b - r))
        if [ "$want" = blue ]; then
            [ "$tint" -ge 40 ] || echo "FAIL: $desc: $line tint=$tint, want >= 40"
        else
            [ "$tint" -le 10 ] || echo "FAIL: $desc: $line tint=$tint, want <= 10"
        fi
    done
}

echo "--- case1: long code line highlight ends at card edge"
P1=$(shot "300,342,1200,369" "--probe-px=800,355 --probe-px=905,355 --probe-px=912,355 --probe-px=920,355")
echo "$P1" | grep -q PROBE || { echo "FAIL: case1 render failed"; exit 1; }
R1=$(check "case1 inside" blue "$(echo "$P1" | head -2)")
R1c=$(check "case1 past-edge" clean "$(echo "$P1" | tail -2)")
[ -n "$R1$R1c" ] && { echo "$R1$R1c"; fail=1; } || echo "case1: PASS (inside blue to the edge, past-edge clean)"

echo "--- case2: whole-card select stays inside card"
P2=$(shot "280,220,920,410" "--probe-px=800,355 --probe-px=920,355 --probe-px=930,250")
echo "$P2" | grep -q PROBE || { echo "FAIL: case2 render failed"; exit 1; }
R2=$(check "case2 inside" blue "$(echo "$P2" | head -1)")
R2c=$(check "case2 outside" clean "$(echo "$P2" | tail -2)")
[ -n "$R2$R2c" ] && { echo "$R2$R2c"; fail=1; } || echo "case2: PASS (card interior blue, exterior clean)"

[ "$fail" = 1 ] && { echo "select_clip: FAIL"; exit 1; }
echo "select_clip: PASS (both cases)"
