# Browser Lab benchmark and promotion protocol

2026-09-28. Proposed protocol; no new results claimed. Parent [plan](../tasks/plan.md), [catalog](browser-lab-experiments.md), [work items](../tasks/browser-lab-work-items.md).

## Comparison tracks

1. **Decision replay:** identical frozen request, relevant history, candidates and page state. Scores routing, target/span selection, no-answer and outcome judgments. No browser control or providers in fake-unit tests; real inference is an explicit separate mode.
2. **Owned browser task:** fresh fixture state for each attempt; fixed routing/helper configuration; vary the action model. Score actual goal completion with an independently authored oracle, not the controller's outcome checker or DONE label. A Playwright fixture smoke test cannot count as CEF task success.
3. **Complete chat:** include routing, helper, local work, any Grok handoff, page loading and final evidence. Separate local-only success from hybrid success and unsupported capability. Preserve original compound requirements.
4. **Live public smoke:** user-started isolated native runs for Wikipedia, YouTube, GitHub and similar read-only pages. Report live failures separately from deterministic fixture results. Never use the user's active tabs/session or OS-wide automation.

Default leaderboard arms: hosted Jev, LFM RLCD 350M, SemIf/Qwen 4B. Extended arms: Laya MLX and Laya Typed 421M. Their adapter/context differences are explicit; they are not two independent model families. Existing code-only actions provide a no-inference control. The existing Jet configuration is the system baseline. No generative JSON arm. Grok is a counted planner/helper in hybrid runs, not an invisible replacement for a failing small model.

Hosted Jev needs an explicit supported harness adapter; it currently exists upstream in the runtime registry but is excluded from Jet's local task/MCP lists. Do not label the existing UI as already supporting hosted Jev tasks. Model/provider versions must be resolved and pinned rather than benchmarking `jev-latest` silently. Missing providers produce unavailable results, not a substituted model.

## Corpus and run budget

| Stage | Data | Execution |
|---|---|---|
| Pilot | 60 authored development decisions: D01–D06 × 10; 12 interactive cases: two per family | Core three arms first; local Laya variants after runner sanity; one cold-start sample and three warm repetitions where supported |
| Broad exploration | 440 unique cases: 22 demo families × 20; 10 development, 5 calibration, 5 held-out per family | First run replay; run native tasks only for implemented capabilities. Keep unsupported counts in all-scope report |
| Feature promotion | Additional untouched variants until a candidate default skill has at least 60 unique held-out goal cases | More than one template/site/entity family, including negative/ambiguous inputs; repeat selected timing cases without inflating sample size |
| Live smoke | Small named read-only site list | User-started; separate from fixture leaderboard; retain network/consent/login failures |

The 22 demonstration prompts are development data. Existing 24 routing probes and prior live navigation tasks are also development data. Split by template, site, entity and source document; paraphrases of the same fixture do not cross partitions. Authors label gold outcomes before running models. Prompt tuning uses development; acceptance thresholds use calibration; frozen held-out cases are opened only for evaluation. If failures inform tuning, retire that held-out set to development and add new unseen cases.

The 440 cases cover the catalog, not 400 identical kinds of model decisions. Mark UI-only/replay cases (especially D15) `no_model` and run them once as product acceptance checks, outside model-accuracy denominators. For mixed families, record which layer each case tests. Compare model arms only on the same applicable case IDs; code-only behavior is a separately labeled control, never free model successes.

Five held-out cases per family in the broad survey cannot justify a production default; the promotion sample is additional. Report confidence intervals and sample sizes. Zero failures in 60 trials still gives an approximately 4.9% one-sided 95% upper bound on the failure rate under independent-trial assumptions; correlated templates weaken that interpretation. No guarantee is inferred.

Proposed resource ceilings: pilot hosted spend at most USD 5 and expanded batch at most USD 25, including known helper/Grok spend; 24 actions/90 seconds per ordinary task, separately declared longer research limits. Stop scheduling new calls before the remaining allowance cannot cover a request. If provider cost cannot be estimated, use a conservative token/request cap and mark actual cost unknown. These are proposed ceilings, not spending performed or new permission requirements. Run serially on local hardware; block the benchmark from displacing an active user's inference. A budget stop is an outcome, not a discarded run.

## Case and artifact contract

Case: `case_id`, family, split, fixture/template version, initial state, user request, scoped history, expected facts/final predicates, prohibited transitions, allowed tools, oracle ID, timeout/action budget. Oracle code lives outside the agent prompt and product checker. Do not expose answers through fixture names, visible labels or metadata supplied to models.

Run: unique ID, attempt number, case hash, application source manifest/commit, browser/build version, model ID/revision/quantization, adapter and prompt version, candidate limits/context audit, cache state, router/helper model, start/warm state, monotonic timing, outcomes, escalation reason, independent oracle result and artifact references. Record unavailable, unsupported, error, timeout, stopped and failed separately. Model unavailable counts against deployment availability, not as an invented reasoning error; show both all-scope and supported-capability denominators.

Event: run/turn/step/document/command IDs, action status, finite choice, model/helper/queue/native/load timings, observed transition, expected/unmet predicates. Use monotonic durations plus wall-clock timestamps for correlation. No hidden chain-of-thought. Metadata-only diagnostics stay as-is; synthetic fixture quotes and optional page frames live in a separate private experiment store. Real-page content capture is off by default and sensitive content is excluded from exported replay/video.

## Metrics

