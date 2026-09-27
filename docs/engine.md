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

Nothing else is probed. When neither exists — or the engine refuses the
input — formulae fall back to source text, byte-identical to the
pre-math reader (fences render as code cards, islands as literal text).

## Obtain an engine

No versioned engine binaries exist yet, so build from source:

```bash
git clone https://github.com/gregoreesmaa/zatex
# build packages/zatex per its README, then:
cp <build-output>/libzatex.dylib /usr/local/lib/libzatex.dylib
```

Release bundles vendor the file above into `Resources/` at bundle time
(`scripts/make_app_bundle.sh` copies it when present and ships without
it otherwise); `scripts/check_app_bundle.sh` reports which case holds.

## Platform scope

Math is Darwin-only. The native Cocoa/CoreText window has no Linux
implementation (`build.zig`: app-shell tests and the `read`/`read-test`
binaries link Darwin-only); the Linux CI job covers the core
(scan/layout/parser) only.

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
