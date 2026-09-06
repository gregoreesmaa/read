# Architecture: "Do Less, Touch Less"

One job: open and render Markdown faster than the eye can perceive, using the
absolute minimum of computer resources. Throughput and latency numbers live only in the
[README benchmark table](../README.md#benchmarks); typographic constants live only in
[AGENTS.md](../AGENTS.md) §3. This file describes mechanism, not metrics.

1. **Zero-copy memory mapping** (`src/core/mmap.zig`)
   - Documents map straight into virtual address space; text demand-pages from the OS cache.
2. **Branchless SIMD line scanner** (`src/core/simd.zig`)
   - Wide vector compares find line breaks; a branch-light scalar pass classifies
     headings, fences, quotes, lists, tables, and rules into a packed `Line` index.
3. **Virtualized viewport** (`src/layout/viewport.zig`)
   - Off-screen elements are culled; only intersecting tokens are parsed and laid out,
     with zero heap allocations on the hot path (`src/core/parser.zig`).
4. **Native Cocoa/CoreText layer** (`src/platform/`)
   - Borderless window, CoreGraphics clipping for scrollable containers, CoreText rasterization.
   - Headless screenshot engine renders to PNG for visual regression in CI/PRs.

## Lean production build

The ship binary (`read`) contains only what reading needs. All testing, debugging, and
observability tooling lives in a separate binary (`read-test`, plus the `fuzz-parser`
harness) behind comptime gates — never runtime flags. Production surfaces a minimal
interface; anything outside it is rejected, never silently absorbed. Leanness is enforced
by the binary size budget (see [size_gate.sh](../scripts/size_gate.sh)), not self-checks.
