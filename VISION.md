# VISION — `read` in one page

**TL;DR: `read` is the most optimal Markdown file reader you'll ever see.**

## What it is
An ultra-minimalist, zero-dependency, microsecond-grade Markdown reader in pure Zig
with a native macOS Cocoa/CoreText layer. One job: open and render Markdown faster
than the eye can perceive, using the absolute minimum of computer resources.

## Non-negotiable goals
1. **Most optimal reader** — least CPU, GPU, RAM, disk, and overall energy of any
   Markdown reader. Zero heap allocations on the hot path. Branchless/SIMD scanning.
   Virtualized viewport (only visible tokens parsed/rendered). Memory-mapped files.
2. **Deliberately single-threaded** — no parallelisation on the hot path by design:
   threads/workers cost more total resources and break scroll feel. Concurrency must
   prove a net resource win or it doesn't ship.
3. **Spec-compliant** — CommonMark + GFM tables/task lists (Daring Fireball syntax);
   HTML rendering intentionally unsupported. Heavy features that threaten the
   zero-alloc/microsecond architecture are discussed BEFORE implementation.
4. **Most premium-feeling** — hand-picked fonts (IBM Plex Serif body, Space Grotesk
   headings, JetBrains Mono code), 1.75 line height, 600px column, dark
   `#121212`/`#E0E0E0` + light `#FAFAFA`/`#1E2022`, buttery scroll physics
   (120Hz first frame ≥20% of step, 40px steps settle ≤24 frames, zero overshoot,
   1:1 trackpad sync).
5. **Lean ship binary** — <180 KiB, zero dependencies. Test/debug tooling lives in a
   separate binary behind compile-time gates; nothing test-only ever ships.
6. **Immutable benchmarks** — targets in `src/core/strict_benchmarks.zig` are never
   loosened; only the implementation is optimized until it passes.

## Benefits / values
- Instant open, silent idle (0% CPU when untouched), tiny RSS, long battery life.
- Distraction-free, typographically excellent reading; native macOS feel
  (selection, clipboard, keybindings, accessibility).
- Trustworthy: crash-proof on malformed/huge files, reproducible builds, 100%-green
  `zig build test -Doptimize=ReleaseFast --summary all` plus regenerated
  screenshots per commit.
- Showcase-grade repo: clear README comparison table, one-command demo, curated
  `test_cases/` (only 1 scrollable-doc case).

## Guardrails (from AGENTS.md)
- Never relax a benchmark or scroll-feel target to make a change pass.
- Production interface stays minimal; unknown input rejected, never absorbed.
- Pre-commit: full tests+benchmarks green, screenshots regenerated and staged.
