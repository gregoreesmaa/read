# AGENTS.md — Guidelines for AI Coding Agents on `Read`

Welcome to `Read`. This project builds an ultra-minimalist, zero-dependency, microsecond-grade Markdown reader in pure Zig with a native Cocoa/CoreText platform layer.

Every agent working on this repository MUST strictly follow these principles.

---

## 1. Core Mission & Architectural Tenets

- **Extreme Performance**: Performance is the defining feature.
  - Zero heap allocations on the hot path (scrolling, rendering, layout, tokenization).
  - Branchless/SIMD vector processing for line indexing and block classification.
  - Virtualized viewport: Only tokens visibly intersecting the screen are parsed and rendered.
  - Memory-mapped files: Zero-copy virtual address space mapping.
- **Zero Dependencies**: No Electron, no WebKit, no heavy UI toolkits, no external package manager dependencies.
- **Binary Footprint**: Executable size must remain strictly under 200 KiB (raised from 180 KiB by owner decision 2026-09-09 to land in-document find; diet discipline and all other gates unchanged). The budget is split into two accounts — core and plugins — enforced by `scripts/size_gate.sh`; the bust procedure lives in §7.
- **Lean Production Build**: The ship binary contains only what reading needs — nothing test-only ever ships.
  - Testing, debugging, and observability tooling lives in a separate binary behind compile-time gates, never behind runtime flags. The separation is structural: no build option may re-enable test code in production.
  - Production surfaces a minimal interface; anything outside it is rejected, never silently absorbed.
  - Trust the compiler to strip gated code; enforce leanness through the binary size budget, not runtime self-checks.

---

## 2. Immutable Targets & Benchmark Invariance

- **Strict Benchmarks are Immutable**:
  - The metrics codified in `src/core/strict_benchmarks.zig` (e.g., > 5.0 GB/s scanner throughput, < 450 µs for 50,000 lines, < 12 µs viewport layout latency, < 12 µs deep-scroll latency, 8-byte packed Line struct, 0 hot path allocations) are **non-negotiable**.
  - **Rule**: If an implementation change fails a strict performance target, **NEVER loosen or change the benchmark target**. Always optimize the implementation until it meets the target.
- **Premium Scroll Feel is Immutable**:
  - The scroll-feel targets codified alongside the benchmarks (`TARGET_MIN_SCROLL_FIRST_FRAME_FRAC`, `TARGET_MAX_SCROLL_SETTLE_FRAMES_40PX`: first 120Hz frame covers ≥ 20% of a step, 40px key steps snap within 24 frames with zero overshoot, precise trackpad/Magic Mouse input stays synchronous 1:1 from the displayed offset, wheel notches glide via retarget) are **non-negotiable**.
  - **Rule**: Same as benchmarks — if a change makes scrolling laggy, floaty, or steppy, fix the implementation, never relax the scroll targets. Pin behavior with tests, not frozen constants: any future curve must still clear these bounds.

---

## 3. Typographic & Visual Design Standards

- **Typography**:
  - Body text: **IBM Plex Serif** (Regular, Bold, Italic)
  - Headings: **Space Grotesk** (Light Bold, Regular)
  - Code & Monospace: **JetBrains Mono**
- **Layout Constants**:
  - Line height: **1.75** (`base_font_size * 1.75`)
  - Maximum content reading width: **600px** (centered horizontally)
  - Heading margins: **Top 2.5em**, **Bottom 0.5em**
- **Color Palettes**:
  - Dark Mode: Background `#121212`, Text `#E0E0E0`
  - Light Mode: Background `#FAFAFA`, Text `#1E2022`

---

## 4. Interaction & Controls Specifications

- **Native Selection & Clipboard**:
  - Standard text selection across all block elements (headings, paragraphs, lists, tables, code).
  - Character range selection on drag.
  - Word selection on double-click: **Must lock in**; subsequent `mouseUp` must NOT overwrite cursor-end with mouse-up coordinates.
  - Line selection on triple-click.
  - Select All via `Cmd+A` or context menu.
  - Native clipboard copy via `Cmd+C` or right-click context menu.
