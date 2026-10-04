#!/usr/bin/env bash
set -euo pipefail

# Read: Visual Regression Screenshot Engine
# 1. Enforces all unit tests & strict microsecond benchmarks pass
# 2. Captures headless frame captures of distinct test documents for PR visual comparison

OUTPUT_DIR="${1:-screenshots}"
mkdir -p "$OUTPUT_DIR"

# Plugin-cache root shared by the suite and the test binary (the seeding
# cp below must land where read-test's stat-exists lookup probes).
suite_cache_root() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            # Windows: the exe never sees MSYS's HOME/TMPDIR synthesis, so
            # pluginCacheRoot falls to "/tmp/..." which normalize_path
            # drive-roots to C:\tmp (GitHub runners and dev boxes are C:).
            # MSYS's own /tmp lives elsewhere — seeding there never resolves.
            printf '/c/tmp/read-plugin-cache'
            ;;
        *)
            if [ -n "${HOME:-}" ]; then printf '%s/Library/Caches' "$HOME";
            else printf '%s/read-plugin-cache' "${TMPDIR:-/tmp}"; fi
            ;;
    esac
}

echo "Step 1: Running all tests and strict benchmarks (ReleaseFast)..."
# Engine-absent gate: the suite pins engine-absent skips here (same
# stance as the CI strict-gate step). The live engine enters only for
# the captures below (Step 3 exports READ_LIVE_MATH per-shot; the
# backend loads $READ_ZATEX_LIB there). Scrub the ambient env so a
# CI-exported engine path cannot leak live behavior into the gate.
env -u READ_ZATEX_LIB -u ZATEX_TEST_DYLIB zig build test -Doptimize=ReleaseFast --summary all

echo "Step 2: Building Read executable in ReleaseFast mode..."
zig build -Doptimize=ReleaseFast

