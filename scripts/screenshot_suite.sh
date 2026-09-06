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

# Case 5: The ONLY test for scrollable docs (scrolled viewport virtualization)
./zig-out/bin/read-test --screenshot "$OUTPUT_DIR/scrollable_doc.png" --scroll 500 test_cases/scrollable_doc.md

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
