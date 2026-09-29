# Browser Lab specified work items

2026-09-28. Parent charter: [SPEC](../docs/SPEC.md); active [plan](plan.md); [remaining work](remaining-work.md). Implementation is **not started** for these children; source discovery and baseline pinning are recorded as planning work. No product implementation or new inference/browser benchmark was performed.

> **Scope update (2026-09-28):** [U01–U03/H01–H08](chat-loop-work-items.md) add compact chat and hybrid collections. B13 and B18 below now share that durable engine. Historical IDs remain stable; no completed task was retitled.

## Shared contract for every child

**Pins:** [baseline](browser-lab-baseline.json), selected-source manifest SHA `ff522f045876ebd39f08b2652256b917e84f2f13c732c33cbd435521596df05d`, unborn HEAD, app `0.1.0+1`; exact upstream revisions in that manifest. New lab features default experimental/off. Re-pin source/model/prompt/build versions for actual implementation runs.

**References:** [experiment catalog](../docs/browser-lab-experiments.md), [benchmark protocol](../docs/browser-lab-benchmark.md), existing [verification history](../docs/VERIFICATION.md). File lists below are expected ownership boundaries, not permission to replace whole modules. Paths not present yet are proposed files. Test commands naming those files become runnable only after the slice implements them. File lists omit routine same-change documentation updates.

**Anti-goals:** no second chat, no new browser/daemon stack, no hidden Grok fallback, no model-generated selectors/scripts, no automatically repeated mutation, no synthetic success animation, no copied upstream score, no cross-session evidence or desktop takeover. Preserve others' changes. Product changes follow the user's Grok Build preference; independent tests/review verify them.

**Verification shared by every task:** run the focused checks below, then the existing backend suite and Ruff for backend changes. For app changes run `flutter analyze` and `flutter test` from `app/`. For native changes build release and record a separate user-started isolated native check. Fake-widget/bridge results do not establish native behavior. No automated command takes over the active user browser. Do not run paid providers in unit tests.

**Dependencies:** all children belong to the same Jet browser-agent experience. Prerequisite IDs below are the implementation graph; existing open todo entries are continued, not duplicated. If a slice requires more than about five product/test files or a second independent subsystem, split a child before implementation. B11 and B26 contain discovery gates for native work.

## B01: Freeze sources and define resettable lab cases

**Outcome:** Make every experiment reproducible from a case manifest and independently labeled expected outcome.

**Progress:** Source discovery/baseline pins recorded; license audit and fixture implementation not started.

**Current truth:** Existing provenance is in docs/extracted-source.json; the practice site is one backend/jet_browser/fixture.html, not a broad corpus.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `tasks/browser-lab-baseline.json`, `backend/tests/fixtures/browser_lab/cases.json` (existing or proposed).

**In / Out:** Pin reference licenses and introduce the synthetic case/reset contract; expanding all fixtures is later.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Every case has a stable ID, family, split, fixture revision, initial state, expected predicates and oracle ID.
- [ ] Pilot manifest defines 60 development decisions and 12 interactive cases without leaking gold labels to the model.
- [ ] Source ledger records permitted copying or inspiration-only status; no upstream runtime is imported.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_lab_cases.py -q
```



**Dependencies:** None beyond the existing app and parent plan.

**Likely files / ownership:** `tasks/browser-lab-baseline.json`, `backend/tests/fixtures/browser_lab/cases.json`, `backend/tests/fixtures/browser_lab/site.html`, `backend/tests/browser_lab_cases.py`, `backend/tests/test_lab_cases.py`.

**Estimated scope:** Small.

## B02: Bound candidate selection and support large tab sets

**Outcome:** Select a relevant observed target even when it occurs after the first chunk or among more than 15 tabs.

**Progress:** Not started.

**Current truth:** routing.py slices up to 24 tabs and adds UNRESOLVED; search/page execution already have different batching paths.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/candidates.py`, `backend/jet_browser/routing.py` (existing or proposed).

