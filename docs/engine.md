# Math engine setup (libzatex)

Formulae render through the ZaTeX engine, a native zero-dependency
dylib built from `packages/zatex` in
[github.com/gregoreesmaa/zatex](https://github.com/gregoreesmaa/zatex).
It is loaded at runtime via `dlopen` — never linked — so the ship binary
keeps its size budget with the engine absent. Math in Read is
**render-only, never authoring** (see [VISION.md](../VISION.md)): the
engine lays out glyph runs, the reader paints them.

## Load path (precedence)

1. `Read.app/Contents/Resources/libzatex.dylib` (the vendored engine —
   **this is the version a release ships**; see
   [release.md](release.md)).
2. `/usr/local/lib/libzatex.dylib` (manual install).
3. `$READ_ZATEX_LIB` (CI/test override: absolute path to the engine built
   from the pinned `third_party/zatex` submodule).

Nothing else is probed. When none exists — or the engine refuses the
input — formulae fall back to source text, byte-identical to the
pre-math reader (fences render as code cards, islands as literal text).

## Obtain an engine

Build from the pinned submodule (no separate clone needed):

```bash
git submodule update --init third_party/zatex
cd third_party/zatex/packages/zatex && zig build
# macOS: zig-out/lib/libzatex.dylib
# Linux: zig-out/lib/libzatex.so
# Windows: zig-out/lib/zatex.dll
cp <build-output>/libzatex.dylib /usr/local/lib/libzatex.dylib  # macOS manual install
```

Release bundles vendor the file above into `Resources/` at bundle time
(`scripts/make_app_bundle.sh` copies it when present and ships without
it otherwise); `scripts/check_app_bundle.sh` reports which case holds.

## Platform scope

Math renders live on all three OSes. Each platform serves the same
`ZatexMetrics` host contract through its native text stack —
CoreText (`src/platform/macos_zatex.m`), FreeType
(`src/platform/linux_zatex.c`), GDI (`src/platform/win32_zatex.c`) —
so layout agrees and only glyph rasterization differs (covered by
per-OS screenshot baselines in `screenshots/<os>/`).

## Supported spellings

Only exact ```` ```math ```` fences, whole-line `$$…$$` display lines,
and guarded `$…$` inline islands route to the engine.
`tex`/`latex`/`katex` fences stay syntax-highlighted code,
`\(...\)` / `\[...\]` stay literal (CommonMark escape precedence), and
currency (`$100`, `$5.99`), spaces (`$ $`), and unclosed dollars stay
literal. Full inventory: [spec.md](spec.md).

## Privacy

Layout is fully on-device and synchronous: caller-owned buffers, no
threads, no subprocess, no network. A document's formulae never leave
the machine.
