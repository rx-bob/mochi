# Feedback composition regression fixture

Framework-owned Ruby reproductions promoted from the 2026-11-14 feedback review. No Cowboy source or checkout is required. Run `task framework:feedback`; `task framework:e2e` includes this suite. Playwright runs Chromium, Firefox, and WebKit.

The browser tests cover nested typed children, conditional remounts, multiple typed events, prop replacement and reordering, delayed descriptors, canceled mounts, geometry, scoped shortcuts, repeating timers, persisted String storage, and a component with 118 authored methods plus 140 distinct binding getters across two instances. Synthetic `DataTransfer` checks prove registration and transfer handling; they do not prove native operating-system drag initiation. The raw-markup wrapper observation remains research evidence, not an expected contract.

Compiler and Ruby-surface research probes remain separate in `scripts/research_cowboy_feedback.rb`. See `references/COWBOY_FEEDBACK_REVIEW.md` for conclusions and limits.
