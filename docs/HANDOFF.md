# Agent handoff

Checkpoint: 2026-09-29, app `0.1.0+1`, tag `checkpoint-2026-09-29a` on `main`.
Not a public release. Start with [AGENTS.md](../AGENTS.md), then
[architecture](architecture.md) and [development commands](development.md).

## What the product does

Jet is a standalone Chromium browser with a Flutter/shadcn shell and vten's
vendored chat presentation. There is one conversation. SemIf 4B routes simple
requests locally; Grok Build handles general reasoning and configures or authors
JavaScript workflows. Local models repeatedly observe, decide, classify and
summarize; Grok reviews checkpoints, repairs records or revises the same workflow.
Compact job cards expose progress, Pause/Stop, records and artifacts.

Implemented: native tabs/navigation, shared durable history, local adapters,
correlated private traces, bounded website/feed collections, tab-bound jobs,
exact-X-post recovery/Show more, overlapping workflow tags, local summaries,
audited corrections, workspace previews/CSV, versioned scripts, built-in workflow
templates and in-app setup. See [workflow contract](portable-workflows.md),
[tab ownership](tab-bound-jobs.md) and [workspace contract](background-jobs-and-workspace.md).

## What changed in this session (all on `main`)

1. **Grok authoring timeout** ([incident](incidents/2026-09-28-grok-timeout.md)). Grok had
   reasoned for ~65 s after `workflow_sdk`, then gone silent. Now:
   - `GrokClient` ends a turn after 150 s of provider silence while no tool runs, and
     keeps the 300 s ceiling. It raises `GrokStalled` with the stage and completed tools.
   - Reasoning volume and stage changes are traced without content. The chat shows the
     stage ("Grok is writing the workflow").
   - After any provider failure, the service reports from saved state what was saved
     or started. It never replays the turn.
   - Feed/bookmark organization uses the built-in `tagged_feed` template: a small
     `save_workflow` call instead of a hand-written script.
   - Workflows checkpoint `continue` to start the next time slice locally without a
     Grok turn.
2. **Reproducible build inputs.**
   - `scripts/install_cef.sh` installs vten's pinned CEF (`cef-147.0.11-vten-frame-lease-075`)
     and verifies it by hash. The main checkout now uses it; the old build is in
     `Frameworks.previous/`.
   - Hash-locked engine environments; the packager rejects CEF that fails its check.
     Grok is not pinned (latest release; see item 7).
   - CEF/Chromium notices now ship in the bundle.
   - `scripts/sign_release.sh` signs with the hardened runtime and can notarize.
   - A clean worktree built, packaged, ad-hoc signed and ran the service headlessly.
     This also exposed and fixed ten plugin sources that `.gitignore` had hidden.
3. **Browser gaps.**
   - Tab switching/closing works with any number of tabs (bounded chunks and a final round).
   - Native clicks and fills are sent only after a pointer move reaches the target;
     text is sent only after the field has focus. This guards the prefilled-form
     failure, whose diagnostics show the press never reached the checkbox.
4. **Accuracy and endurance, offline.**
   - Tag calibration on a synthetic held-out split: SemIf micro F1 0.788; threshold
     calibration gave no gain; design and research recall are weak.
   - A 300-item multi-slice template endurance test passes.
   - The packaged runtime ran the template end to end, with real SemIf and headless
     Chromium, for 20 records.

5. **Live confirmation (user-approved, same night).**
   - Paid Grok, synthetic incident request: template saved 31 s into a 65 s authoring
     turn; 20/20 records completed.
   - Native app on the pinned vten CEF: startup, fresh and prefilled forms.
     Prefilled failures traced to covered windows; fixed via Chromium switches.
   - The composer's direct tasks now start the typing helper.
   - A Developer ID, hardened-runtime build verified strictly and passed native form
     checks with its window fully covered. Notarization was skipped by the user.
   - **Real top-100 X Bookmarks run completed:** 100/100 records, 33 recovered posts,
     10 Grok reviews correcting 37 records, 23 untagged. Two interruptions were fixed
     during the run: denied `list_tabs` in reviews, and an unresponsive detail tab.
     [Evidence](evidence/real-top100-20260928.json) holds counts only.

6. **Self-contained app and an adaptive loop (2026-09-29).**
   - A packaged app keeps Grok's config, sign-in and sessions in `<data>/.runtime/grok-home`.
     The developer's `~/.grok` MCP servers and hooks no longer load into Jet.
   - An empty-HOME audit of the packaged runtime passed; the only write was Jet's own
     `~/.jet-browser` workspace index. Users install nothing: CPython, packages, engines,
     Grok CLI and CEF are bundled; the script engine is macOS's JavaScriptCore.
   - `tagged_feed` v2: the local model decides whether to open a post that looks cut off,
     and untagged posts get a one-best-category second pass (`model.best_tag`).
     Development micro F1 0.791 → 0.854 with no added false tags.
   - Grok repair tools for paused or completed runs:
     - `workflow_records needs=untagged|truncated` lists ids only;
     - `recover_workflow_record` has code open one exact post;
     - `retag_workflow_records` re-runs local tagging;
     - `patch_workflow_records` batches corrections.
   - `save_workflow` compiles custom JavaScript first (`JetWorkflow --check`), and
     `workflow_status` reports the loop's own counters.
   - **Live repair of the real run:** two short Grok turns took untagged bookmarks from
     23 to 6 and the last cut-off post to full text. The turns exposed four bugs, all
     fixed:
     - patches were refused on completed runs;
     - a failed turn misreported "nothing saved" after repairing records;
     - a shorter recovered text raised a raw error;
     - one-at-a-time patches ran into the 300 s limit.