**In / Out:** Shared capability-aware selector and tab integration; no prompt-only blanket increase of limits.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Respect each adapter's candidate/context limits with an escape in every question; no silent truncation.
- [ ] Late correct targets, duplicate labels, reordered candidates and no-match cases are covered.
- [ ] Never compare probabilities normalized in separate chunks as a common distribution; preserve Stop and stale guards.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_candidates.py backend/tests/test_routing.py backend/tests/test_intent_completion.py -q
```



**Dependencies:** B01.

**Likely files / ownership:** `backend/jet_browser/candidates.py`, `backend/jet_browser/routing.py`, `backend/jet_browser/conversation.py`, `backend/jev_ultrafast/local_models.py`, `backend/tests/test_candidates.py`.

**Estimated scope:** Medium.

## B33: Configure a separate Lab service runtime

**Outcome:** Run the existing Jet service in a dedicated Lab runtime without changing the normal app's files or ports.

**Progress:** Not started.

**Current truth:** scripts/launch.py and service.py hardcode .runtime and port 9148; profiles, sessions, tokens and model assets are not independently configured.

**Pins:** Shared baseline above; new Lab configuration defaults off.

**References:** Parent plan, benchmark isolation contract, and `scripts/launch.py`, `backend/jet_browser/runtime_config.py`.

**In / Out:** Explicit runtime/config plumbing for the existing service and external launcher; reuse read-only model assets, isolate mutable state.

**Anti-goals:** No takeover of the current app, no replacement of occupied services, and no new browser stack.

**Acceptance:**

- [ ] A Lab instance uses its own runtime directory, token, sessions, traces and loopback endpoint; normal defaults remain unchanged.
- [ ] Health/ownership identifies the intended instance, and occupied ports or another run cause a clean refusal rather than replacement.
- [ ] Sidecars start outside CEF; model-inference ownership prevents contention with the active app, and no benchmark auto-launch occurs.

**Verification:** From project root after implementing the slice:

```sh
uv run --project backend python -m pytest backend/tests/test_lab_runtime.py backend/tests/test_service.py -q
```

Test with fake processes and temporary paths; no running app or provider is needed.

**Dependencies:** B01. These are Phase 0 tasks despite their appended IDs; B05's native demo depends on B34. B04 offline replay can proceed without native isolation.

**Likely files / ownership:** `scripts/launch.py`, `backend/jet_browser/runtime_config.py`, `backend/jet_browser/service.py`, `backend/tests/test_lab_runtime.py`.

**Estimated scope:** Medium.


## B34: Bind a Lab browser to an isolated profile

**Outcome:** Let a user-started Lab window use only its own CEF profile and configured service instance.

**Progress:** Not started.

**Current truth:** browser_host.dart binds CEF cache to root/.runtime/browser-profile; app startup and fixture links assume the normal service port.

**Pins:** Shared baseline above; new Lab configuration defaults off.

**References:** Parent plan, benchmark isolation contract, and `app/lib/main.dart`, `app/lib/browser_host.dart`.

**In / Out:** Validated app runtime configuration and isolated browser instance; no hot profile switch or fork after CEF initialization.

**Anti-goals:** No takeover of the current app, no replacement of occupied services, and no new browser stack.

**Acceptance:**

- [ ] Profile path, bridge endpoint, token and fixture URL all resolve to the same Lab instance while normal launch defaults are unchanged.
- [ ] No normal tab/session/profile is reused; cleanup closes only Lab-owned resources and yields on user interaction.
- [ ] Offline config/widget tests and release build pass; separate native user-started verification establishes actual CEF isolation before live task demos.

**Verification:** From project root after implementing the slice:

```sh
uv run --project backend python -m pytest backend/tests/test_lab_runtime.py -q
```

Run app tests/analyzer and release build too. Native isolation remains unverified until a user-started Lab run.

**Dependencies:** B33. These are Phase 0 tasks despite their appended IDs; B05's native demo depends on B34. B04 offline replay can proceed without native isolation.

**Likely files / ownership:** `app/lib/main.dart`, `app/lib/browser_host.dart`, `app/lib/sidecar_api.dart`, `app/lib/native_bridge.dart`, `app/test/lab_runtime_test.dart`.

**Estimated scope:** Medium.



## B03: Share goal and outcome contracts across tasks

**Outcome:** Every supported task reports which original requirements are reached, unmet or uncertain.

**Progress:** Not started.

**Current truth:** NavigationGoal exists; general TaskManager still returns verification=manual_check.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/goals.py`, `backend/jet_browser/tasks.py` (existing or proposed).

**In / Out:** Shared typed records and compatibility mapping; task-specific form/extraction checkers come in their own slices.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Original goal and constraints survive local/Grok transitions; unsupported compound work is not silently dropped.
- [ ] DONE without evidence remains unverified; known wrong, ambiguous and unknown-after-action outcomes stay distinct.
- [ ] Existing navigation clients and Stop behavior retain their semantics.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_goal_outcomes.py backend/tests/test_navigation_completion.py backend/tests/test_task_diagnostics.py -q
```



**Dependencies:** B02.

**Likely files / ownership:** `backend/jet_browser/goals.py`, `backend/jet_browser/tasks.py`, `backend/jet_browser/conversation.py`, `backend/jet_browser/navigation_completion.py`, `backend/tests/test_goal_outcomes.py`.

**Estimated scope:** Medium.

## B04: Build an offline-first experiment runner

**Outcome:** Run repeatable decisions and independently score owned tasks without touching an active user session.

**Progress:** Not started.

**Current truth:** check_navigation_intent.py and check_navigation_goals.py have ownership/oracle patterns; no unified lab runner exists.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `scripts/browser_lab.py`, `backend/jet_browser/lab.py` (existing or proposed).

**In / Out:** Replay/report runner plus isolated-run ownership contract and hosted capability handling; no automatic native launch.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Import/help/validation/fake tests never read a token or contact providers; real inference requires its own explicit mode.
- [ ] Reset every fixture between attempts, preserve failures/timeouts and reject overlapping inference ownership.
- [ ] Native run requires fresh owned profile/session/tab and user start; hosted Jev stays benchmark-scoped until its adapter is verified.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_browser_lab.py backend/tests/test_navigation_harness.py -q
```



**Dependencies:** B01, B03.

