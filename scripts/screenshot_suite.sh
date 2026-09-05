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
./zig-out/bin/read --screenshot "$OUTPUT_DIR/text_wrapping.png" test_cases/text_wrapping.md

# Case 2: Hierarchical spacings, heading margins (top 2.5em, bottom 0.5em), blockquotes, horizontal rules
./zig-out/bin/read --screenshot "$OUTPUT_DIR/spacings_headings.png" test_cases/spacings_headings.md

# Case 3: Code blocks, syntax background card, copy button, task checkboxes, lists
./zig-out/bin/read --screenshot "$OUTPUT_DIR/code_and_tasks.png" test_cases/code_and_tasks.md

# Case 4: Table structure, cell padding, column alignment, dividers
./zig-out/bin/read --screenshot "$OUTPUT_DIR/tables_formatting.png" test_cases/tables_formatting.md

# Case 5: The ONLY test for scrollable docs (scrolled viewport virtualization)
./zig-out/bin/read --screenshot "$OUTPUT_DIR/scrollable_doc.png" --scroll 500 test_cases/scrollable_doc.md

# Cases 6+: Original MarkdownTest 1.0 suite (.text sources copied verbatim to
# test_cases/mdtest_*.md). All capture the initial viewport only -- no --scroll
# flag -- so scrollable_doc.md remains the single scrolled-viewport test.
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_amps_and_angle_encoding.png" test_cases/mdtest_amps_and_angle_encoding.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_auto_links.png" test_cases/mdtest_auto_links.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_backslash_escapes.png" test_cases/mdtest_backslash_escapes.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_blockquotes_with_code_blocks.png" test_cases/mdtest_blockquotes_with_code_blocks.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_documentation_basics.png" test_cases/mdtest_documentation_basics.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_documentation_syntax.png" test_cases/mdtest_documentation_syntax.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_hard_wrapped_paragraphs.png" test_cases/mdtest_hard_wrapped_paragraphs.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_horizontal_rules.png" test_cases/mdtest_horizontal_rules.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_inline_html_advanced.png" test_cases/mdtest_inline_html_advanced.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_inline_html_comments.png" test_cases/mdtest_inline_html_comments.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_inline_html_simple.png" test_cases/mdtest_inline_html_simple.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_links_inline_style.png" test_cases/mdtest_links_inline_style.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_links_reference_style.png" test_cases/mdtest_links_reference_style.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_literal_quotes_in_titles.png" test_cases/mdtest_literal_quotes_in_titles.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_nested_blockquotes.png" test_cases/mdtest_nested_blockquotes.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_ordered_and_unordered_lists.png" test_cases/mdtest_ordered_and_unordered_lists.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_strong_and_em_together.png" test_cases/mdtest_strong_and_em_together.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_tabs.png" test_cases/mdtest_tabs.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/mdtest_tidyness.png" test_cases/mdtest_tidyness.md

echo "Screenshot regression captures complete in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
