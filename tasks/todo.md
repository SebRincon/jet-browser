# First working version

- [x] Copy standalone browser engine, assets and source provenance.
- [x] Build and launch native browser with tabs, address bar and chat panel.
- [x] Vendor vten's shadcn_flutter locally and migrate browser/chat controls.
- [x] Consolidate all task activity into one Grok chat interface; local models are tools.
- [x] Improve the GUI with high-contrast dark styling and vten-style Markdown messages.
- [ ] Resolve the intermittent prefilled-form input failure after navigation (retained evidence; fresh forms pass).
- [x] Implement private native bridge and serialized local task control plane.
- [x] Extract/configure LFM, SemIf and Laya adapters plus local typing helper.
- [x] Stream Grok chat and connect task-level MCP tools (live list-tabs verified).
- [x] Run all four local models on the native fresh form and independently verify actual values.
- [x] Fix unified Stop during provider startup; add a regression test.
- [x] Complete the full Grok-to-local-model form handoff in the final UI; verified the user's actual completed run.
- [x] Document final launch/recovery, actual results, limits and review tour.
- [x] Route simple navigation locally before Grok, using the measured SemIf 4B router.
- [x] Verify actual local Wikipedia lookup, follow-up, back/forward and tab listing without Grok.
- [x] Persist conversations/routes/tasks and pass bounded relevant history into fresh Grok sessions.
- [x] Verify restart restoration and actual Grok recall of earlier local pages/current page.
- [x] Follow vten's compact chat/composer/tool/history UX and preserve manual scrolling.
- [x] Vendor the vten chat presentation and render those widgets in the agent pane.
- [x] Add private rotating correlated traces, local SDK spans, timings/errors and expandable UI diagnostics.
- [x] Verify an actual failed local task and successful Grok recovery through one trace.
- [x] Fence late provider tools and cancel queued native commands on Stop.
- [x] Preserve task results when diagnostic storage fails; keep metadata out of conversation content.

Remaining product work: the known prefilled-form input issue; broader held-out workflow validation beyond the current Wikipedia and YouTube cases; Claude Code/Codex provider adapters; frames/complex editors; a signed distributable app; and downloading large assets on another machine. The router/application controls are bounded, not general control of every native app screen.

## Intent completion and local-first audit

- [x] Separate requested search results from an actual destination and check original request evidence.
- [x] Bound observed-link choices to the local engine limit; retain late candidates, stale guards and Stop.
- [x] Run six native navigation regressions locally, including misspelled Elon, SpaceX, Ada follow-up and Quantum alias; preserve earlier failures.
- [x] Audit all 18 official Jev cookbooks and run 24 diagnostic routing probes on four local engines.
- [x] Typed navigation goals and completion checks across search and explicit URLs.
- [x] Known-site homepages without query extraction; resource-specific YouTube navigation with independent native checks.
- [ ] Extend goal/outcome contracts to generic page tasks and form verification.
- [ ] GitHub repository/release workflows and a broader owned site-fixture corpus.
- [x] Capability-aware tab selection beyond 15 tabs (2026-09-28, `LocalRouter.choose_bounded`).
- [ ] Local exact-span extraction and semantic find-in-page, with no-answer checks.
- [ ] Calibrated per-skill routing/recovery and 120-case whole-goal corpus with separate held-out data.

See [audit and implementation order](../docs/local-first-agent-audit.md). Proposed capabilities are not counted as shipped.

## Desktop UX and harness

- [x] Resize/collapse chat while preserving drafts and scroll; compact shell and visible loading.
- [x] Editable starter examples, searchable history and current-turn progress with honest outcome wording.
- [x] Authoritative busy state, duplicate-send protection and Stop during routing/provider startup.
- [x] Native navigation harness with independent oracles, per-turn Stop, user takeover guards and retained failures.
- [x] Expand behavioral widget and backend fault tests; build the real macOS release.

## Browser Lab and expanded Jev experiments — planned 2026-09-28

The active [implementation plan](plan.md), [remaining-work index](remaining-work.md), [20-demo/18-cookbook catalog](../docs/browser-lab-experiments.md), and [benchmark protocol](../docs/browser-lab-benchmark.md) continue the earlier open items. The checklist below is planned work, not new tested capability. Detailed acceptance, ownership and dependencies are in [specified children](browser-lab-work-items.md).

- [ ] B01: Freeze sources and define resettable lab cases.
- [ ] B02: Bound candidate selection and support large tab sets.
- [ ] B03: Share goal and outcome contracts across tasks.
- [ ] B04: Build an offline-first experiment runner.
- [ ] B05: Show one real lab run in the existing chat.
- [ ] B06: Extract exact page values.
- [ ] B07: Find a relevant passage on the current page.
- [ ] B08: Render evidence cards and reopen sources.
- [ ] B09: Add GitHub repository and release workflows.
- [ ] B10: Retain structured conversation references.
- [ ] B11: Fix the prefilled-input failure.
- [ ] B12: Verify bounded form completion.
- [ ] B13: Execute reusable parameterized workflows.
- [ ] B14: Save and run workflows through chat.
- [ ] B15: Apply catalog filters and date constraints.
- [ ] B16: Rank search results for the requested intent.
- [ ] B17: Scout source-backed job listings.
- [ ] B18: Collect research evidence for Grok.
- [ ] B19: Check answer citations and contradictions.
- [ ] B20: Run acceptance journeys against owned sites.
- [ ] B21: Replay a captured run without executing it.
- [ ] B22: Export a watchable task recording.
- [ ] B23: Handle voice-style commands and corrections.
- [ ] B24: Offer reversible semantic focus mode.
- [ ] B25: Probe website-declared tools in Jet's engine.
- [ ] B26: Probe advanced page-control boundaries.
- [ ] B27: Register all eighteen cookbook experiments.
- [ ] B28: Calibrate per-skill routing and abstention.
- [ ] B29: Measure focused context and chunking.
- [ ] B30: Measure batching and cache behavior.
- [ ] B31: Try bounded offline question tuning.
- [ ] B32: Compare results and graduate selected skills.
- [ ] B33: Configure a separate Lab service runtime (Phase 0; before native demos).
- [ ] B34: Bind a Lab browser to an isolated profile (Phase 0; before native demos).

