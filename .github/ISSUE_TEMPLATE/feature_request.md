---
name: Feature request
about: Propose a feature that fits the zero-allocation, microsecond-grade architecture
title: "[feat] "
labels: enhancement
---

## Proposal

<!-- What should Read do that it doesn't today? -->

## Fit with the architecture

<!-- Hot-path cost: allocations? branches? Does it touch scrolling, rendering,
layout, or tokenization? If it needs recursive ASTs, large tables, or anything
that threatens the zero-allocation budget, say so — per AGENTS.md, heavy
Markdown features need discussion BEFORE implementation. -->

## Benchmark impact

<!-- Which strict targets (scan GB/s, 450 µs/50k, 20 µs mmap, 12 µs viewport,
12 µs deep-scroll, 0 allocations, 8-byte Line, < 500 KB) could move, and why
they will still pass. -->