- **Code Blocks & Tables Horizontal Scrolling**:
  - Code blocks and tables are horizontally scrollable.
  - **Hover-activated**: Blocks must only scroll horizontally when the mouse cursor is hovering directly over that specific block.
  - **Independent**: Scrolling one block does NOT affect or scroll any other block.
  - **Right-Alignment Clamping**: Maximum horizontal scroll is clamped so the right edge of content aligns with the right container edge (`max_scroll_x = @max(0.0, content_w - container_w)`).
- **Navigation Keybindings**:
  - `j` / `k`: Scroll down / up (40px)
  - `Space`: Page down (80% window height)
  - `t`: Toggle Dark / Light theme
  - `h` / `l`: Scroll hovered code block or table horizontally
  - `q`: Quit

---

## 5. Markdown Specification Compliance

- Strictly adhere to CommonMark Spec and Daring Fireball Syntax:
  - ATX Headings (`#` to `######`, with optional closing `#`)
  - Setext Headings (`===` for H1, `---` for H2)
  - Fenced code blocks (`` ``` `` and `~~~`) and indented code blocks
  - Blockquotes (including nested `>>`)
  - Lists: Unordered (`*`, `-`, `+`), Ordered (`1.`, `1)`), Task lists (`- [ ]`, `- [x]`)
  - Tables: GFM table rows with column measurement and cell dividers
  - Inlines: Code spans, emphasis (`*`, `_`), strong emphasis (`**`, `__`), triple emphasis (`***`, `___`), strikethrough (`~~`), inline links (`[text](url)`), autolinks (`<https://...>`, `<email>`), images (`![alt](url)`), and backslash escapes (`\*`, `\_`, etc.).
- **HTML Scope**: Only the blessed subset renders — inline `br`/`kbd`/`sub`/`sup`/`mark`/`del`/`s`, `details`/`summary` stripping; everything else stays visible muted-mono runs, never links, images, or hidden blocks. Full HTML rendering remains unsupported.
- **Ask Before Heavy Features**: If a rare or complex Markdown feature threatens the zero-allocation, microsecond-grade architecture (e.g. multi-level recursive dynamic ASTs or 100KB Unicode normalization tables), **ask the user** before implementing.

---

## 6. Pre-Commit Quality & Verification Protocol

Before pushing or committing any code:
1. **Run All Tests & Benchmarks**:
   ```bash
   zig build test -Doptimize=ReleaseFast --summary all
   ```
   100% of tests and strict performance benchmarks must pass.
2. **Regenerate Screenshots**:
   ```bash
   ./scripts/screenshot_suite.sh screenshots
   ```
   Screenshots must be regenerated and staged in the commit so reviewers can visually inspect diffs.
3. **Screenshotted Test Cases**:
   Maintain distinct test cases in `test_cases/`:
   - Text wrapping & typography
   - Spacings & headings
   - Code blocks & task lists
   - Tables formatting
   - **Only 1 test case for scrollable documents** (do not add multiple scrolling tests).

---

## 7. Size-Budget Enforcement & Diet Procedure

The ship binary carries two size accounts, enforced by `scripts/size_gate.sh`:

- **Core account** (`CORE_BUDGET = 200 KiB`): everything except plugin-attributable code.
- **Plugin account** (`PLUGIN_BUDGET`, constant in `size_gate.sh`): all plugin-attributable code.

**What counts as plugin code.** Exactly the code that vanishes when plugins compile out: `src/core/plugin_cache.zig` bodies, the launcher TU (`src/platform/macos_plugin.m`), the per-document plugin flow in `src/main.zig`, the fence-decision branches in `src/layout/viewport.zig`, and the plugin bridge decls. The nullable-table guards at the integration seams (`plugins != null` checks) count as **core** — the core chose that seam. Shared helpers used by both core and plugins count as **core**.