## Chat references and hybrid collection loops — planned 2026-09-28

[Source audit and UX/loop design](../docs/chat-and-hybrid-loops.md) inspects Orca/T3 at pinned revisions. [Specified children](chat-loop-work-items.md) add website/bookmark collections while continuing B13/B18. The first website collection slice is implemented; [current evidence and limits](../docs/collections.md). Full child acceptance is tracked below.

- [x] U01: Simplify the chat transcript around stable turns (offline regression coverage).
- [ ] U02: Keep the composer and task controls coherent.
- [ ] U03: Show collections beside the same conversation.
- [ ] H01: Validate on-demand loop plans.
- [ ] H02: Persist collection records and discovery checkpoints.
- [ ] H03: Classify batches with versioned categories.
- [ ] H04: Execute resumable hybrid loops.
- [ ] H05: Connect Grok planning and bounded loop tools.
- [ ] H06: Collect information from a scoped website.
- [ ] H07: Organize a bookmark collection from observed pages.
- [ ] H08: Prove whole-loop recovery and categorization.


### First collection slice — implementation progress

- [x] Validated fixed taxonomy and bounded observed-tab website scope.
- [x] Private collection storage with atomic item/checkpoint commits and session isolation.
- [x] Local finite-choice classification with honest missing confidence and excerpt coverage.
- [x] Background loop, cooperative Pause, fenced Stop and explicit restart Resume.
- [x] Grok collection MCP tools and authenticated local result/control/export routes.
- [x] One chat card and a searchable collection workspace using the vendored Flutter UI.
- [x] Independent offline recovery/API/UI tests and a 20-case real local-model diagnostic.
- [ ] User-started live native/Grok acceptance of the new collection path.
- [ ] Bookmark adapter, chunked classification, full-document coverage and held-out calibration.

The unchecked H/U parents retain their wider acceptance criteria; first-slice implementation does not complete all 45 planned children.

## Feed loop repair — 2026-09-28

- [x] Preserve the failed History-to-Likes crawl and diagnose the source mismatch.
- [x] Add observed feed capability inspection, per-post extraction, local chunk classification and guarded scrolling.
- [x] Save atomic per-post progress, deduplicate on resume, preserve Stop and uncertain-action fences.
- [x] Verify real DOM fixtures and four Jet-native passes, including Grok and direct UI-endpoint resumes.
- [x] Build/test post-and-scroll progress UI; retain the existing native window until the next user restart.
- [ ] Broader account/cursor recovery and held-out classification accuracy.

Evidence: [feed audit](../docs/feed-collections.md), [source-pinned results](../docs/feed-verification-20260928.json).


## Long jobs, quiet chat and workspace — 2026-09-28

- [x] Continuous feed limits and same-collection resume reconfiguration.
- [x] Local progress reviews with source/Stop fences and loading-state rechecks.
- [x] Background-safe chat with exclusive browser ownership.
- [x] Private conversation scratch/artifacts, finite tools, sandboxed browser previews.
- [x] Compact live job card and expandable intermediate narration.
- [x] Real SemIf + Chromium loop and real Grok artifact acceptance; isolated UI/regression tests.
- [ ] Held-out progress calibration for 350M LFM / Laya; larger archive endurance and explicit cursor recovery.

Current contracts and evidence: [background jobs](../docs/background-jobs-and-workspace.md).

## Supervised collection checkpoints

- [x] First-ten review, periodic Grok supervision and user escalation.
- [x] Same-collection additive taxonomy revisions and selected metadata fields.
- [x] Observed author/date storage, honest missing values and metadata export.
- [x] Compact sample table, live counts/elapsed time and explicit continuation controls.
- [x] Chat/session/Stop fencing and budgets retained across automatic reviews.
- [x] Real Grok review on preserved user collection; 284 backend / 50 Flutter tests.
- [ ] Historical relabel/backfill, expanded-post recovery and multi-hour endurance.

## Tab-bound background work — 2026-09-28

- [x] Collection ownership follows its tab while the user browses elsewhere.
- [x] Exact post recovery and guarded expansion with local reclassification.
- [x] Compact tab indicators and keyboard-accessible controls.
- [x] Bundle and test a native JavaScriptCore workflow helper.
- [ ] Native background CEF acceptance after safe app/sidecar restart.
- [x] Grok workflow authoring/versioning/correction SDK, local multitag/summaries, checkpoints and resumable execution; real Grok acceptance passed.
- [x] Bundle controller/model dependencies, Grok and JavaScript runtime; in-app pinned model downloads and sign-in.
- [ ] Developer ID/notarization and clean-account native/Keychain acceptance.

See [current truth and limits](../docs/tab-bound-jobs.md).
