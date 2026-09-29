# Jet Browser: browser experiments and app integration

> **Handoff update 2026-09-28:** This is the historical plan. The initial source baseline is now committed; current status and priority are in [handoff](../docs/HANDOFF.md) and [remaining work](remaining-work.md). Native startup passed after the semantics repair; the new blocker is Grok workflow-authoring timeout.

> **Implementation update 2026-09-28:** The first website collection and chat slice is now implemented. See [current behavior and evidence](../docs/collections.md). The bounded feed/bookmark adapter now has native execution and Grok-resume evidence; see [feed audit](../docs/feed-collections.md). Broader lab coverage, account identity and held-out accuracy remain open. The design below includes future work.

Planning date: 2026-09-28. Status: **planned, not implemented or benchmarked by this planning pass**. This replaces the original extraction sequence; its completion history remains in [todo.md](todo.md).

> **Scope update (2026-09-28):** The browser product now prioritizes a clean Orca/T3-inspired single chat and Grok-directed local collection loops. See the [source audit and design](../docs/chat-and-hybrid-loops.md) and [11 additional children](chat-loop-work-items.md). The Browser Lab supports this product; it is not the default home screen. Total plan: 45 tasks, 22 demo families, 18 cookbook patterns. No new capabilities are claimed as implemented.

## Outcome

Make Jet useful through one vten-style chat: find information, collect cited research, reach the intended resource, complete bounded forms and filters, and reuse successful workflows. Include a Browser Lab where the user watches real runs and compares models on the same task. Try broadly; promote capabilities individually when evidence supports them.

The user can ask for scoped website research or categorized bookmark collections; Grok prepares bounded plans while local models perform repeated decisions. The lab is a gallery and run inspector inside Jet, not another chat interface. Keep the existing Flutter shell, local shadcn/vten chat forks, private CEF bridge, Grok ACP adapter, and local runtimes.

## Current truth and pins

- No first commit exists, so there is no HEAD SHA. The [baseline manifest](browser-lab-baseline.json) fingerprints selected source files and pins public reference revisions. App version: `0.1.0+1`. This is not a binary-build fingerprint.
- Typed navigation and Wikipedia/YouTube checks exist. General `TaskManager` completion still says `manual_check`. The prefilled-form issue remains open. `routing.py` still submits up to 24 tabs plus an escape to a bounded selector.
- The [earlier audit](../docs/local-first-agent-audit.md) and [verification history](../docs/VERIFICATION.md) are development evidence. The final Keychain/native-check note needs reconciliation with retained artifacts when native verification resumes; it does not establish current completion.
- Plane search for “Jet Browser” found no matching work items; no project/module mapping was found here. Child specifications are local in [browser-lab-work-items.md](browser-lab-work-items.md). No unrelated board was changed.
- The user stopped desktop takeover. Do not drive the active browser, use Orca/CUA/global input, or relaunch the app during this plan. Future native lab runs are explicitly user-started and app-owned; offline tests do not substitute for them.

## What to extract

Adapt small contracts, questions, fixtures, and presentation patterns to Jet's observed-handle bridge. Do not introduce a second Playwright/CDP/browser stack or independent chat/agent loop.

