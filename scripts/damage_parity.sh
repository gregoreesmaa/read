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
    # Pacing: rapid back-to-back AppKit launches intermittently die inside
    # LaunchServices startup (_LSContextInitCommon, before our code runs).
    # A short pause between renders keeps the suite deterministic.
    sleep 0.3
    # shellcheck disable=SC2086
    "$BIN" --screenshot "$1" --settle-images --scroll 0 $2 "$DOC" >/dev/null 2>&1
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

# Drag-back residue: an incremental repaint (selection A painted full, then
# shrunk to B with drag damage on the same bitmap, exactly like a live
# mouseDragged frame) must equal a fresh full render of B (2026-09
# regression: unclipped repaints accumulated extra coats on boundary
# antialiased pixels, reading as flicker and deselect residue).
shot /tmp/parity_drag_inc.png "--select-drag 300,320,800,420,350,330,600,345"
shot /tmp/parity_drag_fresh.png "--select 350,330,600,345"
if ! cmp -s /tmp/parity_drag_inc.png /tmp/parity_drag_fresh.png; then
    echo "FAIL: drag-back incremental repaint differs from fresh render (residue)"
    fail=1
fi

# Collapse-to-caret: shrinking A down to a ~2px caret must also repaint clean.
shot /tmp/parity_drag_inc2.png "--select-drag 300,320,800,420,500,335,502,336"
shot /tmp/parity_drag_fresh2.png "--select 500,335,502,336"
if ! cmp -s /tmp/parity_drag_inc2.png /tmp/parity_drag_fresh2.png; then
    echo "FAIL: drag-back collapse repaint differs from fresh render (residue)"
    fail=1
fi

# Release-to-clear: dragging back to the anchor clears the selection on
# release (4px rule) with the old box as the only damage. A zero B selects
# this path in the hook; the fresh reference is a plain render.
shot /tmp/parity_drag_inc3.png "--select-drag 300,280,800,400,0,0,0,0"
shot /tmp/parity_drag_fresh3.png ""
if ! cmp -s /tmp/parity_drag_inc3.png /tmp/parity_drag_fresh3.png; then
    echo "FAIL: release-to-clear repaint differs from fresh render (residue)"
    fail=1
fi

# Heading geometry: 46px records against the 24px damage pad (worst
# overhang case) at live 2x scale. Must also repaint clean.
shot /tmp/parity_drag_inc4.png "--force-scale 2 --select-drag 300,150,700,220,350,150,500,145"
shot /tmp/parity_drag_fresh4.png "--force-scale 2 --select 350,150,500,145"
if ! cmp -s /tmp/parity_drag_inc4.png /tmp/parity_drag_fresh4.png; then
    echo "FAIL: heading-geometry drag repaint differs (residue)"
    fail=1
fi

# Randomized drag-back sweep: 20 gestures at random places across the
# document (2026-09: live deselect residue hit only on SOME gestures, so
# fixed gestures kept passing while users saw blue fringe). Deterministic
# seed so failures reproduce. Each gesture checks BOTH incremental phases
# against fresh renders: phase 2 (drag-back shrink) catches residue, phase
# 1 (extend) catches missing-fringe highlight flicker. Half the gestures
# snap endpoints near record edges / adjacent lines to hunt the
# inclusion-band and narrow-span damage traps; the rest are fully random.
# Doc-space text_run rects pooled from several scroll offsets.
dump_recs() {
    # $1 = scroll; prints doc-space text_run rects: x y w h
    sleep 0.3
    "$BIN" --screenshot /tmp/sweep25_dump.png --settle-images --scroll "$1" "$DOC" --dump-commands 2>&1 \
        | awk '/^CMD text_run/{print $3, $4+'"$1"', $5, $6}'
}

pool=/tmp/sweep25_pool.txt
: > "$pool"
for _s in 0 1500 3000 4500 6000 7500; do
    dump_recs "$_s" >> "$pool"
done
nrec=$(wc -l < "$pool" | tr -d ' ')
if [ "$nrec" -lt 40 ]; then
    echo "FAIL: record pool too small ($nrec)"
    fail=1
fi

