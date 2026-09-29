# Verification


## 2026-09-28 evening checkpoint

Offline and local checks for commits `d35bdd8`..`checkpoint-2026-09-28b`:

- 369 backend tests with isolated Chromium headless shell 1228 (real-DOM, JavaScriptCore template runs, prefilled-input delivery faults); 62 app and 9 vendored-chat tests; ruff and `flutter analyze` clean.
- Clean worktree (no ignored files): `install_cef.sh` via `gh` (17 s), tampered and wrong-build sources rejected; lock-based engine setup reproduced all four verified environments exactly; release app build; full package; relocated minimal-PATH service health/state.
- Ad-hoc hardened-runtime signing of that bundle: `codesign --verify --deep --strict` passed; service, JetWorkflow, Grok `--version` and SemIf (MLX + torch) ran.
- `verify_portable_workflow.py --scenario template-local` on that bundle: 20 unique records, one review, 59 s ([evidence](evidence/template-local-20260928.json)).
- Tag calibration, SemIf 4B, synthetic held-out: micro F1 0.788 ([evidence](evidence/tagging-semif-20260928.json)).

Not run: any paid Grok turn, any native CEF window (pinned CEF, hardened runtime, prefilled form, hidden-tab endurance), Developer ID signing or notarization.

Later the same night, with the user's go-ahead:

- Paid Grok, `--scenario template`: passed ([evidence](evidence/grok-template-live-20260928.json)).
- Native app on the pinned vten CEF, isolated profile (port 9198): first-run setup verified the cloned weights, then the browser came online. Fresh form with SemIf passed (1.3 s). Prefilled form: LFM passed; SemIf was stopped by the delivery guard in 3/3 runs while the page reported `hidden` (window covered), and passed (1.7 s, `visible`) with the window in front. Fixes: the typing helper now starts for direct tasks (first native run failed without it), and Chromium no longer backgrounds a covered window.
- Developer ID signing (`scripts/sign_release.sh`, identity "Developer ID Application … (F2PY472TDT)"): `codesign --verify --deep --strict` passed; hardened runtime and secure timestamp on the app and on the bundled CPython. Gatekeeper: "rejected, Unnotarized Developer ID" (notarization skipped by the user). The signed app, launched in a second isolated profile (port 9208), initialized CEF and passed the SemIf fresh form and the SemIf prefilled form 2/2 while its window was 100% covered (window-stacking measurement), with every probe reporting `visible`. The unfixed build, likewise covered, had reported `hidden` and dropped the press 3/3.
- Real top-100 bookmark run (user signed in to X in the isolated profile, sample sharing on): Grok configured `tagged_feed` from the real request and 10 bookmarks were saved; the first review turn then ended because `list_tabs` was denied (fixed).

## Initial source baseline and handoff — 2026-09-28

**345 backend tests, 61 Flutter app tests and 9 vendored-chat tests passed.** Backend
Ruff and both Flutter analyzers are clean. The full backend run used Chromium
headless-shell build 1228 with temporary profiles and synthetic page responses;
there were no skips, paid model calls or user browser actions. See the
[sanitized check record](handoff-verification-20260928.json).

The handoff check found a task-state race: delayed worker progress could overwrite
a retained terminal result. A deterministic regression failed before the guard
and passed afterward. Three newer workflow test files also needed import/format
cleanup. The first DOM attempt using regular installed Chrome failed fixture
loading; the dedicated headless-shell run exercised those cases successfully.

The staged secret scan passes with a narrowly scoped exception for verified SHA256
source fingerprints in two provenance manifests. Guide links were checked. Raw
test logs are local-only under `/private/tmp/jet-handoff-*` and may expire.

No new native build/repackage/relaunch ran during this handoff. The existing app
bundle predates the late-progress guard; rebuild/package before validating that
change natively. Earlier native startup and real-provider evidence below are dated
checkpoints, not fresh validation of this commit. The latest real bookmark turn
[timed out in Grok before workflow creation](incidents/2026-09-28-grok-timeout.md).
The authoring timeout remains unresolved.

The sections below preserve historical results. [Handoff](HANDOFF.md) and
[remaining work](../tasks/remaining-work.md) describe current status.

