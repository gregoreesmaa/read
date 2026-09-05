#!/bin/sh
# Render-interaction fuzzer (see AGENTS.md rendering stability requirements).
#
# Plays with the interaction dimensions that broke the renderer in 2026-09
# (scroll offsets incl. the 800px checkpoint boundary and rubber-band zone,
# selections incl. inverted/empty/off-document boxes, drag-backs incl.
# degenerate A==B/collapse/clear, partial damage rects, 1x vs 2x scale) and
# checks each against a cheap independent oracle:
#   - no crash (exit 0 on every combination, incl. negative/huge scrolls),
#   - determinism (same args twice render byte-identical pixels),
#   - scroll invariance (shared text runs keep identical doc geometry across
#     small scroll steps; a jump is the "text jumped around" bug class),
#   - incremental parity (1x select-drag phases equal fresh renders exactly;
#     at 2x same-selection repaints are idempotent and the incremental path
#     is deterministic; extends damage_parity.sh into wilder inputs),
#   - scale invariance (record geometry identical at 1x and 2x),
#   - atlas capacity (no flush rows on a scale-2 sweep; pins the 2026-09
#     flush-storm fix).
#
# Deterministic seeds: failures reproduce exactly. Headless renders only;
# live-only paths (AppKit dirty-clip, GPU present) are out of scope.
#
# Usage: scripts/fuzz_render.sh [binary] [markdown-file] [count]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read}"
DOC="${2:-showcase.md}"
N="${3:-12}"