**Likely files / ownership:** `scripts/browser_lab.py`, `backend/jet_browser/lab.py`, `backend/jet_browser/service.py`, `backend/tests/lab_oracles.py`, `backend/tests/test_browser_lab.py`.

**Estimated scope:** Medium.

## B05: Show one real lab run in the existing chat

**Outcome:** Watch a navigation example with live steps, visible outcome evidence and the existing Stop control.

**Progress:** Not started.

**Current truth:** agent_pane.dart already renders task activity and trace details; no lab gallery or stable replay event contract exists.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/lab.py`, `backend/jet_browser/service.py` (existing or proposed).

**In / Out:** Minimal gallery/run card and event rendering; full comparison and recordings follow later.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] A gallery example enters the existing composer/conversation; there is no second chat.
- [ ] Progress reflects acknowledged events with run/turn IDs; duplicate or late events cannot update another run.
- [ ] Stop, narrow layout, keyboard use, draft preservation and live-versus-recorded labels are tested.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_browser_lab.py -q
```

Also run this slice's listed widget tests and the app suite/analyzer from `app/`. Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B04, B34. Native Watch needs the isolated browser; offline rendering can use fixture events earlier.

**Likely files / ownership:** `backend/jet_browser/lab.py`, `backend/jet_browser/service.py`, `app/lib/lab_panel.dart`, `app/lib/agent_pane.dart`, `app/test/lab_panel_test.dart`.

**Estimated scope:** Medium.

## B06: Extract exact page values

**Outcome:** Ask for an email, phone or monetary value and receive the correct observed span with source evidence.

**Progress:** Not started.

**Current truth:** read_page returns page text; no dedicated extraction skill or source-span result exists.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/extraction.py`, `backend/jet_browser/evidence.py` (existing or proposed).

**In / Out:** Code-generated candidates, model role selection, exact copy and normalization; novel prose generation stays outside this skill.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Support support-vs-billing email, total-vs-subtotal amount and phone-role cases without regenerating the selected string.
- [ ] An absent or ambiguous value returns no-answer/need-input; candidate extraction recall is measured separately.
- [ ] Return URL/document/span identity and original value; normalization is coded and locale-aware or explicitly unsupported.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_extraction.py -q
```



**Dependencies:** B03, B04.

**Likely files / ownership:** `backend/jet_browser/extraction.py`, `backend/jet_browser/evidence.py`, `backend/jet_browser/service.py`, `backend/jet_browser/mcp.py`, `backend/tests/test_extraction.py`.

**Estimated scope:** Medium.

## B07: Find a relevant passage on the current page

**Outcome:** Jump to the source passage matching a plain-language request and report when none exists.

**Progress:** Not started.

**Current truth:** snapshot.js returns visible text but has no stable passage-level semantic-find contract.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/semantic_find.py`, `backend/jev_ultrafast/snapshot.js` (existing or proposed).

**In / Out:** Bounded section/passages and code-owned highlight operation; arbitrary page code remains unavailable to models.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Long-page targets outside the first section remain reachable; no-answer and contradictory-near-match examples are retained.
- [ ] A highlight binds to the captured document/span and refuses stale or missing text.
- [ ] Requested text is copied unchanged; semantic relevance remains an assessment, not a guaranteed fact.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_semantic_find.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B02, B06.

**Likely files / ownership:** `backend/jet_browser/semantic_find.py`, `backend/jev_ultrafast/snapshot.js`, `backend/jev_ultrafast/browser.py`, `backend/jet_browser/service.py`, `backend/tests/test_semantic_find.py`.

**Estimated scope:** Medium.

## B08: Render evidence cards and reopen sources

**Outcome:** See collected values and quotes inline and reopen their source with an honest freshness indicator.

**Progress:** Not started.

**Current truth:** Existing Markdown/tool rows and source links lack structured captured-span cards.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/evidence.py`, `backend/jet_browser/sessions.py` (existing or proposed).

**In / Out:** Persist source records and render with the current design system; no new transcript implementation.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Cards show quote/value, source, captured time and which request requirement they support.
- [ ] Reopen/highlight uses current span identity when available; changed pages do not silently substitute evidence.
- [ ] Session restore preserves cards, manual scroll and draft; source text cannot inject a tool action.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_sessions.py -q
```

Also run this slice's listed widget tests and the app suite/analyzer from `app/`.

**Dependencies:** B05, B06, B07.

**Likely files / ownership:** `backend/jet_browser/evidence.py`, `backend/jet_browser/sessions.py`, `app/lib/evidence_card.dart`, `app/lib/agent_pane.dart`, `app/test/evidence_card_test.dart`.

**Estimated scope:** Medium.

## B09: Add GitHub repository and release workflows

**Outcome:** Reach the requested owner/repository, releases page or specific stable release.

**Progress:** Not started.

**Current truth:** GitHub is a recognized provider, but typed repository/release completion is not implemented.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/github_skill.py`, `backend/jet_browser/navigation.py` (existing or proposed).

