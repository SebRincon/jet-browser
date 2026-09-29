# Jet Browser remaining work

Updated 2026-09-28. Owner: standalone Jet browser-agent experience. Charter: [SPEC](../docs/SPEC.md). Active [plan](plan.md). This index includes the first implemented collection slice; see [collections](../docs/collections.md) for its evidence and limits.

## Current truth

- 2026-09-28 evening checkpoint (`checkpoint-2026-09-28b`): Grok stall watchdog and saved-state reports, `tagged_feed` template with local slice continuation, pinned vten CEF, locked engines, release signing, >15-tab selection, native input delivery guard, tag calibration baseline. Checks: 369 backend, 62 app and 9 vendored-chat tests passed; lint/analyzers clean. Live paid-Grok and native UI confirmations are pending user go-ahead; see [handoff](../docs/HANDOFF.md).

- Implemented foundations: standalone CEF shell, local shadcn/vten chat forks, one chat, Grok ACP, local adapters, durable sessions, private traces, Stop fences, navigation goals and Wikipedia/YouTube checks.
- Partial: general form DONE remains `manual_check`; the prefilled-input failure is guarded offline (no press or typing unless pointer and focus reach the target) but its native cause is unconfirmed. Packaged native startup, DOM read and chat hide/restore now pass after the accessibility repair; background endurance is still open.
- Open: shared bounded selection for links/page actions (tabs done), shared outcomes, extraction/find, structured references, GitHub resources, saved forms/filters, cited research, replay and held-out calibration.
- [Baseline](browser-lab-baseline.json): selected source hashes and reference pins, unborn checkout, no new benchmark run. Board search found no matching Jet issue or local mapping; children are [local work items](browser-lab-work-items.md).

## Current user priority

Clean, simple single chat based on the [Orca/T3 source audit](../docs/chat-and-hybrid-loops.md), plus bounded Grok-to-local website/bookmark collection loops. [U01–U03/H01–H08](chat-loop-work-items.md) add 11 planned children, bringing the queue to 45. Stable chat projection, scoped website collection and bounded X Bookmarks/feed collection are implemented. Feed native execution, Grok resume, direct UI-endpoint resume and duplicate-free persistence have live evidence; broad coverage and label accuracy remain open.

## Next smallest deliverable