probe_hooks() {
    out=$("$1" --screenshot /tmp/fuzz_probe.png --dump-records "$DOC" 2>&1) || return 1
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

fail=0
deny() { echo "FAIL: $1"; fail=1; }

render() {
    # $1 = output, $2 = args word list; pacing keeps AppKit launches
    # deterministic (see damage_parity.sh). --settle-images drains async
    # image decodes first so layout (image heights) is identical across the
    # throwaway processes this script spawns; without it, a load completing
    # mid-suite shifts content and every cross-render comparison misfires.
    # One retry: rapid back-to-back AppKit launches intermittently die in
    # LaunchServices startup before our code runs (environmental, not a
    # renderer bug); a genuine crash fails twice and is still reported.
    out=$1; args=$2
    sleep 0.3
    # shellcheck disable=SC2086
    "$BIN" --screenshot "$out" --settle-images $args "$DOC" >/dev/null 2>&1 || {
        echo "warn: render died once, retrying ($args)"
        sleep 0.3
        # shellcheck disable=SC2086
        "$BIN" --screenshot "$out" --settle-images $args "$DOC" >/dev/null 2>&1 || deny "render exited nonzero twice ($args)"
    }
}

SEP=$(printf '\037')

# --- deterministic offset stream: neighbor pairs -----------------------------
# Each base offset is followed by base+7.5 so consecutive renders overlap
# heavily and the invariance check below has teeth. Buckets: uniform,
# fractional, checkpoint-boundary cluster, extremes, negative rubber-band.
awk -v n="$N" '
    BEGIN {
        srand(20260906);
        for (k = 0; k < n; k++) {
            r = rand();
            b = r * 4;
            if (b < 1) base = int(r * 9200) - 200 + (r * 10 - int(r * 10));
            else if (b < 2) base = 796 + r * 10;
            else if (b < 3) base = (k % 2 == 0) ? 0 : 8500;
            else base = -(r * 200) + 0.5;
            printf "%.1f\n%.1f\n", base, base + 7.5;
        }
    }' > /tmp/fuzz_off.txt

# --- A. scroll fuzz: crash-freedom + determinism + invariance -----------------
echo "--- scroll fuzz ---"
i=0
prev=""
while read -r off; do
    i=$((i + 1))
    render /tmp/fuzz_a.png "--scroll $off --settle-images"
    render /tmp/fuzz_b.png "--scroll $off --settle-images"
    cmp -s /tmp/fuzz_a.png /tmp/fuzz_b.png || deny "scroll $off not deterministic"
    # uniquely-occurring texts with doc-space geometry for the jump check
    sleep 0.3
    # shellcheck disable=SC2086
    "$BIN" --screenshot /tmp/fuzz_d.png --settle-images --scroll $off --dump-commands "$DOC" 2>&1 \
        | awk -v s="$off" -v q="$SEP" '
            /^CMD text_run/ {
                k = index($0, "txt=\x27");
                t = substr($0, k + 5); sub(/\x27$/, "", t);
                printf "%s%s%.1f%s%s\n", t, q, $4 + s, q, $5;
            }' | sort > /tmp/fuzz_all.txt
    awk -F"$SEP" '{ print $1 }' /tmp/fuzz_all.txt | uniq -u > /tmp/fuzz_uniq.txt
    awk -F"$SEP" 'NR==FNR { u[$1]=1; next } ($1 in u)' /tmp/fuzz_uniq.txt /tmp/fuzz_all.txt | sort > "/tmp/fuzz_geo_$i.txt"
    # Invariance runs on pair mates only (offsets N-1,N are 7.5px apart by
    # construction, so shared texts are the same instances; across buckets
    # the same string may be a different occurrence entirely).
    if [ $((i % 2)) = 0 ]; then
        bad=$(join -t "$SEP" "$prev" "/tmp/fuzz_geo_$i.txt" 2>/dev/null \
            | awk -F"$SEP" '$2 != $4 || $3 != $5 { c++ } END { print c + 0 }')
        [ "${bad:-0}" = "0" ] || deny "scroll $off shifted shared text geometry (jump)"
    fi
    prev="/tmp/fuzz_geo_$i.txt"
done < /tmp/fuzz_off.txt
echo "scroll cases=$i ok"

# --- B/C. shared record pool + selection/drag streams -------------------------
pool=/tmp/fuzz_pool.txt
: > "$pool"
for _s in 0 2000 4000 6000; do
    sleep 0.3
    "$BIN" --screenshot /tmp/fuzz_dump.png --settle-images --scroll "$_s" "$DOC" --dump-commands 2>&1 \
        | awk '/^CMD text_run/{print $3, $4+'$_s', $5, $6}' >> "$pool"
done
nrec=$(wc -l < "$pool" | tr -d ' ')
[ "$nrec" -ge 40 ] || deny "record pool too small ($nrec)"

# rows: scroll ax1 ay1 ax2 ay2 cov cover-flag
awk -v n="$N" '
    BEGIN {
        srand(20260907);
        while ((getline line < "/tmp/fuzz_pool.txt") > 0) {
            split(line, f);
            rx[++m] = f[1]; ry[m] = f[2]; rw[m] = f[3]; rh[m] = f[4];
        }
        for (g = 0; g < n; g++) {
            i = 1 + int(rand() * m);
            j = 1 + int(rand() * m);
            if (g % 2 == 0) {
                ax = rx[i] + rand() * rw[i]; ay = ry[i] + rand() * rh[i];
                bx = rx[j] + rand() * rw[j]; by = ry[j] + rand() * rh[j];
                cov = 1;
            } else {
                ax = rand() * 1400 - 100; ay = rand() * 9000 - 500;
                bx = rand() * 1400 - 100; by = rand() * 9000 - 500;
                cov = 0;
            }
            lo = (ay < by ? ay : by);
            s = lo - 200; if (s < -200) s = -200; if (s > 9000) s = 9000;
            printf "%d %.1f %.1f %.1f %.1f %d\n", s, ax, ay, bx, by, cov;
        }
    }' > /tmp/fuzz_sel.txt

echo "--- selection fuzz ---"
gn=0
while read -r gs ax1 ay1 ax2 ay2 cov; do
    gn=$((gn + 1))
    render /tmp/fuzz_s1.png "--scroll $gs --select $ax1,$ay1,$ax2,$ay2"
    render /tmp/fuzz_s2.png "--scroll $gs --select $ax1,$ay1,$ax2,$ay2"
    cmp -s /tmp/fuzz_s1.png /tmp/fuzz_s2.png || deny "select $gn not deterministic ($ax1,$ay1,$ax2,$ay2)"
    if [ "$cov" = "1" ]; then
        render /tmp/fuzz_sp.png "--scroll $gs"
        cmp -s /tmp/fuzz_s1.png /tmp/fuzz_sp.png && deny "select $gn painted no highlight over covered text"
    fi
done < /tmp/fuzz_sel.txt
echo "select cases=$gn ok"

echo "--- drag fuzz ---"
gn=0
while read -r gs ax1 ay1 ax2 ay2 _cov; do
    gn=$((gn + 1))
    # B variants: shrink, identity (A==B), caret collapse, clear, overshoot.
    # Offset by one so an even (2x) gesture hits the A==B idempotence case.
    case $(((gn + 1) % 5)) in
        0) B="$ax1,$ay1,$ax2,$ay2" ;;
        1) B="$ax1,$ay1,$ax1,$ay1" ;;
        2) B="0,0,0,0" ;;
        3) B="$ax1,$ay1,$(awk -v a="$ax2" -v b="$ax1" 'BEGIN{print 2*a-b}'),$(awk -v a="$ay2" -v b="$ay1" 'BEGIN{print 2*a-b}')" ;;
        *) B="$ax1,$ay1,$(awk -v a="$ax1" -v b="$ax2" 'BEGIN{print a+(b-a)*0.4}'),$(awk -v a="$ay1" -v b="$ay2" 'BEGIN{print a+(b-a)*0.4}')" ;;
    esac
    sc2=""
    if [ $((gn % 2)) = 0 ]; then sc2="--force-scale 2"; fi
    A="$ax1,$ay1,$ax2,$ay2"
    render /tmp/fuzz_diri.png "--scroll $gs $sc2 --select-drag $A,$B"
    cp /tmp/drag_phase_1.png /tmp/fuzz_ph1.png
    cp /tmp/drag_phase_2.png /tmp/fuzz_ph2.png
    if [ -z "$sc2" ]; then
        # 1x: incremental repaints must equal fresh renders pixel-exactly
        # (residue, fringe, and seam classes).
        render /tmp/fuzz_frA.png "--scroll $gs --select $A"
        if [ "$B" = "0,0,0,0" ]; then
            render /tmp/fuzz_frB.png "--scroll $gs"
        else
            render /tmp/fuzz_frB.png "--scroll $gs --select $B"
        fi
        cmp -s /tmp/fuzz_ph1.png /tmp/fuzz_frA.png || deny "drag $gn extend differs (scroll=$gs A=$A)"
        cmp -s /tmp/fuzz_ph2.png /tmp/fuzz_frB.png || deny "drag $gn shrink differs (scroll=$gs A=$A B=$B)"
    else
        # 2x: CoreGraphics rounds masked blits under a damage clip up to
        # 1 LSB differently than unclipped (measured, stable, invisible),
        # so incremental-vs-fresh cannot be byte-exact. The flicker-relevant
        # properties still hold exactly: same-selection repaints are
        # idempotent (no accumulation across frames) and the incremental
        # path is deterministic across processes.
        render /tmp/fuzz_diri2.png "--scroll $gs $sc2 --select-drag $A,$B"
        cmp -s /tmp/fuzz_ph2.png /tmp/drag_phase_2.png || deny "drag $gn incremental path not deterministic (scroll=$gs)"
        if [ "$B" = "$A" ]; then
            cmp -s /tmp/fuzz_ph1.png /tmp/fuzz_ph2.png || deny "drag $gn same-selection repaint not idempotent (scroll=$gs)"
        fi
    fi
