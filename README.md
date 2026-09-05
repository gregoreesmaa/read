# Read

An ultra-minimalist, zero-dependency, microsecond-grade Markdown reader built in **Zig**.

```
       _____                 _ 
      |  __ \               | |
      | |__) |___  __ _   __| |
      |  _  // _ \/ _` | / _` |
      | | \ \  __/ (_| || (_| |
      |_|  \_\___|\__,_| \__,_|
```

`Read` is designed for one thing: opening and rendering Markdown files faster than the human eye can perceive, using the absolute minimum computer resources possible.

---

## ⚡ Performance & Strict Benchmarks

Enforced by strict regression benchmarks (`src/core/strict_benchmarks.zig`) tested on Apple Silicon (M-series, 64-bit ARM):

| Metric | Typical Markdown App (Electron / WebTech) | Standard Native Reader | **Read** (Zig 0.16) | Target Guaranteed |
| :--- | :--- | :--- | :--- | :--- |
| **Binary Size** | ~180 MB | ~15 – 35 MB | **185 KB** (`ReleaseSmall`) / **375 KB** (`ReleaseFast`) | < 500 KB |
| **Document Open Time** | 350 – 1,200 ms | 20 – 60 ms | **17 µs** (Zero-copy `mmap`) | $\le 45\text{ µs}$ |
| **SIMD Line Scanning** | ~100 ms | 15 – 25 ms | **350 µs for 50,000 lines** (**> 5.4 GB/s**) | $\ge 2.5\text{ GB/s}$ |
| **Viewport Layout** | 8 – 16 ms | 1 – 3 ms | **3 µs** (0.003 ms) | $\le 50\text{ µs}$ |
| **Substring Search (50k lines)** | ~50 ms | 5 – 10 ms | **83 µs** (0.08 ms) | $\le 150\text{ µs}$ |
| **Active Memory (MaxRSS)** | 150 – 400 MB | 30 – 80 MB | **< 6 MB** | Minimal OS page footprint |
| **Third-Party Dependencies** | Hundreds (`node_modules`) | Multiple libraries | **0** (Pure Zig + Native OS headers) | Zero external packages |

---

## 🏛 Architecture: "Do Less, Touch Less"

1. **Zero-Copy Memory Mapping (`src/core/mmap.zig`)**
   - Files are mapped straight into virtual memory using `mmap` (POSIX) and `MapViewOfFile` (Win32).
   - Zero heap buffer allocation: memory is demand-paged directly by the OS kernel.

2. **Branchless SIMD Line Scanner (`src/core/simd.zig`)**
   - Scans 32 bytes per cycle using hardware vector registers (`@Vector(32, u8)`).
   - Fast-path alphanumeric classifier eliminates branch prediction overhead.
   - Outputs a compact 10-byte `Line` index table.

3. **Virtualized Viewport Layout (`src/layout/viewport.zig`)**
   - Culls invisible elements early; only lines visible in the current viewport window are tokenized and laid out.
   - Zero-heap inline styling (`**bold**`, `*italic*`, `***both***`, `` `code` ``, `~~strike~~`, `[link](url)`).
   - SF Pro calibrated font advance metrics guaranteeing sub-pixel typographic alignment.

4. **Zero-Dependency Native Platform (`src/platform/`)**
   - **macOS**: Native Cocoa window (`NSWindowStyleMaskFullSizeContentView`) + Apple CoreText for Retina subpixel typography (San Francisco Pro, Menlo/SF Mono).
   - **Text Selection & Clipboard**: Standard mouse click-drag, word double-click, line triple-click, select-all (`Cmd+A`), and system clipboard copying (`Cmd+C`).
   - **Visual Regression Screenshot Engine**: Headless rendering pipeline directly to PNG for automated CI/PR validation.

---

## ⌨️ Keybindings & Controls

| Input | Action |
| :--- | :--- |
| `Mouse Drag` | Normal text selection |
| `Double Click` | Select word |
| `Triple Click` | Select full line |
| `Cmd+C` | Copy selected text to system clipboard |
| `Cmd+A` | Select entire document |
| `j` / `Down` | Scroll down |
| `k` / `Up` | Scroll up |
| `Space` | Page down |
| `t` | Toggle Zen Dark / Light theme |
| `q` | Quit |

---

## 🛠 Building & Running

### Prerequisites
- [Zig](https://ziglang.org) (v0.16.0 or later)

### Build & Run
```bash
# Run tests & strict microsecond benchmarks
zig build test -Doptimize=ReleaseFast --summary all

# Build optimized binary
zig build -Doptimize=ReleaseFast

# Open a Markdown document
./zig-out/bin/read showcase.md

# Headless screenshot rendering
./zig-out/bin/read --screenshot output.png showcase.md
./zig-out/bin/read --screenshot output_scrolled.png --scroll 700 showcase.md

# Run PR visual regression test suite
./scripts/screenshot_suite.sh
```

---

## 📄 License

MIT License — Copyright (c) 2026 Gregor Eesmaa. See [LICENSE](LICENSE) for details.
