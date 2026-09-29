# Chat and hybrid-loop work items

2026-09-28. **Implementation update:** initial chat, website collection and feed/bookmark slices are implemented; see [current evidence](../docs/feed-collections.md). The original broader acceptance contracts below are not all fulfilled. Parent: [active plan](plan.md), [charter](../docs/SPEC.md), [source audit and design](../docs/chat-and-hybrid-loops.md). These 11 children extend the 34 existing Browser Lab items, for 45 planned tasks. They continue B13/B18 through shared records and execution; they do not create a second workflow engine.

Shared pins: original [source baseline](browser-lab-baseline.json), app `0.1.0+1`, unborn HEAD; [Orca/T3 file pins](chat-loop-reference-audit.json). Changes remain experimental until their tests and model gates pass. Code is authoritative; the original contracts and proposed paths below include future work. Current source/evidence mappings take precedence. Product implementation follows the user's Grok Build preference.

## U01: Simplify the chat transcript around stable turns

**Outcome:** Make requests, replies and compact work summaries easy to scan without losing detail.

**Progress:** Not started; research/specification only.

**Current truth:** agent_pane.dart mixes grouping and widgets and keeps tool activity open throughout streaming.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `app/lib/chat_projection.dart`, `app/lib/agent_pane.dart` (existing/proposed).

**In / Out:** Typed presentation projection and compact activity; preserve the existing vten/shadcn widgets and theme.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] One assistant turn groups repeated work under a stable activity row; errors and requested input remain discoverable.
- [ ] Markdown streaming, expanded details and reconnect events preserve stable keys and reader position.
- [ ] No second chat, terminal emulation, permanent model toolbar or full upstream UI transplant.

**Verification:** Run flutter test test/chat_projection_test.dart test/agent_pane_test.dart and flutter analyze from app/. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** Existing app only; the first UI projection consumes current event types. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `app/lib/chat_projection.dart`, `app/lib/agent_pane.dart`, `app/lib/chat_widgets.dart`, `app/test/chat_projection_test.dart`, `app/test/agent_pane_test.dart`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Medium, plus corresponding documentation updates.

## U02: Keep the composer and task controls coherent

**Outcome:** Use one stable composer for questions, page context, queued follow-ups and task controls.

**Progress:** Not started; research/specification only.

**Current truth:** The composer supports busy/Stop and per-session drafts; queue/pause semantics are not implemented.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `app/lib/run_controls.dart`, `app/lib/composer_context.dart` (existing/proposed).

**In / Out:** Context chips, run-scoped questions and supported lifecycle actions; no simulated queue or implicit plan change.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Current-page/selection chips identify scope and can be removed without deleting a draft.
- [ ] Pause/Resume/Stop and queued follow-ups reflect acknowledged backend state; stale question replies are rejected.
- [ ] Keyboard/IME, disconnected state, narrow panes and session switching preserve draft and focus.

**Verification:** Run flutter test test/run_controls_test.dart test/shell_ux_test.dart and flutter analyze from app/. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** U01, H04. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `app/lib/run_controls.dart`, `app/lib/composer_context.dart`, `app/lib/agent_pane.dart`, `app/lib/sidecar_api.dart`, `app/test/run_controls_test.dart`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Medium, plus corresponding documentation updates.

## U03: Show collections beside the same conversation

**Outcome:** Open a searchable category collection while retaining the current chat and source context.

**Progress:** Not started; research/specification only.

**Current truth:** Evidence cards are planned in B08; there is no item collection view.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `app/lib/collection_view.dart`, `app/lib/collection_item.dart` (existing/proposed).

**In / Out:** Grouped/searchable items, review bucket and CSV/Markdown export; no source-site bookmark mutation.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Counts use committed unique records; unknown totals do not display invented percentages.
- [ ] Items preserve source/quote/version and support category edits without overwriting historical assignments.
- [ ] A 1,000-item synthetic collection stays usable with virtualized rows, keyboard access and retained filters.

**Verification:** Run flutter test test/collection_view_test.dart and flutter analyze from app/. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** U01, H02, H03, H04. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `app/lib/collection_view.dart`, `app/lib/collection_item.dart`, `app/lib/agent_pane.dart`, `app/lib/sidecar_api.dart`, `app/test/collection_view_test.dart`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Medium, plus corresponding documentation updates.

## H01: Validate on-demand loop plans

**Outcome:** Let Grok compose supported operations into a bounded collection job.

**Progress:** Not started; research/specification only.

**Current truth:** The task tool accepts a free-form goal; no finite foreach/discovery contract exists.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `backend/jet_browser/loop_contracts.py`, `backend/jet_browser/goals.py` (existing/proposed).

**In / Out:** Versioned schema and validator for registered operations; no generated code, recursion or permission expansion.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Every plan declares source scope, requirements, destination, taxonomy mode/version, stopping conditions and budgets.
- [ ] Unknown operators, invalid fields and out-of-scope actions fail before dispatch.
- [ ] Plan revisions retain original intent and explicitly record changes; no valid-label-only success.