done < /tmp/fuzz_sel.txt
echo "drag cases=$gn ok"

# --- D. damage fuzz: record invariance under hostile rects --------------------
echo "--- damage fuzz ---"
full=$(sleep 0.3; "$BIN" --screenshot /tmp/fuzz_full.png --settle-images --dump-records "$DOC" 2>&1 | sed -n 's/^Text records rebuilt: \([0-9][0-9]*\)$/\1/p')
awk -v n="$N" '
    BEGIN {
        srand(60609);
        for (k = 0; k < n; k++) {
            printf "%.1f %.1f %.1f %.1f\n", rand()*1400-100, rand()*1000-50, rand()*1300-50, rand()*1000-50;
        }
    }' > /tmp/fuzz_rect.txt
i=0
while read -r dx dy dw dh; do
    i=$((i + 1))
    n=$(sleep 0.3; "$BIN" --screenshot /tmp/fuzz_dmg.png --settle-images --damage "$dx,$dy,$dw,$dh" --dump-records "$DOC" 2>&1 | sed -n 's/^Text records rebuilt: \([0-9][0-9]*\)$/\1/p')
    [ "$n" = "$full" ] || deny "damage $dx,$dy,$dw,$dh rebuilt $n records, want $full"
done < /tmp/fuzz_rect.txt
echo "damage cases=$i full=$full ok"

# --- E. scale invariance: geometry must not depend on raster scale -----------
echo "--- scale invariance ---"
for _s in 0 1500 4500; do
    sleep 0.3
    "$BIN" --screenshot /tmp/fuzz_c1.png --settle-images --scroll "$_s" "$DOC" --dump-commands 2>&1 | grep "^CMD text_run" | sort > /tmp/fuzz_c1.txt
    sleep 0.3
    "$BIN" --screenshot /tmp/fuzz_c2.png --settle-images --scroll "$_s" --force-scale 2 "$DOC" --dump-commands 2>&1 | grep "^CMD text_run" | sort > /tmp/fuzz_c2.txt
    cmp -s /tmp/fuzz_c1.txt /tmp/fuzz_c2.txt || deny "record geometry differs between 1x and 2x at scroll $_s"
done
echo "scale geometry identical ok"

# --- F. atlas capacity: scale-2 sweep must not flush -------------------------
echo "--- atlas capacity ---"
sleep 0.3
sweep_out=$("$BIN" --screenshot /tmp/fuzz_sweep.png --settle-images --force-scale 2 --scroll-sweep 0,8000,500 "$DOC" 2>&1)
rows=$(printf '%s\n' "$sweep_out" | grep -c '^SWEEP' || true)
flushed=$(printf '%s\n' "$sweep_out" | grep '^SWEEP' | grep -c 'flush=[1-9]' || true)
echo "sweep rows=$rows flushed=${flushed:-0}"
[ "${flushed:-0}" = "0" ] || deny "$flushed sweep rows flushed the atlas (working set exceeds capacity)"

if [ "$fail" = 0 ]; then
    echo "PASS: fuzz clean (scroll/select/drag/damage/scale/atlas, N=$N)"
fi
exit $fail
