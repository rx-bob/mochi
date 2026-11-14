# Feedback composition regression fixture

Framework-owned Ruby reproductions promoted from the 2026-11-14 feedback review. No Cowboy source or checkout is required. Run `task framework:feedback`; `task framework:e2e` includes this suite. Playwright runs Chromium, Firefox, and WebKit.

The browser tests cover built-in `is_a?` results and custom ancestry, qualified helpers and `{each}` expressions, bounded `Array#unshift` ordering and prop isolation, typed props, invalid-call recovery, nested typed children, conditional remounts, multiple typed events, prop replacement and reordering, delayed descriptors, canceled mounts, geometry, scoped shortcuts, mount-owned one-shot/repeating timers with explicit cancellation and failed-mount cleanup, structured preferences restored before render, malformed-value fallback, storage quota/unavailable handling, subscription disposal, and a component with 118 authored methods plus 140 distinct binding getters across two instances. Synthetic `DataTransfer` checks prove registration and transfer handling; they do not prove native operating-system drag initiation. The raw-markup wrapper observation remains research evidence, not an expected contract.

Compiler and Ruby-surface research probes remain separate in `scripts/research_cowboy_feedback.rb`. See `references/COWBOY_FEEDBACK_REVIEW.md` for conclusions and limits.
