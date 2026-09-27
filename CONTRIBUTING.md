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
   8 µs viewport, 11 µs deep-scroll, 0 hot-path allocations, 8-byte `Line`, < 200 KiB
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
4. **`test_cases/` discipline:** keep the five distinct cases (text wrapping, spacings &
   headings, code & tasks, tables, one scrollable doc). **Max 1 scrollable document** —
   do not add more scrolling tests.

## Renderer PR checklist

Renderer changes bite on gates that screenshot regen alone does not cover.
All five below are required before review:

1. **Stay behind the seam.** `src/core` + `src/layout` are OS-agnostic;
   every Cocoa-ism lives behind the `src/platform` + `src/main.zig`
   (app shell) boundary (`bridge.zig`/`platform.h`). The CI `seam-gate`
   job fails on any `NS*`/`CoreText`/`CG*` match outside it.
2. **Strict benchmarks green, never loosened.**
   `src/core/strict_benchmarks.zig` targets are immutable — a miss means
   optimizing the implementation, never lowering the target.
3. **Size gate green + twin-delta quoted.** Run `./scripts/size_gate.sh`
   (core ≤ 200 KiB, plugin account per `AGENTS.md` §7). Renderer PRs quote
   in the PR body: `plugin_bytes` before/after plus the `size -m` proof
   that ship `__TEXT` is unchanged when the option-off twin plumbing
   lands (zero-delta acceptance).
4. **Tests in the right place.**
   - Inline `test` blocks next to the code (`src/core/*`, `src/layout/*`,
     `src/main.zig` app-shell tests — Darwin-only, e.g. `math_detect.zig`
     fence/island guards).
   - `src/tests/` for harnesses (`spec_compliance_test.zig`,
     `commonmark_harness.zig`, `controls_test.zig`).
   - `test/fuzz/` (+ `corpus/`) for crash/hang inputs via
     `scripts/fuzz_parser.sh`.
5. **Pinned toolchain: Zig 0.16.0** (`mlugg/setup-zig@v2` in CI;
   reproducibility in `docs/release.md` depends on it).

## Also

- Zero new dependencies (pure Zig + native OS headers only).
- Follow the typographic constants (600px width, 1.75 line height) and keybindings in
  AGENTS.md.
- Rare/complex Markdown features that threaten the zero-allocation budget (recursive
  ASTs, large Unicode tables, …): ask first, per AGENTS.md §5.