**In / Out:** Bounded GitHub resource skill; code interpretation and choosing the best dependency remain Grok work.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Repository identity and requested section/resource agree with actual visible state.
- [ ] Stable/prerelease and newest/date comparisons use observed values and coded ordering; missing releases stay missing.
- [ ] Wrong owner, similar name, redirect/login and delayed readiness do not falsely complete.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_github_skill.py backend/tests/test_navigation_goals.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B03, B04, B06.

**Likely files / ownership:** `backend/jet_browser/github_skill.py`, `backend/jet_browser/navigation.py`, `backend/jet_browser/routing.py`, `backend/jet_browser/conversation.py`, `backend/tests/test_github_skill.py`.

**Estimated scope:** Medium.

## B10: Retain structured conversation references

**Outcome:** Understand there, that one and continue using completed entities and unfinished requirements.

**Progress:** Not started.

**Current truth:** Sessions persist messages/routes; local routing predominantly receives the last three request strings.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/references.py`, `backend/jet_browser/sessions.py` (existing or proposed).

**In / Out:** Scoped completed references and pending-goal state; no cross-session global memory.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] References record entity/resource/tab/document, source and time; completed actions are never replayed as history.
- [ ] Ambiguous/stale references ask or reobserve instead of selecting an unrelated target.
- [ ] Grok receives the same relevant references and unmet requirements; session switching isolates them.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_references.py backend/tests/test_sessions.py -q
```



**Dependencies:** B03, B08.

**Likely files / ownership:** `backend/jet_browser/references.py`, `backend/jet_browser/sessions.py`, `backend/jet_browser/routing.py`, `backend/jet_browser/conversation.py`, `backend/tests/test_references.py`.

**Estimated scope:** Medium.

## B11: Fix the prefilled-input failure

**Outcome:** Replace a prefilled field reliably after navigation and preserve the intended value.

**Progress:** Not started. Continues the existing known prefilled-form issue.

**Current truth:** tasks/todo.md retains this native-input failure; fresh-form successes do not prove replacement works.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jev_ultrafast/browser.py`, `vendor/flutter_cef_browser/macos/Classes` (existing or proposed).

**In / Out:** Reproduce and repair one identified native input cause before broad form claims; file list is provisional until diagnosis.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] A minimal fixture reproduces the prefilled issue and retains before/after field state.
- [ ] Replacement does not append, duplicate, type into another field or automatically retry an uncertain mutation.
- [ ] Offline regression covers the identified cause; native success is separately recorded only in a user-started isolated run.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_prefilled_input.py backend/tests/test_bridge.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B04.

**Likely files / ownership:** `backend/jev_ultrafast/browser.py`, `vendor/flutter_cef_browser/macos/Classes`, `backend/tests/fixtures/browser_lab/prefilled.html`, `backend/tests/test_prefilled_input.py`.

**Estimated scope:** Medium; select one native file after reproduction.

## B12: Verify bounded form completion

**Outcome:** Fill supplied values, select requested options and stop at the exact requested form stage.

**Progress:** Not started.

**Current truth:** General tasks currently return manual_check even after useful form actions.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/form_skill.py`, `backend/jet_browser/tasks.py` (existing or proposed).

**In / Out:** Form goal/checker and supplied-value binding; not arbitrary free-text authoring or submission permission.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Check actual input/select/checkbox state against every supplied value and constraint.
- [ ] Distinguish fill, preview/review and submit; a review request leaves submit state unchanged.
- [ ] Missing values, disabled controls, validation errors and dynamically replaced fields remain unmet or blocked.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_form_skill.py backend/tests/test_task_diagnostics.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B03, B06, B11.

**Likely files / ownership:** `backend/jet_browser/form_skill.py`, `backend/jet_browser/tasks.py`, `backend/jev_ultrafast/control_intents.py`, `backend/jet_browser/service.py`, `backend/tests/test_form_skill.py`.

**Estimated scope:** Medium.

## B13: Execute reusable parameterized workflows

**Outcome:** Reuse a named sequence of registered skills with new values and explicit per-step outcomes.

**Progress:** Not started.

**Current truth:** There is no saved-flow engine; current tasks are free-form bounded controller goals.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/flows.py`, `backend/jet_browser/sessions.py` (existing or proposed).

**In / Out:** Saved definitions over H01/H04, parameter binding and shared resume semantics; no recorded-coordinate macros.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Each step names a registered skill, prerequisites, original constraints and an expected result.
- [ ] Resume reobserves state and never repeats a previously dispatched mutation with unknown outcome.
- [ ] Changing parameters or a site's controls requires fresh binding; invalid plans fail before action.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_flows.py backend/tests/test_sessions.py -q
```



**Dependencies:** B03, B10, B12, H01, H04. H01/H04 own the shared plan/loop runtime; this child adds reusable saved definitions.

**Likely files / ownership:** `backend/jet_browser/flows.py`, `backend/jet_browser/sessions.py`, `backend/jet_browser/service.py`, `backend/jet_browser/mcp.py`, `backend/tests/test_flows.py`.

**Estimated scope:** Medium.

## B14: Save and run workflows through chat

**Outcome:** Save a successful task as a named flow and fill its parameters from the existing composer.

**Progress:** Not started.