- **Whole-goal success:** all requested predicates hold under the independent oracle. A related destination or partly filled form fails.
- **False completion:** controller said reached, oracle did not; give count, denominator and reason. **Incorrect mutation** is separate, including duplicates after uncertain acknowledgement.
- **Coverage:** local-only success / all requested cases, supported-capability success, hybrid success, unavailable and unsupported rates. Declining everything must not look accurate.
- **Retrieval/extraction:** candidate recall, exact-value accuracy, no-answer precision/recall, evidence coverage, citation support and contradictions retained. Exact quote presence does not by itself prove a claim.
- **QA:** seeded defect detection and false bug reports. A workflow finishing is not a bug diagnosis.
- **Speed:** cold load, warm model decision p50/p95, first useful evidence time, end-to-end completion p50/p95, queue, helper, model, page/network and verification time. Include failed-run duration/timeouts; also show successful-run time separately to avoid censoring slow failures.
- **Resource use:** inference/forward/helper/native counts, input tokens/truncation, known provider cost, local peak memory and host contention. Local dollars are not presented as zero total resource cost.

Use paired cases and counterbalanced model order. Keep identical semantics and same initial fixture per arm; show both common-input comparisons within all models' limits and best-supported per-adapter chunking as separate tracks. Do not compare warmed engines against cold engines. Repeats estimate latency/variance; they do not multiply the number of independent labeled examples. Cache off for main comparison; cache-on is a separate experiment.

## Controlled optimizations

Start from frozen baseline, change one variable, and retain regressions:

| Change | Controlled comparison | Keep only if |
|---|---|---|
| Focused state | Whole observation vs task-relevant fields | Less latency/context without lost required evidence |
| Candidate pruning/chunking | Full admissible set vs lexical shortlist; 4/6/12-sized groups only where adapter limits allow | Candidate recall and whole-goal success retained, no first-chunk bias |
| Hierarchy | Flat vs section → span / site → resource | Wrong early branch is recoverable; total task benefit |
| Batched questions | Sequential vs actual shared-prefix/batch implementation | Fewer measured forward costs or lower wall time; not just fewer HTTP calls |
| Observation/decision cache | Off vs document/goal/model/prompt-bound cache | Correct invalidation; mutations are never replayed |
| Tiny first stage | Current SemIf router vs small-model triage then SemIf/Grok | End-to-end latency improves at acceptable error/coverage; no invented confidence |
| Verifier/cascade | Code-only vs code plus semantic check; unresolved field escalation | Lower false completion with acceptable added latency and no circular scoring |
| History | Last three text turns vs structured completed references | Better corrections/continuations without cross-session or stale-state confusion |

Do not fine-tune weights initially. Consider training only after repeated failure classes survive question/context/contract fixes and enough licensed labeled data exists. Autoresearch optimizes development/validation only and never promotes itself from a self-assigned score.

## Promotion gate (proposed policy)

Keep useful but unproven capabilities in Lab with visible limitations. For a default read/navigation skill: at least 60 unique held-out cases, observed whole-goal success at least 95%, zero false-completion regressions or incorrect mutations on the acceptance suite, and reported 95% uncertainty intervals. For form mutation workflows: at least 98% observed success, the same zero-error conditions, and the known prefilled-input bug resolved. Small samples are not claims about arbitrary sites.

No arbitrary speed promise: record a pilot latency baseline; a promotion must not worsen task-success/coverage to win speed. Default changes need a saved versioned evaluation and rollback setting. Unresolved native compatibility or task ownership failures block that skill's default, not unrelated read-only work.

## Commands

Existing offline checks (project root):

```sh
uv run --project backend python -m pytest backend/tests -q
uv run --project backend ruff check backend/jet_browser backend/tests
```

From `app/`, run `flutter test` and `flutter analyze`; build release after native changes. Existing scripts' `--help` is safe, but do not run their browser-mutating modes while the user's no-takeover instruction is active.

The following is a **proposed CLI contract, not an installed command** (B04/B27/B32):

```text
python scripts/browser_lab.py validate --manifest backend/tests/fixtures/browser_lab/cases.json
python scripts/browser_lab.py replay --suite pilot --models lfm_rlcd,qwen4b_semif_shared --run-inference
python scripts/browser_lab.py replay --suite pilot --models jev_hosted --run-inference --max-dollars 5
python scripts/browser_lab.py cookbooks --manifest tasks/browser-lab-cookbooks.json --mode jet-adaptation --run-inference
python scripts/browser_lab.py report --run-dir artifacts/browser-lab/<run-id>
```

`--help`, import, validate, fake tests and report must not contact providers or read credentials. Hosted mode uses existing private credential configuration without printing it. Native execution is started from the in-app Lab, with ownership, fresh QA profile/session/tab and clear Stop; it is not silently added to any command above. B33–B34 must separate the currently hardcoded runtime/service/profile first; until then native Lab execution is unavailable. This uses a configured instance of the existing stack, not another browser automation framework. Artifacts are timestamped/append-only and preserve primary errors even when cleanup fails.

## Hybrid-loop extension

[D21/D22 and H08](chat-and-hybrid-loops.md) add 40 catalog cases across bookmark and website collection, taking the broad target to 440 (220 development, 110 calibration, 110 held-out before extra promotion samples). Compare identical source fixtures and taxonomy versions; score unique-item discovery recall, duplicate rate, field coverage, label quality/abstention, false total-completion claims, restart correctness, and Grok calls per 100 processed items. Include virtualized/repeated rows, scope/cursor changes, pagination traps, login expiry and taxonomy edits. Freeze the Grok-proposed plan/taxonomy for executor comparisons; evaluate end-to-end adaptive planning separately. Source-account mutation is outside these read/organize scenarios.
