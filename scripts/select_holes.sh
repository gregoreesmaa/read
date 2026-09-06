#!/bin/sh
# select_holes.sh — selection-highlight hole/residue regression suite.
# Pure pixel ground truth via --probe-px (no log parsing: deterministic
# under concurrent live sessions). Headless geometry for
# markdown-testfile.md is stable: 1200x900 at --force-scale 1.
#
# Case 1: full single-line select over the "tags" paragraph line paints
# every word (xrow/xfirst/xlast/bridge + trailing-edge clamp).
# Case 2: collapsed caret in the inter-line gap paints nothing (used to
# take the middle branch and paint whole lines -> residue + holes).
# Case 3: 7px micro-drag in the inter-line slop paints nothing (used to
# paint six full words whose partial clear punched holes in residue).
# Case 4: endpoint inside a run paints the covered gaps (endpoint in a
# run's first pixels maps to an empty char range; the old consecutive
# bridge left the covered gap dark).
# Case 5: endpoint inside a gap paints the covered part, nothing past it.
# Case 6: endpoint in the taller run's overhang keeps the whole endpoint
# row (mixed serif/mono heights orphaned the shorter run).
# Case 7: full-span control over the inline-code row (middle branch).
# Case 8: first-line mirror of case 4 (start inside a run paints covered
# gaps right of it, nothing left of it).
set -u
BIN="${HOOKS_BIN:-zig-out/bin/read-test}"
DOC="${1:-markdown-testfile.md}"
OUT="${TMPDIR:-/tmp}/select_holes.png"

shot() {
    # $1 = select, $2... = extra args; prints PROBE lines
    # shellcheck disable=SC2086
    "$BIN" --screenshot "$OUT" --force-scale 1 --settle-images $2 \
        --select "$1" "$DOC" 2>&1 | grep '^PROBE'
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

echo "--- case1: full-line select paints every word"
P1=$(shot "0,1380,1000,1380" "--scroll 1010 --probe-px=350,370 --probe-px=450,370 --probe-px=517,370 --probe-px=600,370 --probe-px=660,370 --probe-px=770,370 --probe-px=600,300")
echo "$P1" | grep -q PROBE || { echo "FAIL: case1 render failed"; echo "$P1" | head -3; exit 1; }
R1=$(check "case1 word" blue "$(echo "$P1" | head -6)")
R1c=$(check "case1 control" clean "$(echo "$P1" | tail -1)")
[ -n "$R1$R1c" ] && { echo "$R1$R1c"; fail=1; } || echo "case1: PASS (6 words tinted, control clean)"

echo "--- case2: gap caret paints nothing"
P2=$(shot "393,1393,393,1393" "--scroll 1010 --probe-px=350,370 --probe-px=517,370 --probe-px=660,370")
echo "$P2" | grep -q PROBE || { echo "FAIL: case2 render failed"; exit 1; }
R2=$(check "case2 gap-caret" clean "$P2")
[ -n "$R2" ] && { echo "$R2"; fail=1; } || echo "case2: PASS (gap caret clean)"

echo "--- case3: slop micro-drag paints nothing"
P3=$(shot "384,6638,391,6638" "--scroll 6271 --probe-px=350,342 --probe-px=499,342")
echo "$P3" | grep -q PROBE || { echo "FAIL: case3 render failed"; exit 1; }
R3=$(check "case3 slop-micro" clean "$P3")
[ -n "$R3" ] && { echo "$R3"; fail=1; } || echo "case3: PASS (slop micro clean)"

echo "--- case4: endpoint inside run paints covered gaps"
P4=$(shot "300,2600,525,2678" "--scroll 2000 --probe-px=521,677 --probe-px=428,677 --probe-px=535,677")
echo "$P4" | grep -q PROBE || { echo "FAIL: case4 render failed"; exit 1; }
R4=$(check "case4 covered-gap" blue "$(echo "$P4" | head -2)")
R4c=$(check "case4 past-end" clean "$(echo "$P4" | tail -1)")
[ -n "$R4$R4c" ] && { echo "$R4$R4c"; fail=1; } || echo "case4: PASS (endpoint-in-run gaps blue, past-end clean)"

echo "--- case5: endpoint inside gap paints covered part"
P5=$(shot "300,2600,521.5,2678" "--scroll 2000 --probe-px=520,677 --probe-px=428,677 --probe-px=535,677 --probe-px=525,677")
echo "$P5" | grep -q PROBE || { echo "FAIL: case5 render failed"; exit 1; }
R5=$(check "case5 covered-gap" blue "$(echo "$P5" | head -2)")
R5c=$(check "case5 past-end" clean "$(echo "$P5" | tail -2)")
[ -n "$R5$R5c" ] && { echo "$R5$R5c"; fail=1; } || echo "case5: PASS (endpoint-in-gap covered blue, past-end clean)"

echo "--- case6: endpoint in taller-run overhang keeps whole row"
P6=$(shot "300,2688.30,900,2800" "--scroll 2000 --probe-px=521,677 --probe-px=428,677 --probe-px=535,677")
echo "$P6" | grep -q PROBE || { echo "FAIL: case6 render failed"; exit 1; }
R6=$(check "case6 overhang-row" blue "$P6")
[ -n "$R6" ] && { echo "$R6"; fail=1; } || echo "case6: PASS (overhang endpoint paints full row)"

echo "--- case7: full-span control over code-span row"
P7=$(shot "0,2500,1000,2800" "--scroll 2000 --probe-px=521,677 --probe-px=428,677 --probe-px=535,677")
echo "$P7" | grep -q PROBE || { echo "FAIL: case7 render failed"; exit 1; }
R7=$(check "case7 full-span" blue "$P7")
[ -n "$R7" ] && { echo "$R7"; fail=1; } || echo "case7: PASS (full span paints every gap)"

echo "--- case8: first-line start inside run"
P8=$(shot "525,2678,900,2800" "--scroll 2000 --probe-px=535,677 --probe-px=521,677")
echo "$P8" | grep -q PROBE || { echo "FAIL: case8 render failed"; exit 1; }
R8=$(check "case8 covered-gap" blue "$(echo "$P8" | head -1)")
R8c=$(check "case8 before-start" clean "$(echo "$P8" | tail -1)")
[ -n "$R8$R8c" ] && { echo "$R8$R8c"; fail=1; } || echo "case8: PASS (first-line gap blue, before-start clean)"

[ "$fail" = 1 ] && { echo "select_holes: FAIL"; exit 1; }
echo "select_holes: PASS (all eight cases)"