**Current truth:** Chat has starter examples/settings/history but no saved-workflow presentation.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `app/lib/flow_panel.dart`, `app/lib/agent_pane.dart` (existing or proposed).

**In / Out:** Flow list and parameter preview in the existing pane; one task composer remains.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Show parameters and expected stopping point before the user starts the saved flow.
- [ ] Inline progress refers to actual engine step outcomes and preserves partial completion on Stop.
- [ ] Keyboard, narrow layout, edit/delete saved definitions and restart restoration are tested.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_flows.py -q
```

Also run this slice's listed widget tests and the app suite/analyzer from `app/`.

**Dependencies:** B08, B13.

**Likely files / ownership:** `app/lib/flow_panel.dart`, `app/lib/agent_pane.dart`, `app/lib/sidecar_api.dart`, `app/test/flow_panel_test.dart`.

**Estimated scope:** Medium.

## B15: Apply catalog filters and date constraints

**Outcome:** Reach a filtered result set that satisfies user-supplied numeric, categorical and date constraints.

**Progress:** Not started.

**Current truth:** Existing local actions can manipulate some controls but lack a filter/date goal checker.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/filter_skill.py`, `backend/jet_browser/date_values.py` (existing or proposed).

**In / Out:** Code owns arithmetic, sorting, dates/timezones; the model selects roles and visible controls.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Compare actual selected filter state and visible rows against all constraints.
- [ ] Ambiguous currency/date locale or absent options asks/declines rather than inventing a value.
- [ ] Date extraction, impossible dates, pagination and misleading advertised prices have independent fixture oracles.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_filter_skill.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B06, B12.

**Likely files / ownership:** `backend/jet_browser/filter_skill.py`, `backend/jet_browser/date_values.py`, `backend/jet_browser/service.py`, `backend/tests/fixtures/browser_lab/catalog.html`, `backend/tests/test_filter_skill.py`.

**Estimated scope:** Medium.

## B16: Rank search results for the requested intent

**Outcome:** See a useful result shortlist with explicit reasons matching the user's research preference.

**Progress:** Not started.

**Current truth:** No current search-result relevance feature exists; navigation selects destinations only.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/ranking.py`, `backend/jet_browser/service.py` (existing or proposed).

**In / Out:** Rank captured results in chat first; reversible page reordering is a later optional extension.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Use narrow relevance/promotional/discussion judgments with weights controlled by code.
- [ ] Commercial queries do not automatically penalize product pages; original result order remains accessible.
- [ ] Measure shortlist recall and independently labeled ranking quality, including unseen domains.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_ranking.py -q
```

Also run this slice's listed widget tests and the app suite/analyzer from `app/`.

**Dependencies:** B02, B06, B08.

**Likely files / ownership:** `backend/jet_browser/ranking.py`, `backend/jet_browser/service.py`, `app/lib/search_results_card.dart`, `app/test/search_results_card_test.dart`, `backend/tests/test_ranking.py`.

**Estimated scope:** Medium.

## B17: Scout source-backed job listings

**Outcome:** Collect job listings satisfying role/location constraints from a bounded list of company sites.

**Progress:** Not started.

**Current truth:** JevScout is a reference; no Jet scout workflow exists.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/scout.py`, `backend/jet_browser/service.py` (existing or proposed).

**In / Out:** One job-scout vertical first; shopping/vendors/events reuse follows only if this works.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Every role, location and requirement comes from an actual listing with a source link.
- [ ] Handle stale/duplicate listings and ambiguous remote policies without pretending they satisfy the request.
- [ ] No application submission; run respects site/action budgets and retains partial results.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_scout.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B09, B15, B16.

**Likely files / ownership:** `backend/jet_browser/scout.py`, `backend/jet_browser/service.py`, `backend/tests/fixtures/browser_lab/jobs.html`, `backend/tests/test_scout.py`.

**Estimated scope:** Medium.

## B18: Collect research evidence for Grok

**Outcome:** Ask a multi-source question, see evidence arrive, and get a Grok answer based on the captured sources.

**Progress:** Not started.

**Current truth:** Current Grok reads browser/history context; no requirement-indexed collection exists.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/research.py`, `backend/jet_browser/conversation.py` (existing or proposed).

**In / Out:** Finite information requirements, local navigation/extraction, bounded Grok synthesis; not unrestricted autonomous browsing.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Every requested field is supported, missing, or conflicting; incomplete coverage stays visible.
- [ ] Grok receives exact evidence IDs/quotes and the unresolved requirements, not fabricated replacements.
- [ ] Counts/totals derive from retained records in code; every helper/Grok call and duration is attributed.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_research.py backend/tests/test_grok.py -q
```



**Dependencies:** B08, B13, B16, H05, H06. Reuse the scoped collection frontier; do not create another research crawler.

**Likely files / ownership:** `backend/jet_browser/research.py`, `backend/jet_browser/conversation.py`, `backend/jet_browser/grok.py`, `backend/jet_browser/service.py`, `backend/tests/test_research.py`.

**Estimated scope:** Medium.

## B19: Check answer citations and contradictions

**Outcome:** Distinguish supported conclusions from missing or conflicting source evidence.

**Progress:** Not started.

**Current truth:** Current source links do not constitute a claim-to-evidence support checker.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/citations.py`, `backend/jet_browser/research.py` (existing or proposed).

