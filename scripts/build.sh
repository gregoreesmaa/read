#!/bin/sh
# Build both binaries (see AGENTS.md §1 Lean Production Build).
#   zig-out/bin/read      = ship binary (test CLI stripped; < 180 KiB gate)
#   zig-out/bin/read-test = testing binary (headless CLI: --screenshot etc.)
# Plain `zig build` installs both artifacts; this script pins ReleaseFast
# and runs the size gate so every compile checks the budget.
set -eu

cd "$(dirname "$0")/.."

zig build -Doptimize=ReleaseFast
./scripts/size_gate.sh zig-out/bin/read
ls -lh zig-out/bin/read zig-out/bin/read-test