**First (done 2026-09-28): confirm the repaired Grok authoring path live** — the paid synthetic rerun passed.**Next: the real top-100 archive run and native UI checks.** The watchdog, saved-state failure report, `tagged_feed` template and local slice continuation are implemented and tested offline. A user-authorized, isolated rerun of the top-100 bookmark request must confirm Grok selects the template and the run completes. See [incident](../docs/incidents/2026-09-28-grok-timeout.md) and [templates](../docs/portable-workflows.md#built-in-templates).

**Then: held-out categorization, account identity/cursor recovery and wider feed compatibility.** The initial bookmark adapter, per-post chunking and four bounded native passes are complete; see [feed audit](../docs/feed-collections.md). Broader lab foundation continues as **B01 → B02 → B03 → B04 → B05 → B06:** resettable fixtures, bounded choices, shared outcomes, independent runner, one watched task and exact-value extraction. Preserve navigation and Stop. B33–B34 isolate service/runtime and browser profile before native Watch. Offline replay can proceed independently. No desktop takeover.

## Ordered queue

| Work | State | Completion dependency |
|---|---|---|
| Grok authoring reliability | Done: live paid rerun of the incident-shaped request passed 2026-09-28 (template saved at 31 s, 20/20 records) | Real top-100 archive run (user-started, isolated) |
| U01 chat projection | Implemented; offline tests | Stable turn IDs and collapsed completed steps |
| H01–H06/H08, U02–U03 website loop | First slice implemented; feed loop has native/resume evidence, wider acceptance pending | Bounded plans/store/local classifier/runner/MCP/results; further child acceptance remains |
| Tag calibration | Baseline measured 2026-09-28 on synthetic held-out tags (SemIf micro F1 0.788; threshold gave no gain) | Improve design/research recall on development, then score a new held-out set; real-archive spot checks with user permission |
| H07 bookmark source | Initial adapter implemented and live-tested; partial broader acceptance | Account-switch identity, deleted/rate-limited sources and durable remote-cursor recovery remain |
| B01–B05 plus B33–B34 experiment foundation | Not started | Honest outcomes and isolation |
| B06–B10 extraction, find, evidence, GitHub, references | Not started | Foundation |
| B11–B15 forms, saved flows, filters | Not started; B11 is an existing issue | Actual input fixed before promotion |
| B16–B19 ranking, scout, research, citations | Not started | Stable evidence records |
| B20–B26 QA, replay, video, voice, focus, WebMCP, controls | Not started | Feature-specific gates; unsupported is valid |
| B27–B32 cookbook coverage, calibration, tuning, comparison | Not started | Frozen corpora and relevant skills |

## Earlier work retained

Claude Code/Codex providers remain later work. Self-contained local packaging and in-app model setup are implemented. Reproducible inputs landed 2026-09-28: pinned vten CEF install/check, hash-locked engines, and Grok/CEF pin checks in the packager. A clean worktree built, packaged and started the relocated service headlessly with them. `scripts/sign_release.sh` signs with the hardened runtime (ad-hoc structure check passed, including service, JetWorkflow, Grok and engine loads). Native UI acceptance on the pinned CEF and under the hardened runtime, the first Developer ID signature/notarization, and clean-account native acceptance remain open. See [portable workflows](../docs/portable-workflows.md). Frames/complex controls become a bounded experiment in B26, not an assumed capability. Historical completed checklists stay in [todo.md](todo.md).

## Closing work

Attach relevant tests, source/model/prompt/fixture versions, run artifacts and limitations. Keep failures. Native success requires an independently observed outcome; semantic agreement is not deterministic verification. Future live runs must be user-started and isolated in Jet. Offline passing tests do not establish native behavior.


## Long jobs, quiet chat and workspace — 2026-09-28

- [x] Continuous feed limits and same-collection resume reconfiguration.
- [x] Local progress reviews with source/Stop fences and loading-state rechecks.
- [x] Background-safe chat with exclusive browser ownership.
- [x] Private conversation scratch/artifacts, finite tools, sandboxed browser previews.
- [x] Compact live job card and expandable intermediate narration.
- [x] Real SemIf + Chromium loop and real Grok artifact acceptance; isolated UI/regression tests.
- [ ] Held-out progress calibration for 350M LFM / Laya; larger archive endurance and explicit cursor recovery.

Current contracts and evidence: [background jobs](../docs/background-jobs-and-workspace.md).

## Agent-supervised loops — implemented 2026-09-28

First-ten and periodic review, bounded authorized samples, taxonomy/field changes and compact review UI are implemented. A prior 1,102-post run reached a real Grok checkpoint; this is historical evidence, not current process state. Recovery/reclassification subsequently landed in the tab-bound slice below. Taxonomy calibration and large-feed endurance remain. See [supervised collections](../docs/supervised-collections.md).

## Current follow-up: tab-bound work and portable workflows

- [x] Background collection DOM execution with exact-tab claims and revocation fences.
- [x] Tab status badge, time/counts and Pause/Stop/Details controls.
- [x] Exact-post recovery, guarded Show more, local reclassification and audited replacement.
- [x] Native JavaScriptCore helper, bounded parent RPC and release-bundle integration.
- [x] Activate the packaged native host/sidecar in an isolated profile; startup, DOM read and chat hide/restore passed.
- [ ] Verify sustained hidden-tab CEF execution with independent native outcome checks.
- [ ] Resume the paused 50-post collection only when requested; top-100 organization is unfinished.
- [x] Versioned Grok-authored workflows, correction capabilities, native overlapping tags/local summaries and automatic checkpoint repair; actual Grok revised and completed a synthetic workflow.
- [x] Self-contained controller/model/Grok/JavaScript runtime and first-run downloads; relocated minimal-PATH service and real model inference passed.
- [ ] Clean-account native browser acceptance and public distribution signing. Packaged native startup, DOM reads and chat hide/restore now pass after the semantics lifecycle repair; background endurance remains open.

Current contracts, evidence and implementation order: [tab-bound jobs](../docs/tab-bound-jobs.md).