| Reference | Adaptation | Jet destination |
|---|---|---|
| [Orca](https://github.com/stablyai/orca), [T3 Code](https://github.com/pingdotgg/t3code) | Compact tool groups, structured composer state, stable scroll and expandable plans | Flutter/vten interaction patterns; pinned implementation audit |
| [FastBrowse](https://github.com/agent-labs-dev/fastbrowse) | Requirement-linked quotes, outcomes, progress events | Evidence records, research cards, replay |
| [Ying-Kai-Liao/jev-browser](https://github.com/Ying-Kai-Liao/jev-browser) | Bounded step outcomes and candidate text | Goal contracts, forms and saved flows |
| [JevScout](https://github.com/hqman/JevScout), [Sift](https://github.com/tylergibbs1/sift) | Relevance judgments over links/results | Scout and ranked search skills |
| [Jev Voice Browser](https://github.com/moritzkremb/jev-voice-browser) | Recent-action references and complete utterances | Shared chat history and optional voice input |
| [TypeSafe Adblock](https://github.com/realZachi/typesafe-adblock) | Candidate block classification | Reversible focus mode, highlight first |
| [Jev QA](https://github.com/divyekant/jev-qa), [JevTest](https://github.com/CorieW/JevTest) | Acceptance journeys, defects and failure replay | Owned fixtures and independent oracles |
| [Jev WebMCP](https://github.com/jangya/jev-webmcp) | Selecting site-declared tools | Compatibility experiment, later opt-in skill |
| [Jev Ultrafast](https://github.com/browser-use/jev-ultrafast) | Existing observed-action lineage | Extend current extraction and provenance |
| [Official index](https://docs.typesafe.ai/llms.txt) | All 18 cookbook decision patterns | Experiments in the same harness |

Before copying code, inspect the pinned license, preserve notices, and record source/destination hashes and adaptations. The registry is reference-only today. JevTest is design inspiration only while its license is unspecified: do not copy its code or fixtures. JevScout and Jev QA also have unresolved license metadata; treat their code/fixtures as inspiration-only until the pinned license texts establish reuse rights. Check every other license at the pinned revision too. Upstream results never become Jet scores.

## Execution design

1. Code parses exact URLs and supplied values. A registered skill defines inputs, finite actions, budget and completion predicates.
2. The router selects a skill, asks for a missing value, or hands reasoning to Grok. Grok may plan novel compound requests into registered steps; code validates that plan.
3. A small model chooses observed candidates. Adapter-specific limits, section-then-span selection, and no-match escapes keep context bounded.
4. Code checks Stop and tab/document identity, executes one action, reobserves, then checks the requested result. An unknown outcome after dispatch does not trigger a mutation retry.
5. Grok receives original requirements, collected evidence and the unresolved question when synthesis or repair is needed. Its calls remain visible and count toward hybrid performance.

Proposed code-owned records: `Goal` (request, skill, constraints, source-backed slots, target binding, stop point, budget); `Outcome` (status, unmet predicates, evidence, checker kind); `Evidence` (quote/value, URL, document/span identity, time, requirement ID); `StepEvent` (run/turn/step identity, model/prompt revision, operation, observed target, timing, result). Models choose typed options rather than generating arbitrary plans, selectors or scripts. Existing JSON transport is not a JSON-generation benchmark.

Distinguish reached, continue, need observation, need input, need reasoning, unsupported, stopped, budget exhausted, and unknown after action. Deterministic checks and model assessments remain separate; DONE is not its own ground truth.

## Order and checkpoints

| Phase | Work items | User-visible result | Exit evidence |
|---|---|---|---|
| UI increment | U01 | Clean turn grouping using existing events | Stable keys, compact activity, preserved drafts/scroll |
| 0. Foundation | B01–B05, B33–B34 | One real watched navigation task, honest status and Stop | Ownership, independent oracle, candidate-limit and event tests |
| 1. Read and find | B06–B10 | Exact values, semantic find, source cards, GitHub resources, follow-ups | Pilot cases, absent answers, stale evidence rejection |
| 2. Reusable actions | B11–B15 | Prefilled forms, saved flows, filters and dates | Actual field values, pre-submit stop, preserved constraints |
| Hybrid collections | H01–H08, U02–U03 | Scoped website and bookmark organization with durable progress | Discovery/classification/recovery oracles; partial completion is honest |
| 3. Research | B16–B19 | Ranked results, scouting, collections and citations | Source-backed fields, missing/conflicting evidence, coded arithmetic |
| 4. Demo expansion | B20–B26 | Website QA, replay/video, voice, focus, compatibility experiments | Defect detection, faithful replay and restoration |
| 5. Tune and graduate | B27–B32 | Cookbook comparisons and per-skill model policy | Held-out results, ablations, promotion checks |

Each phase leaves a working slice. B21 replay can follow B05/B08 before later research work; capture events from the first slice. New capabilities remain experimental until their own gate passes. B33–B34 isolate the currently hardcoded runtime, service port and CEF profile before native demos. Offline replay can proceed first. U01 can improve the chat immediately using current event types. The first browser feature slice is **B01–B06**, with B33–B34 required for its native Watch path, ending with exact-value extraction that is visible and measurable. Detailed tasks specify dependencies rather than requiring unrelated phases to finish first.

## Scope and UI

[Experiment catalog](../docs/browser-lab-experiments.md): **22 demo families and 18 cookbook adaptations**. [Benchmark protocol](../docs/browser-lab-benchmark.md): 60 development decisions plus 12 interactive pilot cases, then 440 labeled cases across the catalog, followed by additional per-skill acceptance samples before default promotion.

Primary comparison: hosted Jev, LFM RLCD 350M, SemIf/Qwen 4B. Extended: Laya MLX and Laya Typed 421M, labeled as adapters of one family. Fix the typing helper for comparisons. Separate executor comparisons with a fixed router from complete chat runs; a SemIf-routed system is not 350M-only. No generative JSON baseline.

- Keep one composer and the existing vten transcript. Tasks, source cards and Grok responses share that conversation.
- Lab offers Run, Watch, Replay and Compare. Watch reflects actual page state; replay is visibly recorded. No simulated typing or synthetic progress.
- Compact progress shows the requested outcome, current step and Stop. Expand details for model/helper/queue/page timings and evidence.
- Source cards reopen/highlight captured spans when still present; changed content is labeled rather than silently substituted.
- Cover dark contrast, keyboard access, narrow layouts and draft/scroll/history preservation in widget tests.

## Implementation and verification

Follow the user's Grok preference for product implementation through Grok Build CLI; review and tests remain independent. Shared contract edits and live inference are serialized. This plan does not require extra agents or a new service.

Existing offline commands from the project root:

```sh
uv run --project backend python -m pytest backend/tests -q
uv run --project backend ruff check backend/jet_browser backend/tests
```

From `app/`: `flutter analyze`, `flutter test`, and `flutter build macos --release` after native changes. From `vendor/vten_chat/`: `flutter analyze` and `flutter test` when that package changes. Future lab commands in the benchmark document are explicitly unimplemented proposals.

Preserve authentication, cancellation fences, profile isolation and no mutation retries. Keep diagnostics metadata-only; richer experiment captures need a separate private store, redaction and retention. Page content cannot grant permissions. Leave vten and original experiments unchanged. No commit/push/publish is included.

Completion means every experiment is tested, unsupported, or deferred with evidence; accepted features work in the one chat; failures are inspectable; model choices have per-skill results. Trying an experiment does not require shipping it. See [remaining work](remaining-work.md) for the queue.
