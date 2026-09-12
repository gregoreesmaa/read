# Spec: content-driven async plugin rendering (mermaid, d2, graphviz, PlantUML, math)

Status: proposed. Resolves #323 (mermaid), #330 (D2), #329 (Graphviz),
#328 (PlantUML), #326 (KaTeX), #327 (MathJax) — ONE STACKED PR PER
ISSUE (§7). Companion to `docs/plugins-rfc.md` (which decided dispatch
+ fallback, and stays normative where this spec does not override it).

## 1. Goal

Per fence, the reader decides with no user interaction:

- Document does not require it → nothing loads, zero cost.
- Requires it but prerequisites unmet (renderer CLI absent) → the
  plugin NEVER loads: naive render (today's code card), no job, no
  indicator, no retry this session.
- Requires it and prerequisites met → async load with a loading
  indicator on the fence header; on completion the fence renders as
  the plugin output (cached PNG through the image box path).

Non-goals: in-binary layout/typesetting engines (still OUT forever per
the RFC), `:::note` containers (still OUT), interactive diagrams,
visibility-prioritized scheduling (FIFO at open for v1; follow-up).

## 2. Hard constraints (non-negotiable)

- Zero LINKED dependencies; ship binary strictly < 200 KiB
  (`scripts/size_gate.sh`). External renderer CLIs live in the user's
  environment, never in the binary.
- Strict benchmarks and scroll-feel targets never loosen. Bench docs
  contain no plugin fences, so the hot path must not move.
- Issue #14 contract, enforced by source-audit tests: no threads, no
  `fork`/`spawn` in hot files; run loop stays event-driven (no timers,
  no polling, 0% CPU when static). Consequences:
  - `src/core/plugin_cache.zig` (new) is pure computation only and is
    ADDED to the thread-audit file list.
  - Process launching lives ONLY in `src/platform/macos.m` via
    `NSTask` + termination handler (main-runloop callback).
  - No banned substrings (`spawn(`, `fork(`, `std.Thread`,
    `Thread.spawn`, `pthread`) anywhere in Zig sources, comments
    included (substring audit).
- Lean ship: tool CLI knowledge lives in the helper script, not the
  binary. Test/debug hooks behind the existing callback-null pattern
  (see §6), never runtime flags.

## 3. Architecture

Three layers, one direction of knowledge:

1. **Zig state machine** (`src/core/plugin_cache.zig`, new, pure):
   - `pluginLangOf(info_token) ?Renderer`: exact-match comptime table
     over the first fence info-string token:
     `mermaid→mermaid`, `d2→d2`, `dot→graphviz`, `graphviz→graphviz`,
     `plantuml→plantuml`, `puml→plantuml`, `math→math`,
     `tex→math`, `latex→math`, `katex→math`.
   - `fenceHash(renderer, source) u64`: FNV-1a 64 over renderer byte,
     `0x00`, source bytes.
   - `cachePath(buf, renderer, hash)`: `<cache>/read/plugins/
     <renderer>/<16-hex>.png`. Cache root comes from the platform
     (VC: `NSCachesDirectory`).
   - `PluginJob` table: fixed-cap (16 fences/doc; beyond stays code),
     caller-provided buffer, states
     `naive | queued → rendering → ready | failed`.
     `naive` means NO job exists (prerequisites unmet or cap hit):
     the fence is code, forever this session, with no indicator.
     Readiness = file-exists check on the cache path.
   - Doc-level `has_plugin_fences` (one scan at open): when false,
     every per-layout plugin branch is skipped — zero hot-path cost.
2. **Prerequisite probe** (at open, before any job exists): the
   launcher asks the helper `probe <renderer>` per renderer present
   in the document (each a fast `command -v`; results cached for the
   session). Absent tool → every fence of that renderer is `naive`:
   the plugin does not load at all.
3. **Launcher** (`src/platform/macos.m` only): on open, asks Zig for
   queued jobs; runs at most ONE `NSTask` at a time (FIFO) invoking
   the helper script; the termination handler marks the job and fires
   the EXISTING async-image-arrival redraw path (same anchoring as
   remote images: `VirtualCache.reset` + arrival shift). No timers.
4. **Helper** (`scripts/read-plugin-render.sh` + tool mapping):
   `probe <renderer>` and `render <renderer> <srcfile> <outfile>`;
   `render` re-probes first and exits nonzero when absent (→ `failed`
   → code card, indicator cleared). Resolution order:
   `$READ_PLUGIN_RENDERER`, bundle `Resources/`, then
   `PATH`. Tool table:
   - mermaid: `mmdc -i SRC -o OUT`
   - d2: `d2 SRC OUT`
   - graphviz: `dot -Tpng SRC -o OUT`
   - plantuml: `plantuml -tpng -o OUTDIR SRC`
   - math: first present of `katex`, `mjpage`, `mathjax` with that
     tool's file→PNG flags; none present → nonzero exit (fallback).
     Rationale: no canonical PNG CLI exists for TeX math; the
     pipeline is real for all six, math lights up with user tools.

## 4. Layout integration

- Fence units whose job is `ready` lay out as image boxes through the
  EXISTING image path (aspect-fit, natural size via `image_size_fn`,
  240px fallback while sizing).
- `queued`/`rendering` lay out as today's code card PLUS a muted
  `· rendering…` suffix on the fence header row (in-pipeline text run,
  so measure/render/refine agree bit-for-bit with no new drawing
  code). `naive`/`failed` lay out as today's code card byte-identical
  to now — no indicator, no nag.
- Height estimates differ (card vs image); on arrival the existing
  refine + anchor machinery converges them exactly as for images
  today. Measure/render/refine share the fence-state decision
  function so all three agree bit-for-bit.

## 5. Failure semantics

- Probe says absent → `naive`: no job, no indicator, no retry this
  session; re-probed at next open.
- Nonzero exit / no PNG after exit / PNG undecodable: `failed` →
  code card, indicator cleared, no retry this session.
- Cache write races (two readers): content-addressed bytes are
  identical; last-writer-wins is safe. Partial writes: helper writes
  to `OUT.tmp` + renames (atomic).
- Security: renderers run locally on document bytes (same trust as
  the document); no network by the reader; cache dir only; renderer
  crashes never affect the reader (reaped, marked failed).

## 6. Test story (headless determinism)

- `read-test` leaves the launcher callback null (mirrors the
  `image_size_fn` pattern): jobs never launch, so plugin fences always
  render as code cards there — screenshots stay byte-deterministic
  with no cache seeding.
- Unit tests: table mapping, hash stability/golden vector, lifecycle
  transitions (including `naive` on probe-fail), cap behavior,
  `has_plugin_fences` gating.
- End-to-end: stub renderer script (copies a fixture PNG, answers
  `probe` true) proves probe → queue → render → arrival → image swap
  with zero real tools installed (none are: verified
  `mmdc/d2/dot/plantuml/katex` absent on dev machine; `node`/`java`
  present but drive nothing). A probe-false stub proves the `naive`
  path (no job, no indicator).
- Gates on every commit: full suite + strict benchmarks, both audit
  tests, `size_gate.sh`, screenshot determinism.

## 7. Rollout: one stacked PR per issue

Six PRs, each closing ONE issue, each stacked on the previous:

1. #323 mermaid: full infra (state machine, cache, probe, launcher,
   helper, indicator, tests, docs) + mermaid wiring.
2. #330 D2, 3. #329 Graphviz, 4. #328 PlantUML: one renderer row
   each (table + helper stanza + tests). Small by construction.
3. #326 KaTeX, 6. #327 MathJax: math-renderer rows against the
   shared `math` slot (probe-first; code fallback where the user has
   no math CLI — the pipeline is the deliverable, tools are user env).

Each PR rebases onto its parent at merge time (suite-case numbering,
`spec.md`, screenshots); each carries its own fixture + skeleton
screenshot.
