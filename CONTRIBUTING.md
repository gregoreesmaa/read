# Contributing to Read

Read is an ultra-minimalist, zero-dependency, microsecond-grade Markdown reader in Zig.
Contributions must respect the architecture in [AGENTS.md](AGENTS.md). Summary of the
non-negotiables:

## Pre-commit protocol (all three required)

1. **Tests + strict benchmarks green:**
   ```bash
   zig build test -Doptimize=ReleaseFast --summary all
   ```
   100% of tests and strict performance benchmarks must pass. The targets in
   `src/core/strict_benchmarks.zig` (5.5 GB/s scan, 400 µs/50k lines, 18 µs mmap open,
   8 µs viewport, 11 µs deep-scroll, 0 hot-path allocations, 8-byte `Line`, < 500 KB
   binary) are **immutable** — if your change misses one, optimize the implementation,
   never loosen the target.
2. **Run the damage parity check** (selection/hover record model must be
   identical under full and partial redraws):
   ```bash
   sh scripts/damage_parity.sh
   ```
3. **Regenerate screenshots:**
   ```bash
   ./scripts/screenshot_suite.sh screenshots
   ```
   Stage the regenerated PNGs in your commit so reviewers can diff them visually.
3. **`test_cases/` discipline:** keep the five distinct cases (text wrapping, spacings &
   headings, code & tasks, tables, one scrollable doc). **Max 1 scrollable document** —
   do not add more scrolling tests.

## Also

- Zero new dependencies (pure Zig + native OS headers only).
- Follow the typographic constants (600px width, 1.75 line height) and keybindings in
  AGENTS.md.
- Rare/complex Markdown features that threaten the zero-allocation budget (recursive
  ASTs, large Unicode tables, …): ask first, per AGENTS.md §5.
