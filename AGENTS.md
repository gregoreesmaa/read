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
- **Binary Footprint**: Executable size must remain strictly under 500 KB.

---

## 2. Immutable Targets & Benchmark Invariance

- **Strict Benchmarks are Immutable**:
  - The metrics codified in `src/core/strict_benchmarks.zig` (e.g., > 5.0 GB/s scanner throughput, < 450 µs for 50,000 lines, < 12 µs viewport layout latency, < 12 µs deep-scroll latency, 8-byte packed Line struct, 0 hot path allocations) are **non-negotiable**.
  - **Rule**: If an implementation change fails a strict performance target, **NEVER loosen or change the benchmark target**. Always optimize the implementation until it meets the target.

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
- **HTML Exclusion**: HTML rendering is intentionally unsupported.
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
