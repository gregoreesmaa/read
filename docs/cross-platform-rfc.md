# Cross-Platform Strategy (RFC — issue #53)

Status: **proposed**. This doc declares the target matrix and the
abstraction contract *before* more AppKit-isms bake in. Everything
below is additive: no core/layout behavior changes ship with this RFC.

## Decision summary

- **Second OS: Linux.** It shares the `mmap`/POSIX core (`src/core/mmap.zig`
  is already POSIX-native; the Windows `MapViewOfFile` branch exists but a
  Win32 UI is the larger lift). Linux also matches CI reality
  (`ubuntu-latest` already runs the core gate).
- **Toolkit rule (zero-dependency):** "zero dependencies" means no
  third-party, bundled, or package-managed UI toolkits — GTK/Qt/Electron
  are out. Linking *OS system libraries* is the existing precedent
  (`Cocoa`/`CoreText`/`CoreGraphics` on macOS, see `build.zig`); each
  platform uses only libraries guaranteed present on a stock install.
- **Seam:** every OS-ism lives behind `src/platform/bridge.zig` /
  `src/platform/platform.h`. `src/core` + `src/layout` are OS-agnostic,
  enforced by the `seam-gate` CI job (grep; see §6).

## Per-OS stack

| OS | Window / events | Text shaping | Raster | Image decode |
| :--- | :--- | :--- | :--- | :--- |
| macOS (today) | AppKit (`NSView`, `NSWindow`) | CoreText (`CTLine`) | CoreGraphics (2x atlas) | ImageIO + AppKit fallback |
| Linux (next) | Xlib (stable ABI, present everywhere) | fontconfig discovery + FreeType raster into our own atlas | XRender/`XPutImage` via MIT-SHM | stb-free minimal decoders for PNG/JPEG via system libs only (exact pick: follow-up spike; no bundled code) |
| Windows (later) | Raw Win32 (`HWND`, `WndProc`) | DirectWrite | Direct2D or GDI DIB blit | WIC (system) |

Why Xlib first, not Wayland: a toolkit-free Wayland client hand-rolls the
`xdg-shell` protocol (doable, but a second project); XWayland runs Xlib
clients on Wayland compositors today, so Xlib covers both while native
Wayland stays a follow-up. Why not GTK/Qt: dependencies, therefore out
per AGENTS.md §1.

## Binary-size budget per OS

The `<180 KiB` discipline applies to first-party code on every OS.
System libraries (Cocoa, Xlib, FreeType, DirectWrite) link dynamically
and are never counted — same as today. Note the Mach-O `__TEXT`
16 KiB-page discipline (`scripts/size_gate.sh`) is Apple-specific; ELF
uses 4 KiB pages, so Linux headroom accounting will differ in detail but
not in spirit: new platform glue goes at end-of-file, measured by the
same gate.

## Font plan

Ship the TTFs in `assets/fonts/` on every OS (renderer-agnostic files;
FreeType and DirectWrite both consume them directly). No format change.

- Body: IBM Plex Serif (Regular/Bold/Italic) · Headings: Space Grotesk ·
  Mono: JetBrains Mono. System fallbacks stay per-platform
  (today: Georgia/Menlo/system fonts in `macos.m`; Linux: DejaVu Serif /
  DejaVu Sans Mono via fontconfig; Windows: Georgia/Consolas).
- **Licensing check (open):** all three families are SIL OFL, but the
  OFL texts are *not* vendored under `assets/fonts/` today. Vendor them
  before any release that redistributes binaries; no code change needed.

## Minimum OS versions / API floor

Today there is **no declared floor**: no `MACOSX_DEPLOYMENT_TARGET`, no
`LSMinimumSystemVersion`, CI builds on `macos-latest` against the newest
SDK. Proposed (settles the 10.12/10.14 question):

- **macOS 12 Monterey.** Rationale: every AppKit/CoreText API in
  `macos.m` spot-checked so far predates it by years (font registration,
  `CTLine`, GCD, scroll deltas); Dark-Aqua-era AppKit is a sane baseline;
  and it tracks the GitHub-hosted runner support window. Full API audit +
  `MACOSX_DEPLOYMENT_TARGET=12.0` + `LSMinimumSystemVersion` is follow-up
  work, not part of this RFC.
- **Linux: Ubuntu 22.04 LTS** (glibc 2.35; Xlib + fontconfig + FreeType
  guaranteed present). No kernel-feature dependency beyond `mmap`/`fstat`.
- **Windows (later): Windows 10 1809+** (DirectWrite 1.1 baseline).

## Target matrix

| Target | Arch | CI | Status |
| :--- | :--- | :--- | :--- |
| macOS 12+ | arm64 | `test-macos` (full gate + screenshots) | shipping |
| macOS 12+ | x86_64 | cross-compile check | best-effort |
| Linux (Ubuntu 22.04+) | x86_64, arm64 | `test-linux` (core gate; X11 glue compile check when it lands) | next |
| Windows 10+ | x86_64 | runner job when Win32 glue lands | later |

## CI approach

**Runner per target OS, not cross-compile**, for anything that runs:
the GUI, headless screenshots, and timing benchmarks cannot execute
under a foreign target. Cross-compile (`zig build -target …`) is for
compile checks only. Concretely: keep `test-macos` as the full gate,
extend `test-linux` as the Linux gate when the X11 glue lands, add a
Windows runner job with the Win32 glue. New `[platform]` issues specify
behavior against the `bridge.zig`/`platform.h` abstraction (keybinding /
scroll / appearance semantics); OS-specific notes only where behavior
genuinely differs.

## Seam contract (normative)

1. `src/core/*` and `src/layout/*` never name a platform symbol —
   no `NS*`/`CG*`/`CT*`, no `AppKit`/`Cocoa`/`CoreText`, no `dispatch_*`,
   not even in comments (keeps the gate naive). Counterpart files may be
   referenced by filename (`macos.m`) where geometry is mirrored.
2. `src/platform/*` owns all OS glue (today: `macos.m`, `bridge.zig`,
   `platform.h`, `glyph_cache.zig`, `idle.zig`).
3. `src/main.zig` (app shell) is the only file that names both sides:
   it wires `ViewportConfig` callbacks to `bridge.platform_*`.
4. New platform surface = appended `platform_*` C functions + appended
   `PlatformCallbacks` fields (never reorder — FFI offsets must not shift).