# gestures.txt rows: scroll ax1 ay1 ax2 ay2 bx1 by1 bx2 by2 (doc space;
# 0,0,0,0 B means release-to-clear). Built by awk with a fixed seed.
awk -v n="$nrec" '
    BEGIN {
        srand(20260905);
        while ((getline line < "/tmp/sweep25_pool.txt") > 0) {
            split(line, f);
            rx[++m] = f[1]; ry[m] = f[2]; rw[m] = f[3]; rh[m] = f[4];
        }
        for (g = 0; g < 20; g++) {
            i = 1 + int(rand() * m);
            # partner: nearby record (same neighborhood so A fits on screen)
            j = i;
            tries = 0;
            while (tries++ < 50) {
                k = 1 + int(rand() * m);
                if (k != i && (ry[k] > ry[i] - 450 && ry[k] < ry[i] + 450)) { j = k; break; }
            }
            if (j == i) j = (i % m) + 1;
            if (g >= 10) {
                # trap-hunting half: adjacent line below, endpoints hugging
                # the shared boundary (narrow y-span, full-width highlight).
                best = j; bd = 1e9;
                for (k = 1; k <= m; k++) {
                    if (ry[k] > ry[i] + 5 && ry[k] - ry[i] < bd) { bd = ry[k] - ry[i]; best = k; }
                }
                j = best;
                ax = rx[i] + rw[i] * (0.5 + rand() * 0.5);
                ay = ry[i] + rh[i] - 1 - rand() * 4;
                bx = rx[j] + rw[j] * rand() * 0.5;
                by = ry[j] + 1 + rand() * 4;
            } else {
                # fully random half: endpoints anywhere in the records,
                # sometimes snapped within the +-4px inclusion band.
                ax = rx[i] + rand() * rw[i];
                ay = ry[i] + rand() * rh[i];
                if (rand() < 0.5) ay = (rand() < 0.5 ? ry[i] : ry[i] + rh[i]) + (rand() * 10 - 5);
                bx = rx[j] + rand() * rw[j];
                by = ry[j] + rand() * rh[j];
                if (rand() < 0.5) by = (rand() < 0.5 ? ry[j] : ry[j] + rh[j]) + (rand() * 10 - 5);
            }
            lo = (ay < by ? ay : by); hi = (ay > by ? ay : by);
            # B: drag-back shrink toward A-start (sometimes collapse/clear).
            r = rand();
            if (r < 0.15) {
                cx1 = ax; cy1 = ay; cx2 = ax + 2; cy2 = ay + 2;
            } else if (r < 0.25) {
                cx1 = 0; cy1 = 0; cx2 = 0; cy2 = 0;
            } else {
                t = 0.15 + rand() * 0.6;
                cx1 = ax; cy1 = ay;
                cx2 = ax + (bx - ax) * t; cy2 = ay + (by - ay) * t;
            }
            s = lo - 200; if (s < 0) s = 0; if (s > 8000) s = 8000;
            printf "%d %.1f %.1f %.1f %.1f %.1f %.1f %.1f %.1f\n",
                s, ax, ay, bx, by, cx1, cy1, cx2, cy2;
        }
    }' > /tmp/sweep25_gestures.txt
ngest=$(wc -l < /tmp/sweep25_gestures.txt | tr -d ' ')
echo "sweep gestures=$ngest pool=$nrec"
if [ "$ngest" -ne 20 ]; then
    echo "FAIL: gesture generator produced $ngest rows, want 20"
    fail=1
fi

gn=0
while read -r gs ax1 ay1 ax2 ay2 bx1 by1 bx2 by2; do
    gn=$((gn + 1))
    drag="--scroll $gs --select-drag $ax1,$ay1,$ax2,$ay2,$bx1,$by1,$bx2,$by2"
    sleep 0.3
    # shellcheck disable=SC2086
    "$BIN" --screenshot /tmp/sweep25_inc.png --settle-images $drag "$DOC" >/dev/null 2>&1
    if [ "$bx1" = "0" ] && [ "$by1" = "0" ] && [ "$bx2" = "0" ] && [ "$by2" = "0" ]; then
        fresh_b=""
    else
        fresh_b="--select $bx1,$by1,$bx2,$by2"
    fi
    sleep 0.3
    # shellcheck disable=SC2086
    "$BIN" --screenshot /tmp/sweep25_freshB.png --settle-images --scroll $gs $fresh_b "$DOC" >/dev/null 2>&1
    sleep 0.3
    # shellcheck disable=SC2086
    "$BIN" --screenshot /tmp/sweep25_freshA.png --settle-images --scroll $gs --select $ax1,$ay1,$ax2,$ay2 "$DOC" >/dev/null 2>&1
    if ! cmp -s /tmp/drag_phase_2.png /tmp/sweep25_freshB.png; then
        echo "FAIL: gesture $gn drag-back residue (scroll=$gs A=$ax1,$ay1,$ax2,$ay2 B=$bx1,$by1,$bx2,$by2)"
        fail=1
    fi
    if ! cmp -s /tmp/drag_phase_1.png /tmp/sweep25_freshA.png; then
        echo "FAIL: gesture $gn extend-phase fringe differs (scroll=$gs A=$ax1,$ay1,$ax2,$ay2)"
        fail=1
    fi
done < /tmp/sweep25_gestures.txt

if [ "$fail" = 0 ]; then
    echo "PASS: record model is damage-invariant, pixels stable, selection deterministic, drag-back clean (20-gesture sweep)"
fi
exit $fail
