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
  no polling when idle, 0% CPU when static). Consequences:
  - `src/core/plugin_cache.zig` (new) is pure computation only and is
    ADDED to the thread-audit file list.
  - Process launching lives ONLY in `src/platform/macos.m` via
    `posix_spawn` + main-loop `waitpid` poll (per-slot `WNOHANG`,
    called only while the in-flight count is > 0, so idle frames cost
    nothing). Ratified Task 3 fix loop (issue #323): `NSTask`
    termination handlers fire off-thread, violating the
    no-threads/no-locks model; a bounded per-frame reap of at most 8
    slots is negligible.
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
   - `PluginJob` table: fixed-cap (16 fences/doc; beyond stays code —
     16-entry Zig table vs at most 8 in-flight render children, see
     launcher below),
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
3. **Launcher** (`src/platform/macos.m` only): `launchPluginRender`
   (non-blocking `posix_spawn`, int codes 1 active / 0 queued /
   -1 failed), `pollPluginCompletions` (per-slot `WNOHANG` reap;
   Task 5 calls it only while the in-flight count is > 0), and
   `pluginOutcomeFor` (per-job 1 clean / 0 failed / -1 unknown query
   by outfile path for the ready-vs-failed mark — the reap frees the
   slot, so the exit status would otherwise be unrecoverable). At most
   8 children in flight (`PLUGIN_MAX_INFLIGHT`) against the 16-entry
   Zig job table; the Zig side keeps the overflow queued. Task 5
   invokes the helper script as the renderer, so tool CLI knowledge
   stays in the helper, not the binary. Completion fires the EXISTING
   async-image-arrival redraw path (same anchoring as remote images:
   `VirtualCache.reset` + arrival shift). No timers.
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
   - math (capability canary, issues #326/#327): NO presence probe.
     No canonical PNG CLI exists for TeX math — the KaTeX CLI is
     TeX→HTML only, and stock mjpage/mathjax CLIs likewise emit no
     PNG — so `command -v` would lie (probe-true/render-always-fail).
     Instead `probe math` renders a minimal TeX snippet to a tmp file
     with each first-present tool in katex→mjpage→mathjax order and
     passes only when the bytes carry PNG magic (89 50 4E 47); the
     first tool passing wins and its name is recorded for the render
     path. None capable → nonzero exit → naive code cards (no spawn,
     no indicator flicker). Convention flags (user wrappers that
     speak them light up): katex/mjpage `TOOL SRC -o DST`, mathjax
     `TOOL SRC DST`. `render math` uses the canary-proven tool only
     and promotes PNG bytes or nothing (the reader-side decode check
     fails closed on top).

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
  session. Probe verdicts are cached ONCE per session (process
  lifetime): installing a renderer mid-process lights up only after
  restart; re-probed at next open. (Math: the verdict is the canary
  outcome; the winning tool name rides a helper-side handoff file,
  re-validated — `command -v` plus fresh-canary fallback — at every
  render, so a stale entry fails closed.)
- Nonzero exit / no PNG after exit / PNG undecodable: `failed` →
  code card, indicator cleared, no retry this session.
- Cache write races (two readers): content-addressed bytes are
  identical; last-writer-wins is safe. Partial writes: the atomic
  `OUT.tmp` + rename is owned by the helper script (Task 5 scope);
  the C layer validates the outfile at reap (exists + nonzero +
  mtime) and reports the verdict via `pluginOutcomeFor`.
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
  `mmdc/d2/dot/plantuml/katex/mjpage/mathjax` absent on dev machine;
  `node`/`java` present but drive nothing). A probe-false stub proves
  the `naive` path (no job, no indicator).
- Gates on every commit: full suite + strict benchmarks, both audit
  tests, `size_gate.sh`, screenshot determinism.

## 7. Rollout: one stacked PR per issue

Six PRs, each closing ONE issue, each stacked on the previous:

1. #323 mermaid: full infra (state machine, cache, probe, launcher,
   helper, indicator, tests, docs) + mermaid wiring.
2. #330 D2, 3. #329 Graphviz, 4. #328 PlantUML: one renderer row
   each (table + helper stanza + tests). Small by construction.
3. #326 KaTeX, 6. #327 MathJax: math-renderer rows against the
   shared `math` slot (capability canary; code fallback where no
   PNG-capable math tool exists — the pipeline is the deliverable,
   tools are user env).

Each PR rebases onto its parent at merge time (suite-case numbering,
`spec.md`, screenshots); each carries its own fixture + skeleton
screenshot.
