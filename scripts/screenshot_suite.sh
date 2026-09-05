#!/usr/bin/env bash
set -euo pipefail

# Read: Visual Regression Screenshot Engine
# Captures headless frame captures of test documents for PR visual comparison.

OUTPUT_DIR="${1:-screenshots}"
mkdir -p "$OUTPUT_DIR"

echo "Building Read in ReleaseFast mode..."
zig build -Doptimize=ReleaseFast

echo "Capturing visual regression screenshots into $OUTPUT_DIR..."

./zig-out/bin/read --screenshot "$OUTPUT_DIR/showcase_top.png" showcase.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/showcase_quotes_lists.png" --scroll 750 showcase.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/showcase_tasks_code.png" --scroll 1500 showcase.md
./zig-out/bin/read --screenshot "$OUTPUT_DIR/showcase_tables.png" --scroll 2400 showcase.md

echo "Screenshot regression captures complete in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