# Slim mode (CI: CI_SUITE=slim): the high-impact subset only — showcase
# docs + states, one highlight language, one frame per plugin renderer,
# live math, images, RTL, and the single scrollable-doc case. Drops: the
# 19 extra highlight languages, plugin tall/wide/scrolled companions,
# math_scrolled_bottom + math gallery, and all mdtest scroll sweeps
# (~120 → 25 PNGs per OS). Full mode (default) is unchanged below.
run_slim() {
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/text_wrapping.png" test_cases/text_wrapping.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/spacings_headings.png" test_cases/spacings_headings.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/code_and_tasks.png" test_cases/code_and_tasks.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/code_and_tasks_hanging_indent.png" --scroll 800 test_cases/code_and_tasks.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/list_indent_text.png" test_cases/list_indent_text.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/list_indent_code.png" test_cases/list_indent_code.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/tables_formatting.png" test_cases/tables_formatting.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/code_and_tasks_scroll_end.png" --scroll-x-end test_cases/code_and_tasks.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/tables_formatting_scroll_end.png" --scroll-x-end test_cases/tables_formatting.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_fallback.png" test_cases/plugin_fallback.md
    # Math, LIVE (READ_LIVE_MATH opts the test binary into the ship math
    # path; every other capture below stays fallback-pinned — highlight.md
    # and plugin_fallback.md contain $ fences whose committed shots must
    # stay literal). Requires the engine from the CI engine-build step
    # ($READ_ZATEX_LIB in CI, system path locally); without one these
    # two fall back and differ from baseline (loud, not silent).
    READ_LIVE_MATH=1 ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math.png" test_cases/math.md
    READ_LIVE_MATH=1 ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math_scrolled.png" --scroll 400 test_cases/math.md
    # Plugin seeds (same fence-hash + cache pre-seed as the full flow;
    # one renderer per shot, initial fold only).
    command -v python3 >/dev/null 2>&1 || { echo "FAIL: slim needs python3 for fence hashing" >&2; exit 1; }
    cache_root="$(suite_cache_root)"
    slim_seed_mermaid() {
        seed_hash=$(python3 - "test_cases/plugin_mermaid.md" <<'EOF'
import sys
lines = open(sys.argv[1]).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == ['mermaid'])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in (0).to_bytes(1, 'big') + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
        [ -n "$seed_hash" ] || { echo "FAIL: slim mermaid fence hash empty" >&2; exit 1; }
        mkdir -p "$cache_root/read/plugins/mermaid"
        cp test_cases/assets/mermaid-seed.png "$cache_root/read/plugins/mermaid/$seed_hash.png"
    }
    slim_seed_ordinal() {
        # $1 = md file, $2 = info token, $3 = renderer, $4 = seed png, $5 = plugin dir
        slim_hash=$(python3 - src/core/plugin_cache.zig "$1" "$2" "$3" <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
        [ -n "$slim_hash" ] || { echo "FAIL: slim $3 fence hash empty" >&2; exit 1; }
        mkdir -p "$cache_root/read/plugins/$5"
        cp "$4" "$cache_root/read/plugins/$5/$slim_hash.png"
    }
    slim_seed_mermaid
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_mermaid.png" --settle-images test_cases/plugin_mermaid.md
    slim_seed_ordinal test_cases/plugin_d2.md d2 d2 test_cases/assets/d2-seed.png d2
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_d2.png" --settle-images test_cases/plugin_d2.md
    slim_seed_ordinal test_cases/plugin_graphviz.md dot graphviz test_cases/assets/graphviz-seed.png graphviz
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_graphviz.png" --settle-images test_cases/plugin_graphviz.md
    slim_seed_ordinal test_cases/plugin_plantuml.md plantuml plantuml test_cases/assets/plantuml-seed.png plantuml
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_plantuml.png" --settle-images test_cases/plugin_plantuml.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/admonitions.png" test_cases/admonitions.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_zig.png" test_cases/highlight.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/bare_links.png" test_cases/bare_links.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/frontmatter.png" test_cases/frontmatter.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/scrollable_doc.png" --scroll 500 test_cases/scrollable_doc.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/images.png" test_cases/images.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/images_settled.png" --settle-images test_cases/images.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/images_scrolled.png" --scroll 450 test_cases/images.md
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/rtl_bidi.png" test_cases/rtl_bidi.md
}

if [ "${CI_SUITE:-}" = "slim" ]; then
    echo "Step 3 (slim): Capturing high-impact subset into $OUTPUT_DIR..."
    run_slim
    echo "Slim screenshot captures complete in $OUTPUT_DIR:"
    ls -lh "$OUTPUT_DIR"
    exit 0
fi

echo "Step 3: Capturing distinct visual regression test cases into $OUTPUT_DIR..."

# Case 1: Text wrapping, typography, inline styling, max reading width 600px, line-height 1.75
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/text_wrapping.png" test_cases/text_wrapping.md

# Case 2: Hierarchical spacings, heading margins (top 2.5em, bottom 0.5em), blockquotes, horizontal rules
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/spacings_headings.png" test_cases/spacings_headings.md

# Case 3: Code blocks, syntax background card, copy button, task checkboxes, lists
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/code_and_tasks.png" test_cases/code_and_tasks.md

# Case 3b: Hanging-indent continuations at the end of the SAME doc (no new
# test case): scrolled viewport frames the section so reviewers see sub-4sp
# continuations aligned under the lead text, never the marker.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/code_and_tasks_hanging_indent.png" --scroll 800 test_cases/code_and_tasks.md

# Cases 3c/3d: Multi-level indenting 0-5 in dedicated files (PR #324
# review: split from code_and_tasks.md so each frame shows one clean
# section). A no-indent comparison paragraph (3c) / fence (3d) heads each
# file; 3c covers bullets 0-5 plus ordered 0-2 continuations, 3d the
# nested-fence code levels 0-5 (nested fence promotion + relative
# code-level cutoff).
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/list_indent_text.png" test_cases/list_indent_text.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/list_indent_code.png" test_cases/list_indent_code.md

# Case 4: Table structure, cell padding, column alignment, dividers
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/tables_formatting.png" test_cases/tables_formatting.md

# Cases 4b/4c: End-scrolled horizontal state of the SAME docs above (no new
# test cases, no new test_cases/*.md files): every block parked at its max
# via --scroll-x-end, so the shadow sits on the left edge with reversed
# rounding. Vertical viewport stays initial, so scrollable_doc.md remains
# the single scrolled-viewport test.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/code_and_tasks_scroll_end.png" --scroll-x-end test_cases/code_and_tasks.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/tables_formatting_scroll_end.png" --scroll-x-end test_cases/tables_formatting.md

# Case 4d: Plugin fallback rendering (RFC #41) — unknown plugin fences render
# as plain code blocks, source intact.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_fallback.png" test_cases/plugin_fallback.md

# Case 4d2/4d3/4d4: Math via ZaTeX, LIVE renders (not fallback). These three
# shots are generated with libzatex.dylib installed (/usr/local/lib;
# temporarily force liveMathSizeFn on in a scratch build — never committed
# — or run a live ship build) and committed so reviewers see real typeset
# output. Regenerating without the dylib silently downgrades the trio to
# the literal/code-card fallback: unit tests (stub engine) plus the backend
# oracle still pin the fallback path. Do NOT run the full suite with a
# live engine: highlight.md, plugin_fallback.md and others contain `$` or
# ```math fences whose committed shots must stay fallback-pinned.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math.png" test_cases/math.md
# Case 4d3: Same-file scrolled frame (no new test case, scrollable_doc.md
# stays the single scrolled-viewport case): --scroll 400 frames the Display
# gallery heading plus both display lines for reviewers.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math_scrolled.png" --scroll 400 test_cases/math.md
# Case 4d4: Same-file bottom frame: --scroll 700 frames the guards tail,
# the full Display gallery, and the Literal gallery through the document
# end for reviewers.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math_scrolled_bottom.png" --scroll 700 test_cases/math.md
# Case 4d5/4d6/4d7/4d8: Math gallery (test_cases/math_gallery.md), LIVE
# renders like the trio above (same scratch-live procedure, never
# committed): a wider sweep — nesting, accents, delimiters, display
# blocks, matrix — for spotting renderer issues. Same fallback warning
# applies; do NOT shoot these with a live full-suite run for the same
# reason as 4d2. One frame per section (highlight fixed-offset
# precedent): title/nesting (4d5), the full Accents section incl. the
# MATH-table italic-correction rows (4d6), delimiters into Display head
# (4d7), and the display/matrix bottom (4d8).
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math_gallery.png" test_cases/math_gallery.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math_gallery_scrolled.png" --scroll 450 test_cases/math_gallery.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math_gallery_delimiters.png" --scroll 900 test_cases/math_gallery.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/math_gallery_bottom.png" --scroll 1350 test_cases/math_gallery.md

# Case 4e: Mermaid rendered image (issue #323) — read-test never probes or
# launches, so the suite pre-seeds the cache PNG for the fixture fence and
# the headless open resolves it to ready via the shipped stat-exists path
# (no child processes); --settle-images decodes it through the stock image
# path. Seed pixels are the synthetic test_cases/assets/mermaid-seed.png
# fixture (no mermaid renderer binary in this env); the path proven is
# production. Unseeded docs (case 4d) keep a null table, bit-identical.
command -v python3 >/dev/null 2>&1 || { echo "FAIL: case 4e needs python3 for fence hashing" >&2; exit 1; }
FIXTURE_MD="test_cases/plugin_mermaid.md"
seed_hash=$(python3 - "$FIXTURE_MD" <<'EOF'
import sys
lines = open(sys.argv[1]).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == ['mermaid'])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in (0).to_bytes(1, 'big') + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$seed_hash" ] || { echo "FAIL: case 4e fence hash empty" >&2; exit 1; }
cache_root="$(suite_cache_root)"
mkdir -p "$cache_root/read/plugins/mermaid"
cp test_cases/assets/mermaid-seed.png "$cache_root/read/plugins/mermaid/$seed_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_mermaid.png" --settle-images test_cases/plugin_mermaid.md

# Cases 4f/4g/4h: Huge mermaid diagrams (issue #323, PR #340 owner request).
# Same-file scrolled frames (images_scrolled precedent: no new test case,
# no new test_cases/*.md), so scrollable_doc.md stays the single
# scrolled-viewport test case per AGENTS.md §6 / check_test_cases.sh.
# 4f (huge source): 20 mermaid fences reuse mermaid-seed.png; only the
# first 16 reach ready (explicit MAX_PLUGIN_JOBS truncation, pinned by the
# "collect stops at 16" unit test in plugin_cache.zig) while fences 17-20
# stay plain code cards below the fold. 4g (huge rendered image): the
# 476x3140 mermaid-seed-tall.png — a genuinely complex 26-node flowchart
# (branches/joins, decision diamonds, bypass rail) mirroring the fixture
# node-for-node — proves oversize-image geometry (width clamp/fit via
# laidOutImageHeight, scrollbar/height math, no blowup) across the initial
# viewport plus three --scroll frames covering middle/deep/bottom.
# Both seed through the shipped stat-exists path with zero child processes.
command -v python3 >/dev/null 2>&1 || { echo "FAIL: cases 4f/4g need python3 for fence hashing" >&2; exit 1; }
cache_root="$(suite_cache_root)"
mkdir -p "$cache_root/read/plugins/mermaid"
many_hashes=$(python3 - "test_cases/plugin_mermaid_many.md" <<'EOF'
import sys
lines = open(sys.argv[1]).read().split('\n')
i = 0
hashes = []
while i < len(lines):
    if lines[i].lstrip().startswith('```') and lines[i].lstrip()[3:].strip().split(' ')[:1] == ['mermaid']:
        start = i
        end = next(j for j in range(start + 1, len(lines)) if lines[j].lstrip().startswith('```'))
        src = '\n'.join(lines[start + 1:end]).encode()
        h = 0xCBF29CE484222325
        M = (1 << 64) - 1
        for b in (0).to_bytes(1, 'big') + b'\x00' + src:
            h ^= b
            h = (h * 0x100000001B3) & M
        hashes.append('%016x' % h)
        i = end + 1
    else:
        i += 1
print('\n'.join(hashes))
EOF
)
[ "$(printf '%s\n' "$many_hashes" | wc -l | tr -d ' ')" = "20" ] || { echo "FAIL: case 4f wants 20 fence hashes" >&2; exit 1; }
for h in $many_hashes; do cp test_cases/assets/mermaid-seed.png "$cache_root/read/plugins/mermaid/$h.png"; done
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_mermaid_many.png" --settle-images test_cases/plugin_mermaid_many.md
tall_hash=$(python3 - "test_cases/plugin_mermaid_tall.md" <<'EOF'
import sys
lines = open(sys.argv[1]).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == ['mermaid'])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in (0).to_bytes(1, 'big') + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$tall_hash" ] || { echo "FAIL: case 4g fence hash empty" >&2; exit 1; }
cp test_cases/assets/mermaid-seed-tall.png "$cache_root/read/plugins/mermaid/$tall_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_mermaid_tall.png" --settle-images test_cases/plugin_mermaid_tall.md
# Below-fold frames of the SAME tall doc via the existing --scroll
# mechanism (no src/ changes, no new test case): offsets 900/1800/2700
# step through the 3140px render (viewport 900) to the bottom frame.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_mermaid_tall__s1.png" --scroll 900 --settle-images test_cases/plugin_mermaid_tall.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_mermaid_tall__s2.png" --scroll 1800 --settle-images test_cases/plugin_mermaid_tall.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_mermaid_tall__s3.png" --scroll 2700 --settle-images test_cases/plugin_mermaid_tall.md
# Case 4h (wide rendered image): the 2000x600 mermaid-seed-wide.png — a
# genuinely complex 22-node `flowchart LR` (15 columns across top/main/
# bottom lanes, fan-out/join buses, decision diamonds, bypass rail)
# mirroring the fixture node-for-node — proves the wide-image clamp
# (natural width fits to the 600px column via laidOutImageHeight, aspect
# kept, no blowup) through the shipped stat-exists path. Initial fold
# only, by design: ready-plugin `.image` cmds carry no scrollable_id, so
# neither --scroll (vertical doc scroll; the whole band already fits one
# fold) nor --scroll-x-end (parks code/table blocks only) can add signal.
wide_hash=$(python3 - "test_cases/plugin_mermaid_wide.md" <<'EOF'
import sys
lines = open(sys.argv[1]).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == ['mermaid'])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in (0).to_bytes(1, 'big') + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$wide_hash" ] || { echo "FAIL: case 4h fence hash empty" >&2; exit 1; }
cp test_cases/assets/mermaid-seed-wide.png "$cache_root/read/plugins/mermaid/$wide_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_mermaid_wide.png" --settle-images test_cases/plugin_mermaid_wide.md
# Case 4i: Admonition alerts (issue #325) — `> [!KIND]` leaders swap the
# marker for a bold tinted label and recolor the quote bar per kind.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/admonitions.png" test_cases/admonitions.md

# Case 4j: Syntax-highlight demo (issue #333) — one frame per language.
# Sections are uniform (H3 + 5-line fence, blank-separated), so fixed-stride
# scrolled frames seat one language per PNG (mermaid-tall fixed-offset
# precedent). Stride 280.9px measured from layout (H3 rows at doc y 269.5 /
# 550.4); each frame puts its H3 ~120px below the top, prior tail above.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_zig.png" test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_c.png" --scroll 430 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_python.png" --scroll 711 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_js.png" --scroll 992 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_bash.png" --scroll 1273 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_diff.png" --scroll 1554 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_ts.png" --scroll 1835 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_rust.png" --scroll 2116 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_go.png" --scroll 2397 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_java.png" --scroll 2678 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_ruby.png" --scroll 2958 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_swift.png" --scroll 3239 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_kotlin.png" --scroll 3520 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_php.png" --scroll 3801 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_cpp.png" --scroll 4082 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_csharp.png" --scroll 4363 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_html.png" --scroll 4644 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_css.png" --scroll 4925 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_sql.png" --scroll 5206 test_cases/highlight.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/highlight_lua.png" --scroll 5487 test_cases/highlight.md

# Case 4j: D2 rendered image (issue #330) — read-test never probes or
# launches; the suite pre-seeds the cache PNG for the fixture fence and
# the headless open resolves it to ready via the shipped stat-exists path
# (no child processes); --settle-images decodes it through the stock image
# path. Seed pixels are genuine d2 0.9.0 output for the fixture source
# (test_cases/assets/d2-seed.png; regenerate with
# scripts/gen-plugin-seeds.py, which shells out to the real d2 binary);
# the path proven is production. The fence hash mirrors
# fenceHash in src/core/plugin_cache.zig with the renderer ordinal parsed
# from the Renderer enum, so seeds stay correct as the enum grows.
d2_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_d2.md d2 d2 <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
# Case 4j: Graphviz rendered image (issue #329) — read-test never probes
# or launches; the suite pre-seeds the cache PNG for the fixture fence and
# the headless open resolves it to ready via the shipped stat-exists path
# (no child processes); --settle-images decodes it through the stock image
# path. Seed pixels are genuine dot 16.0.0 output for the fixture source
# (test_cases/assets/graphviz-seed.png; regenerate with
# scripts/gen-plugin-seeds.py, which shells out to the real dot binary);
# the path proven is production. The fence hash mirrors
# fenceHash in src/core/plugin_cache.zig with the renderer ordinal parsed
# from the Renderer enum, so seeds stay correct as the enum grows.
graphviz_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_graphviz.md dot graphviz <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
# Case 4k: PlantUML rendered image (issue #328) — read-test never probes
# or launches; the suite pre-seeds the cache PNG for the fixture fence and
# the headless open resolves it to ready via the shipped stat-exists path
# (no child processes); --settle-images decodes it through the stock image
# path. Seed pixels are genuine PlantUML 1.2026.8 output for the fixture
# source (test_cases/assets/plantuml-seed.png; regenerate with
# scripts/gen-plugin-seeds.py, which shells out to the real plantuml
# binary); the path proven is production. The fence hash mirrors
# fenceHash in src/core/plugin_cache.zig with the renderer ordinal parsed
# from the Renderer enum, so seeds stay correct as the enum grows.
plantuml_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_plantuml.md plantuml plantuml <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$d2_hash" ] || { echo "FAIL: case 4i fence hash empty" >&2; exit 1; }
cache_root="$(suite_cache_root)"
mkdir -p "$cache_root/read/plugins/d2"
cp test_cases/assets/d2-seed.png "$cache_root/read/plugins/d2/$d2_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_d2.png" --settle-images test_cases/plugin_d2.md

# Tall companion (same case 4j): d2-seed-tall.png is the genuine d2 0.9.0
# render (1804x6894) of the 22-node direction:down tall fixture; two
# scrolled frames walk the full display height (the real render fits in
# initial + 800 + 1600, so no third frame: 2400 showed only trailing
# sliver plus empty viewport).
tall_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_d2_tall.md d2 d2 <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$tall_hash" ] || { echo "FAIL: d2 tall fence hash empty" >&2; exit 1; }
cp test_cases/assets/d2-seed-tall.png "$cache_root/read/plugins/d2/$tall_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_d2_tall.png" --settle-images test_cases/plugin_d2_tall.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_d2_tall__s1.png" --settle-images --scroll 800 test_cases/plugin_d2_tall.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_d2_tall__s2.png" --settle-images --scroll 1600 test_cases/plugin_d2_tall.md

# Wide companion (same case 4j): d2-seed-wide.png is the genuine d2 0.9.0
# render (5914x1040) of the 15-node direction:right wide fixture.
# Initial fold only, by design: ready-plugin `.image` cmds carry no
# scrollable_id, so neither --scroll nor --scroll-x-end can add signal
# (mermaid-wide 4h precedent).
wide_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_d2_wide.md d2 d2 <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$wide_hash" ] || { echo "FAIL: d2 wide fence hash empty" >&2; exit 1; }
cp test_cases/assets/d2-seed-wide.png "$cache_root/read/plugins/d2/$wide_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_d2_wide.png" --settle-images test_cases/plugin_d2_wide.md
[ -n "$graphviz_hash" ] || { echo "FAIL: case 4j fence hash empty" >&2; exit 1; }
cache_root="$(suite_cache_root)"
mkdir -p "$cache_root/read/plugins/graphviz"
cp test_cases/assets/graphviz-seed.png "$cache_root/read/plugins/graphviz/$graphviz_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_graphviz.png" --settle-images test_cases/plugin_graphviz.md

# Tall companion (same case 4j): graphviz-seed-tall.png is the genuine
# dot 16.0.0 render (705x2065) of the 22-node rankdir=TB tall fixture
# (ellipses are dot's default node shape); two scrolled frames walk the
# full display height (the real render fits in initial + 800 + 1600, so
# no third frame: 2400 showed only trailing sliver plus empty viewport).
tall_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_graphviz_tall.md dot graphviz <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$tall_hash" ] || { echo "FAIL: graphviz tall fence hash empty" >&2; exit 1; }
cp test_cases/assets/graphviz-seed-tall.png "$cache_root/read/plugins/graphviz/$tall_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_graphviz_tall.png" --settle-images test_cases/plugin_graphviz_tall.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_graphviz_tall__s1.png" --settle-images --scroll 800 test_cases/plugin_graphviz_tall.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_graphviz_tall__s2.png" --settle-images --scroll 1600 test_cases/plugin_graphviz_tall.md

# Wide companion (same case 4j): graphviz-seed-wide.png is the genuine
# dot 16.0.0 render (2465x181) of the 15-node rankdir=LR wide fixture.
# Initial fold only, by design: ready-plugin `.image` cmds carry no
# scrollable_id, so neither --scroll nor --scroll-x-end can add signal
# (mermaid-wide 4h precedent).
wide_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_graphviz_wide.md dot graphviz <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$wide_hash" ] || { echo "FAIL: graphviz wide fence hash empty" >&2; exit 1; }
cp test_cases/assets/graphviz-seed-wide.png "$cache_root/read/plugins/graphviz/$wide_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_graphviz_wide.png" --settle-images test_cases/plugin_graphviz_wide.md
[ -n "$plantuml_hash" ] || { echo "FAIL: case 4k fence hash empty" >&2; exit 1; }
cache_root="$(suite_cache_root)"
mkdir -p "$cache_root/read/plugins/plantuml"
cp test_cases/assets/plantuml-seed.png "$cache_root/read/plugins/plantuml/$plantuml_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_plantuml.png" --settle-images test_cases/plugin_plantuml.md

# Tall companion (same case 4k): plantuml-seed-tall.png is the genuine
# PlantUML 1.2026.8 render (393x511) of the 14-message four-participant
# sequence fixture. PlantUML lays sequence diagrams out compactly, so the
# whole render fits the initial fold: no scrolled frames (700 showed only
# the bottom footer sliver plus empty viewport).
tall_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_plantuml_tall.md plantuml plantuml <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$tall_hash" ] || { echo "FAIL: plantuml tall fence hash empty" >&2; exit 1; }
cp test_cases/assets/plantuml-seed-tall.png "$cache_root/read/plugins/plantuml/$tall_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_plantuml_tall.png" --settle-images test_cases/plugin_plantuml_tall.md

# Wide companion (same case 4k): plantuml-seed-wide.png is the genuine
# PlantUML 1.2026.8 render (460x306) of the eight-participant wide
# fixture. Initial fold only, by design:
# ready-plugin `.image` cmds carry no scrollable_id, so neither --scroll nor
# --scroll-x-end can add signal (mermaid-wide 4h precedent).
wide_hash=$(python3 - src/core/plugin_cache.zig test_cases/plugin_plantuml_wide.md plantuml plantuml <<'EOF'
import re, sys
zig_src, md_path, info_token, renderer = sys.argv[1:5]
m = re.search(r"Renderer\s*=\s*enum\s*\{([^}]*)\}", open(zig_src).read())
ordinal = [x.strip() for x in m.group(1).split(",") if x.strip()].index(renderer)
lines = open(md_path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.lstrip().startswith('```') and l.lstrip()[3:].strip().split(' ')[:1] == [info_token])
end = next(i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('```'))
src = '\n'.join(lines[start + 1:end]).encode()
h = 0xCBF29CE484222325
M = (1 << 64) - 1
for b in bytes([ordinal]) + b'\x00' + src:
    h ^= b
    h = (h * 0x100000001B3) & M
print('%016x' % h)
EOF
)
[ -n "$wide_hash" ] || { echo "FAIL: plantuml wide fence hash empty" >&2; exit 1; }
cp test_cases/assets/plantuml-seed-wide.png "$cache_root/read/plugins/plantuml/$wide_hash.png"
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/plugin_plantuml_wide.png" --settle-images test_cases/plugin_plantuml_wide.md

# Case 4k: Bare-URL linkification (issue #332) — pasted http(s) URLs render
# as links with trailing punctuation left literal.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/bare_links.png" test_cases/bare_links.md

# Case 4l: YAML frontmatter (issue #334) — the metadata block renders
# nothing; only the heading and paragraph below reach the viewport.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/frontmatter.png" test_cases/frontmatter.md

# Case 5: The ONLY test for scrollable docs (scrolled viewport virtualization)
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/scrollable_doc.png" --scroll 500 test_cases/scrollable_doc.md

# Case 6: Image completeness — local (doc-dir relative), missing, and remote
# URLs. Plain one-shot renders deterministic placeholders for all three;
# --settle-images lets the local file decode so reviewers see the 600px
# clamp, while missing/remote (offline) keep the muted alt-text placeholder.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/images.png" test_cases/images.md
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/images_settled.png" --settle-images test_cases/images.md
# Same-file scrolled frame (mdtest precedent: no new test case) so reviewers
# see the remote-URL placeholder state below the fold.
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/images_scrolled.png" --scroll 450 test_cases/images.md
# Case 7: RTL/bidi paragraphs, headings, lists, quotes (issue #50). Plain
# initial viewport like cases 1-4 (not a scrolling test).
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/rtl_bidi.png" test_cases/rtl_bidi.md

# Cases 6+: Original MarkdownTest 1.0 suite (.text sources copied verbatim to
# test_cases/mdtest_*.md). scrollable_doc.md remains the single
# scrolled-viewport *test case*; the per-file scroll steps below capture the
# same files to end-of-content purely so reviewers can validate every line
# visually (no new test cases, no new documents).
capture_scrolled() {
    local src="$1"
    local base="$2"
    # A content-independent empty frame: any past-end offset renders only the
    # background, so frames hashing equal to it carry no content.
    ./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/.empty_ref.png" --scroll 999999999 "$src" >/dev/null 2>&1
    local empty_hash
    empty_hash=$(shasum -a 256 "$OUTPUT_DIR/.empty_ref.png" | cut -d' ' -f1)
    rm -f "$OUTPUT_DIR/.empty_ref.png"

    local step=700
    local max_steps=12
    local idx=0
    local prev_hash=""
    while [ "$idx" -lt "$max_steps" ]; do
        local off=$((idx * step))
        local out
        if [ "$idx" -eq 0 ]; then
            out="$OUTPUT_DIR/$base.png"
        else
            out="$OUTPUT_DIR/${base}__s${idx}.png"
        fi
        ./zig-out/bin/read-test --screenshot "$out" --scroll "$off" "$src" >/dev/null 2>&1
        local hash
        hash=$(shasum -a 256 "$out" | cut -d' ' -f1)
        # Stop at end of content: empty frames and repeats add no signal.
        if [ "$hash" = "$empty_hash" ] || [ "$hash" = "$prev_hash" ]; then
            rm -f "$out"
            break
        fi
        prev_hash="$hash"
        idx=$((idx + 1))
    done
    # Clean stale steps from a previously longer document (e.g. doc shrank).
    local stale=$idx
    while [ -f "$OUTPUT_DIR/${base}__s${stale}.png" ]; do
        rm -f "$OUTPUT_DIR/${base}__s${stale}.png"
        stale=$((stale + 1))
    done
}

for md in test_cases/mdtest_*.md; do
    name=$(basename "$md" .md)
    capture_scrolled "$md" "$name"
done

echo "Screenshot regression captures complete in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