## Feed collection repair — 2026-09-28

**242 backend tests (including 9 real Chromium DOM cases), 41 Flutter tests, Ruff and Flutter analyze pass.** Release built. Four Jet-native passes saved 35 unique X bookmark posts through 24 scrolls, including two Grok-driven resumes and a final direct UI-endpoint resume. The local loop totaled 42.26 seconds, median item inference 100.4 ms; complete Grok chat turns took about 50 seconds. No held-out accuracy or full-archive claim. See [failure audit and behavior](feed-collections.md) and [source-pinned results](feed-verification-20260928.json). The backend is running the changes; the existing native window was retained, so rebuilt UI labels load on its next restart.

The checkpoints below are historical.

## Website collections and chat — 2026-09-28

**215 backend tests and 40 Flutter app tests pass**. Backend Ruff and Flutter analyze are clean. The release app builds; the only build warning is the existing CEF helper-copy phase without declared outputs. The 9 vendored-chat tests are the unchanged prior baseline, not rerun in this slice.

The new tests exercise collection plan validation, scope, atomic storage, session isolation, pause/resume/Stop, restart recovery without navigation replay, model failure, authenticated tools/routes, safe exports, exact provider tool identities, stable turn grouping, a 100-step collapsed transcript, paginated results, narrow layout, heartbeat/control races, stale session isolation and mocked native-view visibility. The headless screenshot is `app/build/test-artifacts/collection-workspace.png`; it uses synthetic fixture content, not a live collection.

Actual local-weight diagnostics: LFM 8/20 expected matches (43.91 ms warm median), SemIf 18/20 (94.27 ms) on 20 synthetic classification cases. These are not held-out or browser-level accuracy. See [usage and limits](collections.md) and [per-case data](collection-model-diagnostic-20260928.json).

No desktop-control tool, live native browser action, provider planning conversation or app relaunch was used for this slice. Live acceptance of the new collection path remains pending. The historical Keychain state below is a retained checkpoint, not a statement that this implementation is currently waiting for a password.

## Earlier checkpoints


## Desktop UX and navigation goals — 2026-09-28

The current source passes **162 backend tests, 27 Flutter app tests and 9 vendored-chat tests**. Both Flutter analyzers, Ruff and snapshot JavaScript syntax checks are clean. The macOS release builds successfully (349.8 MB); the only build warning is the existing CEF helper-copy phase lacking declared outputs. Logs: `ui-navigation-backend-tests-final.log`, `ui-ux-app-tests-final.log`, `ui-ux-vten-tests.log`, `ui-ux-app-analyze-final.log`, `ui-ux-vten-analyze.log`, and `ui-ux-native-build-final.log` in `artifacts/`.

The shell adds resizable/collapsible chat, preserved drafts, editable examples, history search and current-turn progress. Native keyboard integration forwards Cmd+L/T/R from the key macOS window to the same Flutter commands. Fake-host tests cover layout, focus, duplicate dispatch, failed sends, busy/Stop, history and drafts. These tests do not substitute for actual CEF keyboard interaction.

Native navigation evidence is deliberately retained across iterations:

- `navigation-goals-native-20260928T053955Z.json`: **5/8**, exposing canonical channel aliases and premature completion before visible content.
- `navigation-goals-native-20260928T054945Z.json`: **8/8, zero Grok handoffs** after visible-content and alias fixes. Homepage times were 267–1,835 ms; channel 9,171 ms including cold model load, video 4,922 ms, playlist 2,770 ms and results 1,184 ms.
- `navigation-goals-native-20260928T060343281204Z-2e4883c8bc114306bcc44e1b4169bc30.json`: **7/8** on the rebuilt UI; a relevant Artemis video was incorrectly rejected by the local identity question. The harness stopped that Grok handoff and retained it as a failure.
- `intent-completion-native-20260928T054442Z.json`: **6/6 Wikipedia cases, zero Grok handoffs**, including explicit results, spelling variants, follow-up and alias navigation.