**In / Out:** Exact source checks plus bounded semantic assessment; not a guarantee from a model judging itself.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Reject unknown evidence IDs and absent/altered quotes deterministically.
- [ ] Independent labels cover entailment, contradiction, unrelated quote and incomplete context.
- [ ] Surface uncertain support and conflict; do not erase failed claims and report the remaining subset as full success.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_citations.py -q
```

Also run this slice's listed widget tests and the app suite/analyzer from `app/`.

**Dependencies:** B18.

**Likely files / ownership:** `backend/jet_browser/citations.py`, `backend/jet_browser/research.py`, `app/lib/evidence_card.dart`, `backend/tests/test_citations.py`, `app/test/evidence_card_test.dart`.

**Estimated scope:** Medium.

## B20: Run acceptance journeys against owned sites

**Outcome:** Ask Jet to test a signup/search flow and receive actionable failures with evidence.

**Progress:** Not started.

**Current truth:** The native navigation harness exists; broad QA fixtures and seeded defects do not.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/qa.py`, `backend/tests/fixtures/browser_lab/qa.html` (existing or proposed).

**In / Out:** Small authored acceptance journeys and deterministic assertions; general visual beauty scoring excluded.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Include valid/invalid inputs, focus/keyboard expectations and resettable seeded defects.
- [ ] Score missed defects and false bug reports separately from journey completion.
- [ ] Retain the exact failing checkpoint and trace; automated tests never touch production state.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_qa.py backend/tests/test_browser_lab.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B04, B12, B15.

**Likely files / ownership:** `backend/jet_browser/qa.py`, `backend/tests/fixtures/browser_lab/qa.html`, `backend/tests/lab_oracles.py`, `backend/tests/test_qa.py`.

**Estimated scope:** Medium.

## B21: Replay a captured run without executing it

**Outcome:** Scrub through real decisions, page evidence and timings after a task completes or fails.

**Progress:** Not started.

**Current truth:** Private metadata traces exist; they are not a page-frame replay store.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/replay.py`, `backend/jet_browser/lab.py` (existing or proposed).

**In / Out:** Separate bounded private capture/event store and replay viewer; fixture capture first.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Replay distinguishes recorded evidence from current page state and never dispatches browser actions.
- [ ] Capture correlates events with exact run/step/document IDs; missing frames are labeled.
- [ ] Redaction, bounded retention and capture failure preserve the task result and existing metadata-only traces.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_replay.py backend/tests/test_tracing.py -q
```

Also run this slice's listed widget tests and the app suite/analyzer from `app/`.

**Dependencies:** B05, B08.

**Likely files / ownership:** `backend/jet_browser/replay.py`, `backend/jet_browser/lab.py`, `app/lib/run_replay.dart`, `backend/tests/test_replay.py`, `app/test/run_replay_test.dart`.

**Estimated scope:** Medium.

## B22: Export a watchable task recording

**Outcome:** Export a synthetic demo run with readable step captions and genuine timings.

**Progress:** Not started.

**Current truth:** No video export exists; source FastBrowse demonstrates a recording pattern.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `scripts/render_lab_video.py`, `backend/jet_browser/replay.py` (existing or proposed).

**In / Out:** Offline renderer of recorded fixture artifacts, not screen takeover or a new live capture mechanism.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Frames, decisions and captions share a monotonic timeline; failures/pauses are not edited out of benchmark exports.
- [ ] Export identifies real-time or accelerated playback and includes actual model configuration.
- [ ] No secrets or unrelated windows/session content; missing renderer dependency yields a clear unavailable result.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_video_manifest.py backend/tests/test_replay.py -q
```



**Dependencies:** B21.

**Likely files / ownership:** `scripts/render_lab_video.py`, `backend/jet_browser/replay.py`, `backend/tests/test_video_manifest.py`.

**Estimated scope:** Small.

## B23: Handle voice-style commands and corrections

**Outcome:** Use conversational commands such as second one or not that one against the observed context.

**Progress:** Not started.

**Current truth:** Text chat exists; no dedicated partial-utterance/correction handling is implemented.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/references.py`, `backend/jet_browser/conversation.py` (existing or proposed).

**In / Out:** Test text transcripts first, then connect an existing opt-in voice input path; do not install a new audio service.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Partial speech does not prematurely dispatch an action; completed text follows the same task authorization.
- [ ] Ambiguous choices are numbered and require a definite selection; changed lists invalidate old numbers.
- [ ] Corrections use the last observed choices and do not silently undo irreversible work.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_voice_commands.py backend/tests/test_references.py -q
```

Also run this slice's listed widget tests and the app suite/analyzer from `app/`.

**Dependencies:** B10.

**Likely files / ownership:** `backend/jet_browser/references.py`, `backend/jet_browser/conversation.py`, `app/lib/voice_input_adapter.dart`, `backend/tests/test_voice_commands.py`, `app/test/voice_input_adapter_test.dart`.

**Estimated scope:** Medium.

## B24: Offer reversible semantic focus mode

**Outcome:** Highlight useful blocks and optionally fold low-relevance/promotional content with instant restoration.

**Progress:** Not started.

**Current truth:** Page block identities and semantic find are prerequisites; no declutter mode exists.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/focus_mode.py`, `backend/jev_ultrafast/snapshot.js` (existing or proposed).

