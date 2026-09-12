#!/usr/bin/env bash
set -euo pipefail

# Read: Visual Regression Screenshot Engine
# 1. Enforces all unit tests & strict microsecond benchmarks pass
# 2. Captures headless frame captures of distinct test documents for PR visual comparison

OUTPUT_DIR="${1:-screenshots}"
mkdir -p "$OUTPUT_DIR"

echo "Step 1: Running all tests and strict benchmarks (ReleaseFast)..."
zig build test -Doptimize=ReleaseFast --summary all

echo "Step 2: Building Read executable in ReleaseFast mode..."
zig build -Doptimize=ReleaseFast

echo "Step 3: Capturing distinct visual regression test cases into $OUTPUT_DIR..."

# Case 1: Text wrapping, typography, inline styling, max reading width 600px, line-height 1.75
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/text_wrapping.png" test_cases/text_wrapping.md

# Case 2: Hierarchical spacings, heading margins (top 2.5em, bottom 0.5em), blockquotes, horizontal rules
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/spacings_headings.png" test_cases/spacings_headings.md

# Case 3: Code blocks, syntax background card, copy button, task checkboxes, lists
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/code_and_tasks.png" test_cases/code_and_tasks.md

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
if [ -n "${HOME:-}" ]; then cache_root="$HOME/Library/Caches"; else cache_root="${TMPDIR:-/tmp}/read-plugin-cache"; fi
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
if [ -n "${HOME:-}" ]; then cache_root="$HOME/Library/Caches"; else cache_root="${TMPDIR:-/tmp}/read-plugin-cache"; fi
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