**Verification:** Run uv run --project backend python -m pytest backend/tests/test_loop_contracts.py -q from project root. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** B03. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `backend/jet_browser/loop_contracts.py`, `backend/jet_browser/goals.py`, `backend/tests/test_loop_contracts.py`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Small, plus corresponding documentation updates.

## H02: Persist collection records and discovery checkpoints

**Outcome:** Retain collected evidence, source identity and progress across pauses and restarts.

**Progress:** Not started; research/specification only.

**Current truth:** sessions.py persists messages/tasks/routes, not frontiers or item versions.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `backend/jet_browser/collections.py`, `backend/jet_browser/collection_migrations.py` (existing/proposed).

**In / Out:** Collection store with additive schema migration and idempotent local record writes.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Stable source IDs/canonical URLs and content versions deduplicate repeated virtual rows without merging distinct posts.
- [ ] Record, classification and checkpoint commits recover consistently after a simulated crash.
- [ ] Account/session scope, evidence lineage, pagination and historical taxonomy assignments survive restore.

**Verification:** Run uv run --project backend python -m pytest backend/tests/test_collections.py backend/tests/test_sessions.py -q from project root. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** H01, B06. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `backend/jet_browser/collections.py`, `backend/jet_browser/collection_migrations.py`, `backend/jet_browser/sessions.py`, `backend/tests/test_collections.py`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Medium, plus corresponding documentation updates.

## H03: Classify batches with versioned categories

**Outcome:** Apply consistent local classification to many records while surfacing uncertainty.

**Progress:** Not started; research/specification only.

**Current truth:** Finite model adapters exist; batch collection classification and editable taxonomy versioning do not.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `backend/jet_browser/classification.py`, `backend/jet_browser/taxonomy.py` (existing/proposed).

**In / Out:** Single/multi-label taxonomy, bounded candidates and source-backed item assessment; no category drift per item.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Every result records category/model/prompt/content revisions; no-answer and uncertainty are explicit.
- [ ] Adapter limits and batching behavior are measured; missing native confidence remains null.
- [ ] Taxonomy changes produce a new version and explicit reclassification, with independently labeled accuracy and review coverage.

**Verification:** Run uv run --project backend python -m pytest backend/tests/test_classification.py -q from project root. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** H01, H02, B02. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `backend/jet_browser/classification.py`, `backend/jet_browser/taxonomy.py`, `backend/tests/test_classification.py`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Small, plus corresponding documentation updates.

## H04: Execute resumable hybrid loops

**Outcome:** Run collect/classify/save cycles with real progress, pause/resume and bounded recovery.

**Progress:** Not started; research/specification only.

**Current truth:** TaskManager handles one bounded task; it is not a durable item scheduler.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `backend/jet_browser/loop_runner.py`, `backend/jet_browser/run_events.py` (existing/proposed).

**In / Out:** One scheduler around existing registered skills, using item checkpoints and ordered events.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Resume reobserves cursor hints, skips committed item/version work, and never auto-retries an uncertain site mutation.
- [ ] Stop/pause prevent later dispatch at the defined boundary; budget, login block and stalled discovery preserve partial results.
- [ ] Ordered durable events support reconnect/deduplication; queued follow-ups apply only at a recorded safe boundary.

**Verification:** Run uv run --project backend python -m pytest backend/tests/test_loop_runner.py backend/tests/test_task_diagnostics.py -q from project root. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** H01, H02, H03, B04. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `backend/jet_browser/loop_runner.py`, `backend/jet_browser/run_events.py`, `backend/jet_browser/tasks.py`, `backend/jet_browser/service.py`, `backend/tests/test_loop_runner.py`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Medium, plus corresponding documentation updates.

## H05: Connect Grok planning and bounded loop tools

**Outcome:** Have Grok prepare or revise a loop, let local workers do repeated decisions, and return evidence for synthesis.

**Progress:** Not started; research/specification only.

**Current truth:** Existing ACP/MCP delegates page tasks and history; collection-plan tools are absent.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `backend/jet_browser/mcp.py`, `backend/jet_browser/service.py` (existing/proposed).

**In / Out:** Add finite prepare/start/status/revise tools and bounded exception context; extend the existing provider.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Local supported navigation still bypasses Grok; new compound collection requests get a validated plan.
- [ ] Grok receives bounded samples/aggregates and unresolved requirements under the selected context policy; private content handling is visible.
- [ ] All planning/repair/synthesis calls count in traces/cost; provider loss does not erase the job or silently reroute data.

**Verification:** Run uv run --project backend python -m pytest backend/tests/test_loop_handoff.py backend/tests/test_grok.py -q from project root. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** H01, H04, B10. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `backend/jet_browser/mcp.py`, `backend/jet_browser/service.py`, `backend/jet_browser/grok.py`, `backend/jet_browser/conversation.py`, `backend/tests/test_loop_handoff.py`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Medium, plus corresponding documentation updates.

