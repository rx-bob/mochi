# Cowboy feedback research fixture

Framework-owned Ruby reproductions for the 2026-11-14 feedback review. No Cowboy source or checkout is required. Run `cd e2e && npx playwright test gvm_feedback_review --reporter=line` after `task build`.

The browser tests cover nested typed children, conditional remounts, raw helpers, row drag events, delayed descriptors, geometry, scoped shortcuts, repeating timers, and persisted String storage. Some assertions record current behavior (notably the raw-markup wrapper); they do not endorse that behavior as a permanent API decision.

Compiler and Ruby-surface failures are generated separately by `scripts/research_cowboy_feedback.rb`. See `references/COWBOY_FEEDBACK_REVIEW.md` for conclusions and limits.