The revised subject question includes grounded subject and requested resource kind. A controlled actual-model comparison improved from 11/13 to 13/13 (`youtube-identity-development-probe.json`), rejecting unrelated pages and a fan channel. The reusable production-prompt replay passed **13/13** (`navigation-identity-semif-20260928T061254091167Z.json`). An earlier replay harness accidentally supplied an empty aligned title and passed 9/13; that harness failure is retained in `navigation-identity-semif-20260928T061141238845Z.json`. The corrected fixture preserves the real production state rather than weakening its alignment checks. These probes are development data, not held-out accuracy.

The final native relaunch is currently waiting at macOS's password-required Chromium Safe Storage Keychain dialog. The user was asked to approve it directly in macOS. Final native keyboard checks and a new navigation replay after the subject-question change remain pending that OS authentication; the previous 8/8 run must not be presented as validation of the final prompt. Profile encryption and Keychain settings were not changed.

The harness checks actual URL/title/heading independently of route status, retains partial failure evidence, stops only its own turn and yields on user takeover. `--help` and imports make no API or model calls. See [UI audit](ui-ux-audit.md) and [navigation contract](navigation-goals.md).

## Intent completion and broader local-first audit

At the preceding checkpoint, **117 backend tests passed**, Ruff was clean, and the snapshot JavaScript passed `node --check`. Root reran those checks after Grok implemented the reviewed fixes. That checkpoint had 21 app tests plus 9 package tests; it made no Flutter changes.

Two complete native regression runs passed all six cases with **zero Grok calls**. The latest run uses the final missing-article guard and wrong-article continuation changes. This is six cases repeated, not twelve independent tasks or a broad reliability estimate.

| Request | Actual endpoint | Latest elapsed |
|---|---|---:|
| Find Elon Musk's Wikipedia page | Elon Musk article | 11,949 ms, cold first turn |
| Show Wikipedia search results for Elon Musk | Actual results page, `fulltext=1` | 1,002 ms |
| go to elon musks wiki page | Followed observed result to Elon Musk article | 1,833 ms |
| go space x wiki page | SpaceX article | 983 ms |
| Same kind of page for Ada Lovelace | Ada Lovelace article | 989 ms |
| Article about Quantum physics | Canonical Quantum mechanics article | 820 ms |

Evidence: `artifacts/intent-completion-native.json` (final), `intent-completion-native-third.json` (preceding six passes; cold first turn 6,209 ms, warm 949–1,790 ms). Times include network, native bridge and polling overhead. Different cold totals must not be interpreted as model throughput. Exact checks and semantic assessments remain distinct in route evidence; alias acceptance does not become deterministic proof.

Retained failures: `intent-completion-native-first.json` and `intent-completion-native-second.json` each passed 4/6. They exposed destination/results confusion, the 16-option native limit, and overly broad verifier wording. `intent-completion-native-startup-failure.json` records a native tab-open HTTP409 before any case ran; original context was restored. A subsequent independent check began only after observing the browser state. No browser mutation is automatically retried by the controller.

Six focused real-SemIf prompt probes selected the observed Elon link and recognized the Quantum alias (`navigation-prompt-probe.json`). Eight further real-model edge probes passed: five intent/negation/topic-wording cases and three identity checks including unrelated topics (`navigation-outcome-edge-probe.json`). These use controlled state; the latter stubs query extraction and does not test the text helper or navigation. They are development evidence, not held-out accuracy.

The snapshot now exposes Wikipedia's structural missing-article indicator. Search completion rejects a missing article even when the title matches. Unknown article identity hands off; a known wrong article may continue through an observed link under the original budget. A read-only check of the actual open `/wiki/Elon_musks` page confirmed the native flag and `missing_article` result (`artifacts/intent-missing-article-native.json`). General page tasks still report `manual_check`; explicit URL navigation is not covered by the search checker.

The [deep local-first audit](local-first-agent-audit.md) reviews all 18 official Jev cookbooks and maps them to a proposed browser workflow catalog. A fresh read-only diagnostic ran 24 prompts on four local engines. SemIf agreed with 20/21 current-handler labels at 127.5 ms median warm routing; Laya MLX 17/21 at 9 ms, Laya Typed 15/21 at 10 ms, LFM 8/21 at 47 ms. Three explicitly documented cases concern ambiguous or future capability labels; all original 24 results remain unchanged. These are handler agreements, not completed browser tasks. No hosted Jev evaluation was run. See `local-first-routing-audit.json`, its `-analysis.json`, and `jev-source-audit.json`.