7. **Latest Grok, no pin (2026-09-29, at the user's request).**
   - The packager runs `grok update` and bundles the newest release, refusing only
     releases older than 1.0.41.
   - A bundled app runs `grok update` into its own Grok home at every start and uses the
     newer of the bundled and updated copies.
   - Development no longer counts as packaged just because `model-downloads.json` exists;
     only `bundle-manifest.json` marks a bundle.
   - Verified live with Grok 1.0.44: 20/20 records; 10/10 tool permissions recognized.

Checks at this checkpoint: 394 backend (real-DOM and JavaScriptCore included), 63 app and
9 vendored-chat tests passed; ruff and `flutter analyze` clean.
[Verification](VERIFICATION.md) keeps the dated history.

## Next work, in order

1. **Tag coverage.** 6/100 real records remain untagged after repairs; some may fit no tag.
   Design and research recall remain weakest. The synthetic held-out set is used up, so
   write a new one before claiming further gains.
2. **Tab identity across restarts.** A workflow binds to a per-launch tab id. After a
   relaunch, recovery worked only because reopening X Bookmarks got the same id. Add a
   code-verified rebind to a new tab with the same canonical start URL (audited, paused
   runs only).
3. **Release.**
   - Notarize (`xcrun notarytool store-credentials jet-notary …`, then
     `JET_NOTARY_PROFILE=jet-notary scripts/sign_release.sh`; this uploads to Apple).
   - Clean-account test.
   - License review of the bundled wheels.
   - Grok is not pinned: the packager bundles the latest release and the app updates it in
     its own Grok home. Verified live with 1.0.44.
4. **Hidden-tab endurance.** A covered window now stays active, but a non-active Jet
   tab is still a hidden view. Measure long runs on a background tab.
5. **Remaining browser gaps.**
   - Generic form completion: a DONE decision is still `manual_check`.
   - Shared bounded selection for links and page actions.
   - Cross-origin frames and complex editors.
   - Claude Code/Codex providers.
   Ordered details: [remaining work](../tasks/remaining-work.md).

## State and operational cautions

- Packaged default data: `~/.jet-browser`; development: repository `.runtime`.
  These are separate profiles and databases, not automatically migrated.
- `vendor/flutter_cef_browser/macos/Frameworks/` now holds the pinned vten CEF;
  `Frameworks.previous/` holds the original 2026-05 build, the one used by the
  earlier native checks. `scripts/install_cef.sh --check` tells which is installed.
- Running at handoff: port 9198 only, the isolated real-run profile
  (`/private/tmp/jet-live-20260928`) with your X session, 100 records and the CSV.
  - Its app runs from the rebuilt `dist/` (`16d669f`, pinned Grok 1.0.41). Do not
    repackage `dist/` while it is open.
  - Its service was restarted from the checkout backend (`e058691`) with
    `JET_GROK_HOME=~/.grok`, so it reuses the developer's Grok sign-in.
  - The user is browsing in that window.
  Ports 9168 and 9148 are down. Closing a Jet window does not stop its service; stop a
  service only after confirming its port and pid.
- The Developer ID-signed release copy and the clean worktree are in the session
  scratchpad (`…/scratchpad/release`, `…/scratchpad/jet-clean`), not in the repository.
  Rebuild them with `package_runtime.py --output …` and `sign_release.sh`.
  `git worktree prune` cleans the worktree record once that directory is removed.
- Workspaces normally use `~/.jet-browser/workspaces` even when `JET_DATA_ROOT`
  changes. Set `JET_WORKSPACE_ROOT` explicitly as well for complete test isolation.
- The developer `./jet` CLI still targets repository credentials and port `9148`.
  Engine subprocesses in development need `backend` on `PYTHONPATH` (the dev
  launcher and `scripts/eval_tagging.py` set it).
- Scripts/auth tokens, browser profiles, model weights, raw traces and collected
  posts are intentionally not committed. Sanitized, synthetic evidence is.
- Do not restart a live job just to load a UI change. Stop is a dispatch fence,
  not an undo operation; an already-dispatched action may finish.

## Evidence and reading map

| Work area | Read first |
| --- | --- |
| Chat/UI | [chat interface](chat-interface.md), [vten port audit](vten-chat-port-audit.md) |
| Workflow authoring/review | [portable workflows](portable-workflows.md) (templates, tag accuracy), `docs/examples/` |
| Fixed collection runner | [collections](collections.md), [supervised collections](supervised-collections.md) |
| Browser ownership/recovery | [tab-bound jobs](tab-bound-jobs.md), [feed extraction](feed-collections.md) |
| Providers/diagnostics | [Grok ACP](grok-acp.md), [tracing](tracing.md), [timeout incident](incidents/2026-09-28-grok-timeout.md) |
| Build/release | [development](development.md), `packaging/pins.json`, [CEF manifest](dependencies/cef-artifact-manifest.yaml) |
| Models/navigation | [local-first audit](local-first-agent-audit.md), [navigation goals](navigation-goals.md) |
| Scope/backlog | [specification](SPEC.md), [remaining work](../tasks/remaining-work.md) |