**In / Out:** Highlight-only experiment first, then reversible folding; not tracking protection or a production ad blocker.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Retention of requested content is scored independently, including mixed useful/promotional blocks.
- [ ] Restore reconstructs original visibility; stale document state invalidates the prior selection.
- [ ] Structure labels preserve verbatim text; no model-written replacement HTML or removal of form controls.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_focus_mode.py backend/tests/test_semantic_find.py -q
```



**Dependencies:** B07, B08.

**Likely files / ownership:** `backend/jet_browser/focus_mode.py`, `backend/jev_ultrafast/snapshot.js`, `backend/jev_ultrafast/browser.py`, `backend/jet_browser/service.py`, `backend/tests/test_focus_mode.py`.

**Estimated scope:** Medium.

## B25: Probe website-declared tools in Jet's engine

**Outcome:** Determine whether Jet can safely use a supported page's declared read tools.

**Progress:** Not started.

**Current truth:** Jev WebMCP targets participating sites; native CEF support has not been established.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/web_tools.py`, `backend/tests/fixtures/browser_lab/web_tools.html` (existing or proposed).

**In / Out:** One read-only tool fixture and compatibility report; upgrading CEF or broad production integration is a separate decision.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Record actual CEF/API capability and unavailable behavior; don't infer support from a Chrome README.
- [ ] Tool schema/action is validated by code; a webpage cannot expand permissions or supply arbitrary native commands.
- [ ] Compare a supported fixture's direct-tool result against its ordinary DOM workflow; retain unsupported as an honest result.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_web_tools.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B03, B04.

**Likely files / ownership:** `backend/jet_browser/web_tools.py`, `backend/tests/fixtures/browser_lab/web_tools.html`, `backend/tests/test_web_tools.py`, `docs/web-tools-compatibility.md`.

**Estimated scope:** Medium.

## B26: Probe advanced page-control boundaries

**Outcome:** Expose exactly which custom controls, shadow roots and frame interactions Jet supports.

**Progress:** Not started.

**Current truth:** Existing snapshots cover many ordinary controls but frames/complex editors remain limited.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/tests/fixtures/browser_lab/controls.html`, `backend/tests/test_control_capabilities.py` (existing or proposed).

**In / Out:** Capability probes and one bounded control fix at a time; broad frame/editor/upload support is not bundled into one task.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Each control fixture is supported, blocked or unsupported with evidence; no fall-through click on a similar outer-page target.
- [ ] A chosen first fix has stale-document and actual-value checks; cross-origin boundaries stay explicit.
- [ ] If more than one native/module change is required, split a separately specified child before implementing it.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_control_capabilities.py -q
```

Native acceptance requires a user-started isolated Lab run with the independent oracle; it remains pending until that happens.

**Dependencies:** B04, B12.

**Likely files / ownership:** `backend/tests/fixtures/browser_lab/controls.html`, `backend/tests/test_control_capabilities.py`, `backend/jev_ultrafast/snapshot.js`, `docs/control-capabilities.md`.

**Estimated scope:** Medium; individual support extensions need separate children.

## B27: Register all eighteen cookbook experiments

**Outcome:** Track every official recipe as runnable, unsupported or deferred in the same comparison system.

**Progress:** Not started.

**Current truth:** The prior audit maps all 18 recipes but did not execute their datasets.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `tasks/browser-lab-cookbooks.json`, `scripts/browser_lab.py` (existing or proposed).

**In / Out:** Versioned cookbook manifest and adapters to completed Jet skills; original-domain reproduction stays a separate mode.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] All C01–C18 entries record source, dataset/license, primitive requirements, fixture/adapter and status.
- [ ] Model adapters declare native vs approximated questions; unsupported never masquerades as a score.
- [ ] Each entry links to its implementing child; recipe-specific data/code extraction is scoped and licensed before runs.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_cookbook_manifest.py -q
```



**Dependencies:** B04, B06, B07.

**Likely files / ownership:** `tasks/browser-lab-cookbooks.json`, `scripts/browser_lab.py`, `backend/tests/fixtures/browser_lab/cookbooks.json`, `backend/tests/test_cookbook_manifest.py`.

**Estimated scope:** Medium.

## B28: Calibrate per-skill routing and abstention

**Outcome:** Choose local execution, clarification or Grok using measured skill-specific error and coverage.

**Progress:** Not started.

**Current truth:** SemIf broad routing is development-tested; probability/confidence is not calibrated across these adapters.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/skill_policy.py`, `backend/jet_browser/routing.py` (existing or proposed).