Re-score without inference:

```sh
backend/.venv/bin/python scripts/audit_local_routing.py --score artifacts/local-first-routing-audit.json
```


The reusable native regression harness is `scripts/check_navigation_intent.py --run`; it uses a temporary conversation/tab, retains timestamped results, and restores context only while it still owns it. Its `--help` makes no API calls. Run it while the app is idle.

## Current local-first chat, history and tracing

The actual vendored vten chat release is built and running. The completed tracing baseline had **101 backend tests passing** and clean Ruff. The reviewed chat fork has **21 app tests and 9 package tests passing**, both analyzers clean, and a successful 349.7 MB release build (`artifacts/native-build-vten-direct-port.log`; all commands retain EXIT:0 in `artifacts/review-fix-*.log`). Backend checks include native command correlation across separate async requests, authenticated session-scoped trace reads, cancellation/late-provider fencing, preserved error status, log rotation/redaction, and disk failures that do not replace task results. Stop cancels queued navigation but permits the release/remaining input of a local action whose first input was already acknowledged; a real thread/queue regression test covers that distinction.

The presentation is now an independent local fork at `vendor/vten_chat`, not only a visual approximation. Ten retained files match their source hashes; adapted components bind to Jet's host. Review fixes cover stable turn keys, stale session-scroll callbacks, focus listeners, IME composition, source-style pinned-prompt geometry/tap behavior, disconnected status and bounded mutually exclusive inspectors at 390×500. Root reopened the release and inspected the actual transcript, history, model settings, diagnostics and Markdown navigation; the 25-message conversation restored. See `artifacts/vten-chat-source-check.json` and `artifacts/vten-chat-native-review.json`. Keyboard/IME behavior is widget-tested; a physical IME was not exercised.

Actual native chat checks all passed with zero Grok calls (`artifacts/local-chat-1790290848419182000.json`):

| Request | Observed result | Wall time |
|---|---|---:|
| Find Elon Musk's Wikipedia page | Elon Musk article | 7,390 ms, cold router |
| Follow-up: same kind of page for Ada Lovelace | Ada Lovelace article | 858 ms |
| Go back | Elon Musk article | 378 ms |
| Go forward | Ada Lovelace article | 358 ms |
| Show open tabs | Actual observed tabs | 258 ms |

These are single native integration checks, including polling overhead, not a statistically controlled benchmark. The first route spent 5,772 ms in cold classification. Current request ordering was corrected after an earlier Back request repeated the preceding search; the failed artifact remains retained.

The router is a dedicated SemIf 4B process; LFM remains the default page-action model. The earlier 19-case development set scored 19/19 for SemIf versus 12/19 Laya and 13/19 Laya Typed. A later 32-case replay selected the correct local/Grok handler on 31 cases (`artifacts/router-final-replay-1790290668391736000.json`). Bare assent (“Yes, do it”) was the remaining failure; a bounded guard now sends such requests to Grok's full conversation context, with a regression test. This adjusted suite is not fresh held-out evidence of general accuracy.

The user's real “go space x wiki page” turn provided a live failure-and-recovery trace. The tiny helper initially extracted the whole phrase; LFM then failed to generate a field value. Grok received the partial result, opened the SpaceX article and confirmed the page. Its 245-event trace contained nine acknowledged native commands, three allowed finite MCP tool permissions, model/helper timing, and four error events. All nested events share one trace ID. Evidence: `artifacts/user-spacex-trace.json`. This is an observed fallback success, not a successful local-only lookup.

