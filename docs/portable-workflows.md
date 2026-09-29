# Custom workflows in the packaged app

Updated 2026-09-28. Grok now writes and revises executable JavaScript workflows, rather than only filling in a fixed collection plan. The local `.app` contains its runtime dependencies. Model weights download through the application; an end user does not install Python, Node, Lua or a source checkout.

## Use it

Open `dist/Jet Browser.app` on Apple Silicon macOS. In **Models and setup**, download SemIf 4B (about 9.34 GB) and the 0.8B typing model (about 652 MB), then sign in to Grok. LFM 350M and both Laya variants are optional. The setup view works before Chromium initializes; the system may ask for Chromium Safe Storage access when opening the browser. Authentication and model downloads require network access.

Use the same chat, for example:

> Write a JavaScript workflow to organize up to 100 bookmarks on this tab. Use overlapping mobile, web, desktop, design, research, tools and open-source tags. Save each observed link, author, posted date and a local summary. Recover collapsed posts before labeling them. Review the first 10, repair weak summaries or revise the script if needed, then continue within a ten-minute local execution budget. You may share small review samples with Grok.

For organizing, tagging or summarizing a feed or X Bookmarks, Grok now selects the built-in `tagged_feed` template with a few options instead of writing JavaScript (see [Built-in templates](#built-in-templates)). For anything the template cannot express, Grok fetches the SDK and writes custom source. Either way it saves version 1 and starts a background run. Its compact card shows saved/classified counts, runtime, state and source revision. Open the card to inspect records/source or export CSV into the conversation workspace. The source tab stays owned while the user browses elsewhere. Stop ends further dispatch. One agent browser job runs at a time; the existing chat remains available.

At a review checkpoint the runtime pauses and asks Grok to inspect bounded authorized samples. Grok may repair tags/summaries, change taxonomy or JavaScript, then resume the same workflow. Runtime errors also enter this repair path. Repeated no-progress reviews stop automatic retry. Scope, source identity, local model and original budgets cannot silently increase. A user escalation is still necessary when the task cannot be resolved inside its authority.

## Runtime and SDK

`JetWorkflow` is a native helper using Apple's [JavaScriptCore](https://developer.apple.com/documentation/javascriptcore). A script receives synchronous `jet.input` and `jet.call(name, arguments)`; it has no Node, DOM, network, process or filesystem globals. The parent controller implements the following capabilities:

| Capability | Behavior |
|---|---|
| `feed.observe` | Fresh, source-checked post evidence and already-saved flags |
| `feed.scroll` | Scroll the observed container with document/source/ownership fences |
| `post.recover` | Open the exact X status in an owned detail tab; guarded Show more; repair evidence |
| `model.decide` | Local finite-choice decision over bounded source text |
| `model.classify` | Independent overlapping tags using local chunked decisions |
| `model.summarize` | Local SemIf 4B summary from observed text |
| `records.put`, `records.list` | Durable deduplicated records with observed metadata |
| `records.patch` | Audited summary/tag correction without inventing source evidence |
| `run.progress` | Compact progress message |
| `run.checkpoint` | Persist script state and pause, request review, continue locally or finish |

The public MCP lifecycle is `workflow_sdk`, `save_workflow`, `read_workflow`, `run_workflow`, `workflow_status`, `control_workflow`, `workflow_records`, `patch_workflow_record`. Grok writes source directly through these finite tools; no shell or source checkout is needed. Source revisions are immutable and use expected-version checks. Records preserve their original capture and every later correction.

Definitions declare tab, start URL, source kind, model, taxonomy, enabled capabilities and limits. Source is capped at 32 KB. A native invocation (slice) is at most 180 seconds/1,000 SDK calls; `jet.input.budget` gives the current slice's own `{seconds, calls}` and checkpoints preserve state across slices. `run.checkpoint` status `continue` ends a slice and starts the next one locally, with no provider turn, only when the slice saved or scrolled. After three consecutive continuations with no new record, or a slice with no progress at all, the run pauses with `continue_no_new_items`/`continue_no_progress`. Pause or Stop between slices cancels the pending continuation. A slice that hits the hard timeout without a checkpoint still pauses and wakes Grok for review. The original cumulative authorization is at most four hours of local execution, 10,000 SDK calls and 5,000 records. Grok planning/review latency is separate from local execution time. Restart restores records and pauses interrupted runs without automatically replaying actions.

Review sharing follows the existing user preference: at most five 400-character excerpts per review, with no paging through the whole private dataset. A restricted review profile can operate only on the same workflow/session. Full records stay in local SQLite and are available to the UI and local script. Grok is a remote model; the categorization and summary model calls run locally.

## Write, check, run, refine

Workflows are JavaScript in JavaScriptCore, which ships with macOS; it plays the role an
embedded Lua would, with nothing to install. The loop Grok follows:

1. `save_workflow` compiles custom source with `JetWorkflow --check` (never executing it)
   and rejects a syntax error with its source line, or a literal `jet.call` to a
   capability the definition does not list. Templates are rendered from vetted source.
2. `run_workflow` runs it in bounded slices.
3. `workflow_status` returns the run's own counters (for `tagged_feed`: untagged, partial,
   expanded by decision, second-pass tags) and the last result.
4. Grok fixes records (below) and, when a problem repeats, saves a new revision with
   changed options or source and runs again. Scope, model and lifetime limits cannot grow.

## Reviewer repairs

At a checkpoint, or after a run completes, Grok fixes records rather than leaving them
for later (`backend/jet_browser/workflow_repair.py`). Grok chooses; code acts:

- `workflow_records` with `needs: untagged | truncated` lists matching record ids and
  flags, never post text.
- `recover_workflow_record` opens one cut-off X post in an owned tab, expands a single
  observed Show more, stores the exact observed text (audited as a source recovery
  `requested_by: grok`) and re-tags/re-summarizes it locally. Each post is attempted at
  most once per turn, at most 20 per turn, and never retried.
- `retag_workflow_records` re-runs local tagging, including the second pass, on up to 20
  stored records, optionally re-summarizing.
- `patch_workflow_records` applies up to 20 justified tag/summary corrections in one call,
  each independently (single-record `patch_workflow_record` remains).
- A recovery whose post text is shorter than the saved capture (e.g. an image label) returns
  `blocked: no_additional_text` and keeps the fuller evidence.

On the real top-100 run these tools took untagged bookmarks from 23 to 6 and the last cut-off
post to full text over two short repair turns ([evidence](evidence/real-top100-20260928.json)).

All three require a paused or completed run, honor Stop, and return metadata only. When
a problem repeats, the review prompt tells Grok to change template options or the script
with `save_workflow` and run again.

## Built-in templates

`save_workflow` accepts `definition.template = {name, options}` in place of `source` and `capabilities`; exactly one form is allowed. Jet renders vetted source with the options frozen into an `OPTIONS` header and stores it like any other revision, so `read_workflow`, revisions, scope checks and the runtime are unchanged. `workflow_sdk` lists templates and their option bounds. A template turns authoring into a small tool call, which removes the long script-writing turn behind the [2026-09-28 timeout](incidents/2026-09-28-grok-timeout.md).

`tagged_feed` v2 (`backend/jet_browser/workflow_templates.py`; v1 revisions keep their frozen source):

- Skips saved items. On X Bookmarks it recovers truncated posts; a blocked recovery keeps the partial evidence (still marked truncated) and tags it rather than inventing text. Recovery is disabled for other feeds.
- On X Bookmarks, a post the extractor did not flag but whose text ends mid-thought ("…") goes to a local `model.decide` branch: expand (open the exact post) or keep (`expand_cut_off`, default on).
- Applies independent local tags; a post left untagged gets one second-pass `model.best_tag` question (one best category or none; `fallback_tag`, default on). Then an optional local summary, and the observed link, author and date.
- Review checkpoints report how many posts are still untagged or partial so the reviewer can fix them.
- Pauses for review after `first_review` items (default 10), then every `review_every` items (0 = no periodic review).
- Before its slice budget ends it checkpoints `continue`; the next slice resumes from the current page without a Grok turn.
- Completes at `limits.max_items` or a proven end of feed. After `max_idle_scrolls` scrolls reveal nothing new, a local `model.decide` chooses whether to keep scrolling; the run pauses after twice that many.
- Local model failures on three items pause for review; failed item ids are skipped on later slices.

## Tag accuracy (synthetic calibration)

`scripts/eval_tagging.py` runs the real `model.classify` path over 90 synthetic
bookmark-style posts with seven overlapping tags (`backend/tests/fixtures/tagging/`,
30 development / 30 calibration / 30 held-out, gold tags fixed before any run). With
SemIf 4B on 2026-09-28 ([evidence](evidence/tagging-semif-20260928.json)):

| Split | Exact match | Micro F1 | Macro F1 | False-positive tags | Missed tags |
|---|---:|---:|---:|---:|---:|
| Development | 0.533 | 0.791 | 0.790 | 2 | 17 |
| Calibration | 0.500 | 0.771 | 0.774 | 10 | 12 |
| Held-out (scored once) | 0.467 | 0.788 | 0.785 | 5 | 16 of 55 |

The v2 second pass (`model.best_tag` on untagged posts) raised micro F1 on development from 0.791 to 0.854 and on calibration from 0.771 to 0.784, with no added false tags ([evidence](evidence/tagging-fallback-20260928.json); held-out 0.788 → 0.800 is a second look). A single yes-probability threshold chosen on calibration (0.55) scored 0.787 micro F1
on held-out, so the shipped decision (the model's own yes/no) stays. Precision is high;
recall is the weakness, worst for design (held-out recall 0.33) and research (0.57). The
prompt-injection post received no tags. Prompt changes must be tuned on development and
then scored on a new held-out set, because this one has now been used. These are
synthetic posts written for Jet, not the user's bookmarks, and not a claim about real
archive accuracy; checkpoint review remains the safeguard.

## Packaging and data

`native/JetLauncher` starts bundled CPython before exec into Flutter/CEF; the initialized CEF process never forks the controller. The bundle includes Python 3.12.13, pinned local-engine packages, Grok CLI, licenses and the native JavaScript helper. It uses a minimal system PATH. Model downloads are pinned by revision, file size and SHA256 in `model-downloads.json`; no downloaded Python/model repository code is executed.

App data defaults to `~/.jet-browser`, including models, `.runtime` stores/profile/logs and conversation workspaces. Bundle resources are read-only. The previous development `.runtime` and bookmark collection are not automatically migrated. An instance identity check prevents attaching to the wrong data directory on the same port.

Developer packaging (these tools are build-time dependencies only):

```sh
bash scripts/prepare_portable_runtime.sh
python3 scripts/package_runtime.py
```

The present 2.5 GB app is locally ad hoc signed. Public distribution still needs Developer ID signing/notarization and verification on another account/machine. This task did not publish an installer.

## Verification

[Recorded evidence](portable-workflows-verification-20260928.json) separates completed checks from remaining native work:

- 341 backend tests passed with real isolated Chromium DOM cases; two additional immediate-Stop/Pause regressions and an explicit blocked-recovery contract regression passed. Backend lint passed.
- 59 Flutter tests passed, analyzer clean and macOS release built; an additional first-run regression proves setup does not initialize Chromium. Workflow/setup UI renders were inspected at narrow widths.
- Relocated bundled service started with a fresh data directory and minimal PATH. LFM downloaded its 713.7 MB pinned snapshot through the app setup API. Other models used cloned cached weights with full manifest verification and missing metadata downloads.
- All four local inference engines ran from the relocated bundled runtime. These are smoke tests, not comparative performance benchmarks.
- Real Grok authored version 1, saved two synthetic bookmarks with local multitagging/summaries, reviewed, made one audited summary correction, revised the same workflow and saved a third unique bookmark. Version 2 completed with 18 SDK calls. Local execution took 12.924 seconds; total including Grok authoring/review was 246.51 seconds.
- This fixture proves the author/run/review/revise path. It did not require scrolling or truncated-post recovery; those paths have separate DOM/unit tests. Generic fixture authors remained null when extraction could not establish them. No metadata was fabricated.
- The earlier native startup was blocked inside macOS Keychain. A requested retry got past Keychain and exposed a Flutter semantics lifecycle crash, which was repaired. The packaged native browser then loaded the demo, returned real DOM state and survived native chat hide/restore with no AXTree errors. See [rerun evidence](native-startup-accessibility.md). Full native background endurance remains unverified. The empty-profile first-run setup was also visually verified before Chromium initialization.

The real user bookmark job and existing browser were not resumed or replaced by these tests. The prior top-100 job is still unfinished. Classification accuracy, calibration, generic website-specific extraction, large CSV exports and multi-hour archive behavior require further measured work.

`--scenario template-local` runs the `tagged_feed` template on a 25-post synthetic feed with the packaged runtime, real SemIf and isolated headless Chromium but no provider (free). On 2026-09-28 it saved 20 unique records with summaries and dates, paused once for review at ten and completed in 59 s of local execution ([evidence](evidence/template-local-20260928.json)). `--scenario template` sends the incident-shaped request to real Grok and passes only if Grok chose the template and the same 20 records complete. It passed on 2026-09-28 ([evidence](evidence/grok-template-live-20260928.json)): Grok chose `tagged_feed`, first saved it 31 s into a 65 s authoring turn (the incident turn reached 300 s without saving), reviewed the first ten in a 49 s turn and the run completed 20 unique records with summaries and dates, 134 s end to end.

The replayable live harness is `scripts/verify_portable_workflow.py`. It requires an explicit isolated data directory, a bundled runtime, prepared models, a Chromium test executable and an authenticated Grok account. It uses only synthetic posts, makes paid provider calls, and never attaches to the user's browser. `--help` is safe and does not load Jet or contact a provider.

```sh
clankstamp open run_20260924_002021_jet-browser --step step_024
```
