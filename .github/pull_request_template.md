## What this PR does

<!-- 1–3 sentences. Link related issues: Fixes #NNN. -->

## Pre-commit checklist (required — see CONTRIBUTING.md)

- [ ] `zig build test -Doptimize=ReleaseFast --summary all` is green (100% tests + strict benchmarks)
- [ ] No benchmark target was loosened (`src/core/strict_benchmarks.zig` untouched or tightened only)
- [ ] Screenshots regenerated via `./scripts/screenshot_suite.sh screenshots` and staged (if rendering changed)
- [ ] `test_cases/` discipline kept: no new scrollable doc beyond the single `scrollable_doc.md`
- [ ] Binary footprint still < 180 KiB (`./scripts/size_gate.sh`), zero new dependencies

## Screenshots

<!-- Paste before/after PNGs for any visual change. -->