**In / Out:** Frozen splits, evaluation report and versioned experimental policy; no default change from training-set accuracy.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Use distinct development/calibration/held-out data and report intervals, sample sizes, abstention and coverage.
- [ ] Keep SemIf null confidence null; measure consistency/skill shortlisting and field escalation without borrowed Jev thresholds.
- [ ] A default policy needs the protocol's per-skill held-out gate and a rollback setting.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_skill_policy.py backend/tests/test_routing.py -q
```



**Dependencies:** B27, B03.

**Likely files / ownership:** `backend/jet_browser/skill_policy.py`, `backend/jet_browser/routing.py`, `scripts/browser_lab.py`, `backend/tests/test_skill_policy.py`.

**Estimated scope:** Medium.

## B29: Measure focused context and chunking

**Outcome:** Find a faster bounded-context configuration without losing relevant candidates or task success.

**Progress:** Not started.

**Current truth:** Page controller already uses small tournaments; earlier failures showed missing limits and distracting context.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/candidates.py`, `scripts/browser_lab.py` (existing or proposed).

**In / Out:** Controlled state/pruning/hierarchy ablations only; no weight training.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Use identical cases and a frozen baseline; change one configuration at a time.
- [ ] Measure candidate recall, no-answer, candidate-order bias and independent whole-goal outcomes.
- [ ] Record all truncation and adapter limits; promote only from validation then untouched test evidence.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_candidate_ablations.py backend/tests/test_candidates.py -q
```



**Dependencies:** B02, B07, B28.

**Likely files / ownership:** `backend/jet_browser/candidates.py`, `scripts/browser_lab.py`, `backend/tests/fixtures/browser_lab/ablations.json`, `backend/tests/test_candidate_ablations.py`.

**Estimated scope:** Medium.

## B30: Measure batching and cache behavior

**Outcome:** Reduce repeated model work when it improves measured total task time.

**Progress:** Not started.

**Current truth:** Local adapters have different shared-prefix paths; one HTTP call does not prove one forward pass.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/decision_cache.py`, `backend/jev_ultrafast/local_models.py` (existing or proposed).

**In / Out:** Independent-question batching and bounded observation/decision caches; never speculative mutations.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Report actual forward calls, wall time, peak memory and task results against sequential/cache-off control.
- [ ] Cache keys include relevant goal, state, model/prompt and document identity; changes invalidate correctly.
- [ ] Cache failures cannot replay mutations, retain stale evidence or bypass Stop; same hardware ownership is serialized.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_decision_cache.py -q
```



**Dependencies:** B28, B29.

**Likely files / ownership:** `backend/jet_browser/decision_cache.py`, `backend/jev_ultrafast/local_models.py`, `scripts/browser_lab.py`, `backend/tests/test_decision_cache.py`.

**Estimated scope:** Medium.

## B31: Try bounded offline question tuning

**Outcome:** Determine whether clearer questions or learned features improve a recurring measured failure class.

**Progress:** Not started.

**Current truth:** No training/fine-tuning is justified by the existing small diagnostic set.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `scripts/tune_lab_questions.py`, `tasks/browser-lab-tuning.md` (existing or proposed).

**In / Out:** Budgeted development-only prompt/feature proposals; weights unchanged and no self-declared promotion.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Select a documented error family and fixed data budget; preserve original and proposed prompts/features.
- [ ] Never expose held-out labels to search; retire any evaluation examples used for tuning.
- [ ] Retain the winning candidate only after calibration and a new untouched evaluation; failures remain in the report.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_tuning_protocol.py -q
```



**Dependencies:** B28, B29.

**Likely files / ownership:** `scripts/tune_lab_questions.py`, `tasks/browser-lab-tuning.md`, `backend/tests/test_tuning_protocol.py`.

**Estimated scope:** Small.

## B32: Compare results and graduate selected skills

**Outcome:** See honest model comparisons and enable only capabilities that passed their own gate.

**Progress:** Not started.

**Current truth:** Current metrics/trace UI does not distinguish all-scope, supported-only and hybrid benchmark outcomes.

**Pins:** Shared baseline above; no new result or source revision claimed.

**References:** Parent plan/catalog and `backend/jet_browser/lab.py`, `app/lib/lab_comparison.dart` (existing or proposed).

**In / Out:** Per-skill comparison view and experimental/default setting; no single misleading speed-only leaderboard.

**Anti-goals:** Shared constraints above; completing this child does not imply general browser reliability.

**Acceptance:**

- [ ] Show goal success, false completion, incorrect mutations, escalation, timing/cold state, costs and denominators.
- [ ] Unavailable/unsupported/failing runs remain visible; links open retained evidence/replay and exact versions.
- [ ] Default changes cite a qualifying report, preserve rollback, and leave unproven capabilities in Lab.

**Verification:** From project root, after adding this slice's tests:

```sh
uv run --project backend python -m pytest backend/tests/test_lab_report.py -q
```

Also run this slice's listed widget tests and the app suite/analyzer from `app/`.

**Dependencies:** B05, B21, B27, B28.

**Likely files / ownership:** `backend/jet_browser/lab.py`, `app/lib/lab_comparison.dart`, `app/lib/lab_panel.dart`, `app/test/lab_comparison_test.dart`, `backend/tests/test_lab_report.py`.

**Estimated scope:** Medium.