## H06: Collect information from a scoped website

**Outcome:** Build an evidence-backed collection from a website section and report what remains uncovered.

**Progress:** Not started; research/specification only.

**Current truth:** Navigation/extraction primitives exist or are planned, but there is no persistent crawl frontier.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `backend/jet_browser/site_collection.py`, `backend/tests/fixtures/browser_lab/site_collection.html` (existing/proposed).

**In / Out:** Observed-link traversal on declared origins with conservative URL normalization and explicit field/topic coverage.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Respect page/depth/time limits and meaningful query parameters; calendar/filter cycles cannot run indefinitely.
- [ ] Every fulfilled field points to captured evidence; inaccessible pages and contradictory sources stay visible.
- [ ] Completion distinguishes exhausted declared frontier from capped, stalled or partial discovery; no claim to all unknowable site content.

**Verification:** Run uv run --project backend python -m pytest backend/tests/test_site_collection.py -q from project root; native acceptance later uses a user-started isolated fixture run. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** H04, H05, B07, B08. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `backend/jet_browser/site_collection.py`, `backend/tests/fixtures/browser_lab/site_collection.html`, `backend/tests/test_site_collection.py`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Small, plus corresponding documentation updates.

## H07: Organize a bookmark collection from observed pages

**Outcome:** Collect and categorize saved posts into Jet without silently changing the source account.

**Progress:** Initial source adapter implemented; 9 real DOM cases and four bounded native passes. Broader acceptance remains partial.

**Current truth:** Observed English X Bookmarks and generic permalink feeds support local classification, guarded scrolling, atomic progress, deduplication and explicit resume. Account-switch identity, deleted-post/rate-limit diagnosis and a durable server cursor remain open.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `backend/jet_browser/bookmark_collection.py`, `backend/tests/fixtures/browser_lab/bookmarks.html` (existing/proposed).

**In / Out:** Synthetic virtualized-list fixture first, followed by user-started authenticated read-only compatibility testing.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Use observed post IDs/URLs and source evidence; handle duplicate/reordered/truncated/deleted items and bounded uncertain classifications.
- [ ] Login/permission/rate-limit states and no-new-item stalls are partial outcomes, not proof the account was exhausted.
- [x] Destination is Jet; source folder edits/deletion require a separate supported mutation flow and are outside this child.

**Verification:** Run the feed loop, tool and real Chromium DOM tests listed in [feed verification](../docs/feed-collections.md#evidence). Four user-authorized native passes saved 35 unique posts; the wider compatibility/accuracy benchmark remains separate. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** H04, H05, U03. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `backend/jet_browser/feed_collection.py`, `backend/jet_browser/feed_runner.py`, `backend/tests/test_feed_dom.py`, `backend/tests/test_feed_loop.py`, `backend/tests/test_feed_tools.py`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Small, plus corresponding documentation updates.

## H08: Prove whole-loop recovery and categorization

**Outcome:** Compare actual collection outcomes across the models and retain failure evidence.

**Progress:** Not started; research/specification only.

**Current truth:** Earlier routing and short navigation results do not establish long collection reliability.

**Pins:** Shared pins above; re-pin implementation and model revisions when running.

**References:** Parent design and `backend/tests/lab_loop_oracles.py`, `backend/tests/fixtures/browser_lab/loop_cases.json` (existing/proposed).

**In / Out:** Independent loop oracles, fault fixtures and paired runs; real login access is not needed for the owned suite.

**Anti-goals:** No second composer/executor, no OS takeover, no generated selectors/scripts, no hidden model substitution, and no external writes implied by collection organization.

**Acceptance:**

- [ ] Score unique-item recall, duplicate rate, field accuracy, classification/abstention and false total-completion claims independently.
- [ ] Cover restart, changed taxonomy, stale IDs, Stop, provider failure and duplicate/out-of-order progress events.
- [ ] Report Grok calls per 100 items and complete-run time/cost; never derive throughput from a single decision or hide hybrid work.

**Verification:** Run uv run --project backend python -m pytest backend/tests/test_loop_acceptance.py -q from project root; explicit real-model runs use the benchmark protocol. Run applicable full backend/app suites after focused checks. Unit tests use fakes and no paid providers. Native results are separate from widget/bridge results.

**Dependencies:** H06, H07, U02. Existing browser tasks are defined in [browser-lab-work-items.md](browser-lab-work-items.md).

**Likely files / ownership:** `backend/tests/lab_loop_oracles.py`, `backend/tests/fixtures/browser_lab/loop_cases.json`, `backend/tests/test_loop_acceptance.py`, `scripts/browser_lab.py`. Preserve others' changes; split new native/module work into a child rather than expanding this list without review.

**Estimated scope:** Medium, plus corresponding documentation updates.