Query extraction now includes short navigation examples and recovers separator changes only from a verbatim user substring (e.g. `python-docs` → the user's `Python docs`). Five helper checks passed after that adjustment, including `go space x wiki page` → `space x` in 196 ms. Evidence preserves the initial Python-docs rejection and subsequent correction (`artifacts/query-extraction-tracing-fix.json`). At that earlier checkpoint the complete route was not rerun while the user was interacting. The current six-case navigation suite above now verifies SpaceX locally.

Saved message IDs survived a real service restart. A fresh isolated Grok ACP process then received the actual selected-session context and correctly recalled **Elon Musk, Ada Lovelace and the current SpaceX page** in 4,453 ms, without modifying the app conversation or navigating (`artifacts/isolated-grok-memory-check.json`). Local-to-Grok history, bounded retrieval, session isolation and stale task continuation are also covered by backend tests.

Read-only CUA visual inspection confirmed the real SpaceX recovery in the final app: compact vten-style user cards, assistant Markdown/copy actions, collapsed tool rows, composer/footer and the activity summary “120 of 245 events · 36.51 s”, with four errors visible. The screenshot was emitted inline by the computer-use tool; it did not expose a documented file-save API. Expanded trace loading/copying, stale-session response rejection, scroll preservation and Latest are widget-tested. See [chat UI source parallels](chat-interface.md).

The actual JSONL journal was checked for owner-only permissions, absent control token/prompts/form values/browser scripts, and zero logging failures. The native browser remained online and idle (`artifacts/trace-runtime-audit.json`). Diagnostics now retain metadata rather than raw page/input snapshots. Older task recordings below remain historical private evidence. See [tracing contract and runbook](tracing.md).

## Earlier native form baseline — 2026-09-23

In the preceding build, a real user request completed Grok → local LFM → native form → Markdown result. No source project was changed.

## Earlier UI and automated checks

- Flutter analysis is clean; all 10 app tests pass. Tests cover native dispatch preservation, single composer/model settings, Markdown and dark-theme contrast.
- Release build succeeded: `artifacts/native-build-dark-markdown.log`.
- The actual app was visually inspected with the dark theme, 15px chat text, wider sidebar, Markdown bullets/bold/links, and completed local task card: `artifacts/native-shell-dark-markdown.png`.
- All 35 backend tests pass; Ruff is clean. Stop during Grok startup was reproduced as a failing regression and fixed. Unit tests use no paid provider calls.

## Real Grok handoff in the final build

The user submitted “Help me fill this form” in the app. Grok discovered the exact tab, read its form, delegated the printed practice values through `browser__run_task`, and returned a formatted result in the same conversation.

Task `333b9ddedc4b4a6981b787dcfcadfb71` used LFM RLCD 350M and the local Qwen 0.8B typing helper. It performed five browser actions, four native model inference requests and two typing calls in **4,244 ms**, including **3,447 ms** model load/initial observation. These times cover the local browser task, not the full Grok conversation.

A separate checker verified the actual captured browser result: Registration preview; team Solstice; email ash@example.test; session Afternoon; updates true. This check reads the retained DOM observation, not Grok's prose or the model's DONE choice. Evidence: `artifacts/grok-user-handoff-verification.json`, `artifacts/native-user-chat-observed.json`, and `.runtime/tasks/333b9ddedc4b4a6981b787dcfcadfb71.json`.

UI QA reloaded the fixture after that completed run, so the screenshot shows the reset form beside its prior result. The user then began another request. Further automated navigation and service restarts were stopped to leave that live session under their control. The additional scripted paid handoff was not needed and was not run.

## All four local engines: native fresh-form checks

The input bridge below is the same implementation used by the final dark build. Each row independently passed checks of the actual final page values. Evidence: `artifacts/native-check-1790209217964486000.json`.

| Model | Task elapsed, ms | Load/initial observation, ms | Actions | Model inference requests | Typing calls |
|---|---:|---:|---:|---:|---:|
| LFM RLCD 350M | 2,421 | 2 (warm) | 5 | 4 | 2 |
| Laya MLX 421M | 1,015 | 497 | 5 | 4 | 2 |
| Laya Typed 421M | 751 | 290 | 5 | 4 | 2 |
| SemIf / Qwen3.5 4B | 8,409 | 7,472 | 5 | 4 | 2 |

These are single integration checks with different warm states, not an overall leaderboard or intrinsic model-throughput benchmark. Read-only input diagnostics were enabled and add bridge work.

## Retained failures and remaining work

- OSR-only text entry silently did nothing in CEF native-view mode. Fixed by acknowledged in-process Chromium input, with only mouse, key and insert-text methods allowed. A later AppKit focus approach regressed clicks; the current bridge preserves the Chromium input protocol directly.
- A later prefilled-form check still blocked at the checkbox before reaching text replacement: `artifacts/native-check-1790209273176527000.json`. Acknowledgements arrived but the observed checkbox did not change. This intermittent native-input case remains unresolved; successful fresh-form runs do not establish replacement reliability. No claim is made that this check passed. Follow-up 2026-09-28: that run's input diagnostics show the document focused but `activeElement` still BODY after every press, so the press never reached the checkbox. The executor now refuses to press until a pointer move lands on the target, and to type until the field has focus, raising `InputNotDelivered` with delivery diagnostics (`backend/tests/test_prefilled_input.py`). The native root cause is not yet observed.
- Initial Laya launches failed because nested encoder/tokenizer files were missing. Complete independent checkpoints were then copied; subsequent native checks passed.
- SemIf initially reached the preview but selected Edit and looped. The fixture incorrectly retained the original main heading/title after submission. Its heading/title now identify Registration preview. This is a semantic correction to the owned demo page, not model training; the old blocked run remains retained.
- One secure-profile app restart was delayed by macOS Keychain, then recovered without changing security settings. `artifacts/native-restart-sample.txt` retains the diagnosis.
- Broader websites, cross-origin frames, complex editors and long workflows remain future validation. Models are bounded local decision tools; their DONE output alone does not verify a custom task.
- The review tour validates with zero errors and one expected warning: the new repository has no base commit because no commit was requested. It contains the full worktree patch and provenance.

## Reproduce

Fresh native forms (local models only):

```sh
backend/.venv/bin/python scripts/check_live_models.py
backend/.venv/bin/python scripts/check_live_models.py --models lfm_rlcd --replacement
```

Full chat integration (makes a real Grok provider call through the installed login):

```sh
backend/.venv/bin/python scripts/check_chat_handoff.py
```

Run these when no user chat/task is active: they navigate the active tab to the owned practice page. Older retained task recordings contain actual test instructions/values; new diagnostic files omit content. Conversation history still retains actual task goals/results privately.

Eight actual SemIf routing probes also selected the expected local/Grok lane: four collection requests went to Grok planning; YouTube, Back, tab listing and Wikipedia remained local. No browser action or provider call was executed. [Per-case routing results](collection-route-diagnostic-20260928.json).


## Background jobs and workspace — 2026-09-28

267 backend tests (11 isolated real Chromium DOM cases), 46 Flutter tests, clean Ruff/analyzer, 349.9 MB macOS release. One real SemIf + Chromium run saved 15 unique synthetic posts over 14 scrolls in 10.07 seconds with two local progress decisions and no Grok calls. Real Grok ACP created a scratch note and HTML artifact; the artifact rendered in Jet. The original 50-post collection remains preserved. [Source-pinned evidence and model caveats](background-job-verification-20260928.json).

## Supervised collection review — 2026-09-28

284 backend tests (13 real Chromium cases), 50 Flutter tests, lint/analyze and release build passed. Real Grok ACP reviewed the existing 1,102-item collection, separated uncertainty from incomplete capture, and paused for user input. No records were relabeled or discarded. Native browser reconnected. Details: [supervised collections](supervised-collections.md) and [evidence](supervision-verification-20260928.json).

## Tab-bound collection execution and post recovery — 2026-09-28

310 backend tests passed with isolated real Chromium enabled; 56 Flutter tests, Ruff, Flutter analysis and the final macOS release build passed. The bundled native JavaScriptCore helper ran directly with only system PATH entries. Tab status widgets were rendered and inspected at 320/1024 pixels; layout checks also covered 768/1440. Source hashes and precise limits: [verification record](tab-bound-verification-20260928.json).

The live collection remains paused with 50 saved posts. The open native app and sidecar were not restarted; new background CEF behavior is built but not live-account verified. The top-100 task, production Grok workflow authoring and self-contained distribution remain unfinished. [Current contracts and next work](tab-bound-jobs.md).
