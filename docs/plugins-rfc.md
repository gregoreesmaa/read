# RFC: Plugin support for fenced-code extensions (Mermaid et al.)

Status: proposed. Closes #41 (RFC-DOC-ONLY — no engine ships with this PR).

## 1. Problem

Ecosystem Markdown relies on fenced-code languages that `read` cannot render
today — the fence source is shown as literal text (e.g. ` ```mermaid ` diagrams,
` ```math `, `:::note` containers). Before committing to any architecture
(AGENTS.md §5: heavy features are discussed BEFORE implementation), this RFC
settles scope and mechanism.

## 2. Hard constraints (non-negotiable, from AGENTS.md / VISION.md)

- Zero dependencies. No JS engine, no SVG library, no network fetches.
- Zero heap allocations on the hot path; virtualized viewport (only visible
  tokens parsed/rendered); memory-mapped zero-copy source.
- Ship binary strictly <180 KiB (`scripts/size_gate.sh`).
- Strict benchmarks and scroll-feel targets in
  `src/core/strict_benchmarks.zig` stay green and are never loosened.
- Structural leanness: test/debug tooling lives behind compile-time gates;
  production surfaces a minimal interface — unknown input is rejected, never
  silently absorbed.

Two structural facts bound the design:

1. `Line` (`src/core/simd.zig`) is an 8-byte packed struct. There is **no
   room for per-line plugin metadata** — a plugin tag cannot ride the line
   index. Any dispatch must re-derive the fence info string from the
   zero-copy source slice at render time.
2. Code blocks are measured and drawn as fixed-height mono cards
   (`src/layout/viewport.zig`, `code_fence_start` scan). A plugin that needs
   intrinsic sizing (diagram layout, math typesetting) cannot reuse this path;
   it would need its own measure pass, which the single-pass virtualized
   layout does not have.

## 3. Decision: dispatch

**Fence info-string registry, exact match, comptime table.**

- At render time, when a `code_fence_start` line is visible, the renderer
  takes the first whitespace-delimited token of the info string and looks it
  up in a comptime-static table (`mermaid`, `math`, …).
- Exact match only (case-sensitive, matching CommonMark info-string
  handling). Unknown or missing info string → plain code block, exactly as
  today. Zero per-frame cost for non-plugin fences: one token hash, no
  allocation, no heap.
- Non-fence syntaxes (`$…$` math, `[^1]` footnotes, `==mark==`) are NOT
  dispatched through this registry; each is judged below as core or out.

## 4. Decision: fallback

**Missing/unavailable plugin renders the fence source as a plain code block,
byte-identical to today's rendering, with the info string kept visible.**
Layout never breaks (fixed-height mono card path is unchanged), and nothing
is silently absorbed: the reader always sees there *is* a `mermaid`/`math`
block and its full source. Fixture: `test_cases/plugin_fallback.md`.

## 5. Per-candidate decisions

| Candidate | Verdict | Rationale |
|---|---|---|
| Mermaid (` ```mermaid `) | OUT of ship binary forever; registry name reserved | A diagram engine needs graph layout + vector rendering — orders of magnitude over the size/alloc budget. Revisit only as an external pre-render cache tool; no IPC in the reader. Fallback: source as code. |
| Math (` ```math `, `$…$`) | OUT of ship binary forever | KaTeX/MathJax-class typesetting needs fonts + layout engine (JS or large tables). Inline `$…$` additionally collides with currency text; stays literal. Fallback: source as code. |
| Footnotes (`[^1]`) | IN SCOPE as core, not a plugin (future issue) | GFM-adjacent, single-pass renderable, no registry needed. |
| Admonitions, GitHub-alert form (`> [!NOTE]`) | IN SCOPE as core styling (future issue) | Blockquote-prefix form; table-driven tint, no new block syntax. |
| Admonitions, container form (`:::note`) | OUT | New block syntax + layout risk for little gain over the alert form. |
| Mark (`==highlight==`, `<mark>`) | IN SCOPE as core inline (see #40) | Cheap inline span, not a plugin. |
| Definition lists | OUT forever | Two-pass layout over term/definition pairs; conflicts with virtualized single-pass measurement. |
| Emoji shortcodes (`:+1:`) | OUT forever | Needs a large shortcode table (≈100 KB class data); threatens the binary budget and buys nothing over literal Unicode emoji, which the system font already renders. |
| Frontmatter (`--- … ---`) | IN SCOPE as core (future issue) | Cheap block skip at document start; render nothing. |
| TOC (`[[toc]]`) | OUT forever | Requires whole-document heading collection before layout; fundamentally at odds with viewport-virtualized single-pass rendering. |

## 6. What stays out forever

Script/style execution, network fetches, JS/WASM engines, full HTML parsing,
anything requiring runtime dependencies, heap allocation on the hot path, or
background threads without a proven net resource win (VISION.md §2).

## 7. Conformance

- Whatever ships under this registry is covered by fixtures in `test_cases/`
  (first: `test_cases/plugin_fallback.md`) and staged screenshots per the
  pre-commit protocol.
- The registry itself must cost ~0 bytes for documents that use no plugins
  (comptime table, exact-match lookup on visible fences only), verified via
  `scripts/size_gate.sh` and the strict benchmarks on every PR.