**How plugins are measured (differential twin).** The ship binary is stripped, and Zig emits a single object per compilation unit, so symbol attribution is impossible — instead the gate builds a twin: `zig build -Dplugin_stub=true` produces an otherwise byte-identical binary with the plugin file swapped for an API-compatible stub and the launcher TU swapped for an empty stub (same flags, same everything else). `plugin_bytes = __TEXT(ship) - __TEXT(twin)`, compared on `__TEXT` segment bytes (never file bytes — page padding lies). The twin is observability tooling: it is never installed, bundled, or shipped, and the option defaults to full plugins, so the ship shape is always the default. Zero-delta acceptance: adding the stub plumbing with the option off must leave ship `__TEXT` byte-identical (prove with `size -m` before/after). Each renderer PR quotes its twin-delta (`plugin_bytes` before/after) in the PR body.

**Gate rule.** FAIL if `total - plugin > CORE_BUDGET` or `plugin > PLUGIN_BUDGET`. Both numbers print on every run.

### When the gate busts

1. **Confirm it is real.** Re-run the gate; rule out page-padding noise (file bytes can jump a full 16 KiB page on a few dozen bytes of `__text` — the `__TEXT` figure is the truth). Attribute the growth (`git log`, diff stat, per-PR twin-deltas).
2. **One agent diets `main`.** Broad scan: comptime-table compression, string pooling, dead code, section bloat, duplicate logic. No behavior change: screenshots must stay byte-identical, all tests and strict benchmarks green — a cut that moves any benchmark is reverted, never compensated elsewhere (§2 is untouched by this procedure).
3. **Three agents diet the failing changes.** The controller splits the bust-causing scope (the PR branch, or the merged commits that caused it) into three disjoint areas — e.g. per file or per feature — and assigns one agent per area. Disjoint by construction; agents never touch each other's files.
4. **One final agent considers changes-in-whole.** It takes all found opportunities and evaluates interactions the area scans cannot see: cross-boundary inlining, alignment and section placement, opportunities that only exist when old and new code are considered together. It picks and combines; it does not re-scan.
5. **Build-slot mutex.** Gate builds are the long pole and parallel builds thrash into flakes: only one agent on a machine runs a gate build at a time. Coordinate with a lock directory (e.g. `.zig-cache/size-gate.lock` via `mkdir`, bounded wait, backoff); never delete another agent's lock, never kill its build. Reads and edits need no lock.
6. **Evidence per opportunity.** Each agent reports every candidate with measured bytes (ship `__TEXT` before/after), the gate results proving no behavior change, and what it rejected with reasons. "Nothing found" is a valid result only with the scanned areas and the largest rejected candidate stated.

**Small functionality loss.** Allowed ONLY when all of these hold: no test covers the lost behavior; CommonMark/spec compliance is unaffected (conformance suite green); screenshots are byte-identical; the loss is documented in the commit message and PR body. Anything user-visible beyond that is forbidden — cut bytes, not features.

**If nothing is found: bump 5% and re-gate.** If every agent reports nothing with evidence, increase the busting account by 5% (multiply by 1.05, round up to a whole KiB), re-run the gate to confirm green, and record the decision here as a history line with date and reason (precedent: 180 → 200 KiB, owner decision 2026-09-09, in-document find). Do not re-run the diet agents against an already-green gate; the loop re-arms on the next bust.

**Budget history.**
- 180 → 200 KiB core, owner decision 2026-09-09, to land in-document find.
- Plugin account split out (twin mechanism); initial `PLUGIN_BUDGET` = measured plugin `__TEXT` + 4 KiB headroom — value set by the implementing agent below, recorded in `size_gate.sh`:
  - `PLUGIN_BUDGET = 12 KiB, measured 2026-09-12` (twin-measured 8062 bytes + 4 KiB headroom).
