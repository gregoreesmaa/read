# Read

[![CI](https://github.com/gregoreesmaa/read/actions/workflows/ci.yml/badge.svg)](https://github.com/gregoreesmaa/read/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/gregoreesmaa/read)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16-orange)](https://ziglang.org)

> **Read** — an ultra-minimalist, zero-dependency, microsecond-grade Markdown reader in pure Zig with a native macOS Cocoa/CoreText layer.

A **zig markdown reader** with **zero-dependency** binaries under 500 KB: zero-copy file access via
**mmap**, branchless **SIMD** line scanning at gigabytes per second, a virtualized viewport with
**microsecond** layout latency, and native **Core Text** typography on **macOS**. No Electron, no
WebKit, no UI toolkit, no package dependencies — just Zig and OS headers.

```
       _____                 _ 
      |  __ \               | |
      | |__) |___  __ _   __| |
      |  _  // _ \/ _` | / _` |
      | | \ \  __/ (_| || (_| |
      |_|  \_\___|\__,_| \__,_|
```

`Read` is designed for one thing: opening and rendering Markdown files faster than the human eye can perceive, using the absolute minimum computer resources possible. Zero heap allocations on the hot path, SIMD vector scanning, and native sub-pixel typography.

---

## ⚡ Performance & Strict Benchmarks

All metrics are codified in `src/core/strict_benchmarks.zig` and verified on Apple Silicon (M-series, 64-bit ARM). Performance targets are immutable and strictly enforced on every build:

| Metric | Typical Markdown App (Electron / WebTech) | Standard Native Reader | **Read** (Zig 0.16) | Target Guaranteed |
| :--- | :--- | :--- | :--- | :--- |
| **Binary Size** | ~180 MB | ~15 – 35 MB | **< 500 KB** (`ReleaseFast`) | **< 500 KB** |
| **Document Open Time** | 350 – 1,200 ms | 20 – 60 ms | **≤ 18 µs** (Zero-copy `mmap`) | **≤ 18 µs** |
| **SIMD Line Scanning** | ~100 ms | 15 – 25 ms | **≤ 400 µs for 50,000 lines** (**≥ 5.5 GB/s**) | **≥ 5.5 GB/s, ≤ 400 µs** |
| **Viewport Layout Latency** | 8 – 16 ms | 1 – 3 ms | **≤ 8 µs** | **≤ 8 µs** |
| **Substring Search (50k lines)** | ~50 ms | 5 – 10 ms | **≤ 50 µs** | **≤ 50 µs** |
| **Deep-Scroll Layout (line 45k+)** | 8 – 16 ms | 1 – 3 ms | **≤ 11 µs** (checkpointed) | **≤ 11 µs** |
| **Line Index Footprint** | — | — | **8-byte packed `Line` struct** | **8 bytes** |
| **Hot Path Heap Allocations** | Millions | Thousands | **0** (Zero heap allocations) | **0** |
| **Active Memory (MaxRSS)** | 150 – 400 MB | 30 – 80 MB | **< 6 MB** | Minimal OS page footprint |
| **Third-Party Dependencies** | Hundreds (`node_modules`) | Multiple UI toolkits | **0** (Pure Zig + Native OS headers) | Zero external packages |

---

## 🎨 Typographic & Visual Design Standards

`Read` adheres to strict typographical guidelines tailored for distraction-free reading:

- **Typefaces**:
  - Body Text: **IBM Plex Serif** (Regular, Bold, Italic)
  - Headings: **Space Grotesk** (Light Bold, Regular)
  - Code & Monospace: **JetBrains Mono**
  - Font advances are pre-calibrated for exact sub-pixel layout without measuring text on the CPU.
- **Layout Constants**:
  - Maximum reading width: **600px** (centered horizontally)
  - Base line height: **1.75** (`base_font_size * 1.75`)
  - Heading margins: **Top 2.5em**, **Bottom 0.5em**
- **Zen Color Palettes**:
  - **Dark Mode**: Background `#121212`, Text `#E0E0E0`, Code card `#1A1A1C`
  - **Light Mode**: Background `#FAFAFA`, Text `#1E2022`, Code card `#F0F1F3`

---

## 🏛 Architecture: "Do Less, Touch Less"

1. **Zero-Copy Memory Mapping (`src/core/mmap.zig`)**
   - Documents are mapped directly into the virtual address space using `mmap` (POSIX) and `MapViewOfFile` (Win32).
   - Zero heap buffer copies: text content is demand-paged straight from the operating system cache.

2. **Branchless SIMD Line Scanner (`src/core/simd.zig`)**
   - Scans 32 bytes per iteration using hardware vector registers (`@Vector(32, u8)`).
   - High-speed classification identifies headings, code fences, blockquotes, lists, task checkboxes, tables, and horizontal rules at > 7.0 GB/s.
   - Outputs a compact 8-byte packed `Line` index array.

3. **Virtualized Viewport Layout (`src/layout/viewport.zig`)**
   - Elements outside the viewport window are culled instantly. Only tokens visibly intersecting the screen are tokenized and laid out.
   - Zero-allocation inline tokenizer (`src/core/parser.zig`).

4. **Native Cocoa & CoreText Platform Layer (`src/platform/`)**
   - Minimalist borderless window (`NSWindowStyleMaskFullSizeContentView`) with native CoreGraphics and CoreText text rasterization.
   - GPU-accelerated hardware clipping (`CGContextClipToRect`) for horizontally scrollable containers.
   - Headless screenshot engine rendering directly to PNG for visual regression validation in CI/PRs.

---

## 📝 Markdown Specification Compliance

Strictly conforms to CommonMark Spec and Daring Fireball syntax (HTML rendering intentionally excluded):

- **Block Elements**:
  - ATX Headings (`#` through `######`, with optional closing `#`)
  - Setext Headings (`===` for H1, `---` for H2)
  - Thematic breaks / Horizontal rules (`---`, `***`, `___`)
  - Fenced code blocks (`` ``` `` and `~~~`) and indented code blocks
  - Blockquotes (including nested `>>`)
  - Lists: Unordered (`*`, `-`, `+`), Ordered (`1.`, `1)`), Task lists (`- [ ]`, `- [x]`)
  - Tables: GFM table rows with column measurement, cell alignment, and dividers
- **Inline Elements**:
  - Code spans (`` `code` ``)
  - Emphasis (italic `*text*`, `_text_`)
  - Strong emphasis (bold `**text**`, `__text__`)
  - Triple emphasis (bold & italic `***text***`, `___text___`)
  - Strikethrough (`~~deleted~~`)
  - Links: Inline `[text](url)` and autolinks (`<https://...>`, `<user@domain.com>`)
  - Images (`![alt](url)`)
  - Backslash escapes (`\*`, `\_`, `\[`, `\]`, `\#`, `\` `, etc.)

---

## ⌨️ Interaction, Keybindings & Controls

### Text Selection & Clipboard
- **Flowing Selection**: Standard drag-to-select across all markdown elements (headings, paragraphs, lists, tables, code blocks).
- **Word Selection**: Double-click locks in word boundary; mouse-up will **never** collapse or overwrite selection end coordinates.
- **Line Selection**: Triple-click locks in entire line boundary.
- **Select All**: `Cmd+A` or via context menu.
- **Clipboard Copy**: `Cmd+C` or via context menu.
- **Right-Click Context Menu**: Native menu offering Copy, Select All, Open Link in Browser, and Copy Link Address.
- **Hover Copy Button**: Code blocks display a visible-on-hover "Copy" button with visual feedback.
- **Clickable Links**: Direct browser navigation on click for web links and emails.

### Distinct Per-Block Horizontal Scrolling
- **Tables & Code Blocks**: Both code blocks and tables support horizontal scrolling.
- **Hover-Activated**: Blocks only scroll horizontally when the mouse cursor is hovering directly over that specific block.
- **Independent**: Scrolling one block does not affect or scroll any other block.
- **Right-Alignment Maximum Clamping**: Maximum horizontal scroll clamps so the right edge of content aligns with the right container edge (`max_scroll_x = @max(0.0, content_w - container_w)`).

### Navigation Keybindings

| Key | Action |
| :--- | :--- |
| `j` / `Down` | Scroll down (40px) |
| `k` / `Up` | Scroll up (40px) |
| `Space` | Page down (80% window height) |
| `h` / `l` | Scroll hovered code block or table horizontally (30px) |
| `Trackpad Swipe` | Horizontal scroll on hovered code block or table |
| `t` | Toggle Dark / Light theme |
| `Cmd+C` | Copy selection to system clipboard |
| `Cmd+A` | Select all text in document |
| `q` | Quit |

---

## 📸 Screenshots

Visual regression captures (regenerated via `./scripts/screenshot_suite.sh screenshots` — see
[showcase.md](showcase.md) for the full demo document):

| Text wrapping & typography | Spacings & headings |
| :---: | :---: |
| ![Text wrapping](screenshots/text_wrapping.png) | ![Spacings and headings](screenshots/spacings_headings.png) |

| Code blocks & task lists | Tables formatting |
| :---: | :---: |
| ![Code and tasks](screenshots/code_and_tasks.png) | ![Tables formatting](screenshots/tables_formatting.png) |

| Scrollable document (scrolled viewport) |
| :---: |
| ![Scrollable doc](screenshots/scrollable_doc.png) |

---

## 🛠 Quickstart

### Prerequisites
- [Zig](https://ziglang.org) 0.16.0 or later (`zig version` should print `0.16.0`)
- macOS with Xcode Command Line Tools (Cocoa/CoreText platform layer; core
  `zig build test` also runs on Linux, but the native window and screenshots need macOS)

### Build & Run
```bash
# Run 100% of unit tests and strict microsecond benchmarks (required gate)
zig build test -Doptimize=ReleaseFast --summary all

# Build optimized ReleaseFast executable (< 500 KB)
zig build -Doptimize=ReleaseFast

# Open a Markdown document (try the full demo)
./zig-out/bin/read showcase.md

# Headless screenshot capture
./zig-out/bin/read --screenshot output.png showcase.md
./zig-out/bin/read --screenshot output_scrolled.png --scroll 500 showcase.md

# Regenerate complete visual regression screenshot suite
./scripts/screenshot_suite.sh screenshots
```

New contributors: read [CONTRIBUTING.md](CONTRIBUTING.md) for the pre-commit protocol first.

---

## 🤖 Guidelines for AI Agents

See [AGENTS.md](AGENTS.md) for architectural tenets, benchmark immutability rules, design standards, and pre-commit verification protocols.

---

## 📄 License

MIT License — Copyright (c) 2026 Gregor Eesmaa. See [LICENSE](LICENSE) for details.
