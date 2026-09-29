# Custom workflows in the packaged app

Updated 2026-09-28. Grok now writes and revises executable JavaScript workflows, rather than only filling in a fixed collection plan. The local `.app` contains its runtime dependencies. Model weights download through the application; an end user does not install Python, Node, Lua or a source checkout.

## Use it

Open `dist/Jet Browser.app` on Apple Silicon macOS. In **Models and setup**, download SemIf 4B (about 9.34 GB) and the 0.8B typing model (about 652 MB), then sign in to Grok. LFM 350M and both Laya variants are optional. The setup view works before Chromium initializes; the system may ask for Chromium Safe Storage access when opening the browser. Authentication and model downloads require network access.

Use the same chat, for example:

> Write a JavaScript workflow to organize up to 100 bookmarks on this tab. Use overlapping mobile, web, desktop, design, research, tools and open-source tags. Save each observed link, author, posted date and a local summary. Recover collapsed posts before labeling them. Review the first 10, repair weak summaries or revise the script if needed, then continue within a ten-minute local execution budget. You may share small review samples with Grok.

Grok fetches the SDK, saves version 1 and starts a background run. Its compact card shows saved/classified counts, runtime, state and source revision. Open the card to inspect records/source or export CSV into the conversation workspace. The source tab stays owned while the user browses elsewhere. Stop ends further dispatch. One agent browser job runs at a time; the existing chat remains available.

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
| `run.checkpoint` | Persist script state and pause, request review or finish |

The public MCP lifecycle is `workflow_sdk`, `save_workflow`, `read_workflow`, `run_workflow`, `workflow_status`, `control_workflow`, `workflow_records`, `patch_workflow_record`. Grok writes source directly through these finite tools; no shell or source checkout is needed. Source revisions are immutable and use expected-version checks. Records preserve their original capture and every later correction.

Definitions declare tab, start URL, source kind, model, taxonomy, enabled capabilities and limits. Source is capped at 32 KB. A native invocation is at most 180 seconds/1,000 SDK calls; checkpoints preserve state across invocations. The original cumulative authorization is at most four hours of local execution, 10,000 SDK calls and 5,000 records. Grok planning/review latency is separate from local execution time. Restart restores records and pauses interrupted runs without automatically replaying actions.

Review sharing follows the existing user preference: at most five 400-character excerpts per review, with no paging through the whole private dataset. A restricted review profile can operate only on the same workflow/session. Full records stay in local SQLite and are available to the UI and local script. Grok is a remote model; the categorization and summary model calls run locally.

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

The replayable live harness is `scripts/verify_portable_workflow.py`. It requires an explicit isolated data directory, a bundled runtime, prepared models, a Chromium test executable and an authenticated Grok account. It uses only synthetic posts, makes paid provider calls, and never attaches to the user's browser. `--help` is safe and does not load Jet or contact a provider.

```sh
clankstamp open run_20260924_002021_jet-browser --step step_024
```
