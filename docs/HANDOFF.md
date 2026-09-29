# Agent handoff

Checkpoint: 2026-09-28 (evening), app `0.1.0+1`, tag `checkpoint-2026-09-28b` on `main`.
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
   - Hash-locked engine environments; the packager rejects an unpinned Grok CLI or CEF.
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

Checks at this checkpoint: 369 backend (real-DOM and JavaScriptCore cases included),
62 app and 9 vendored-chat tests passed; ruff and `flutter analyze` clean.
[Verification](VERIFICATION.md) keeps the dated history.

## Next work, in order

1. **Live confirmation (needs the user's go-ahead: paid calls or native windows).**
   - Paid Grok: `scripts/verify_portable_workflow.py --scenario template`.
   - Native UI on the pinned vten CEF, also under the hardened runtime.
   - Native prefilled-form rerun: the new probe will name the cause if it recurs.
   - Hidden-tab endurance, and the real top-100 bookmark request in an isolated profile.
2. **Release.** First Developer ID signature and notarization
   (`JET_SIGN_IDENTITY=… JET_NOTARY_PROFILE=… scripts/sign_release.sh`; uploads to
   Apple), clean-account test, and a license review of the bundled wheels.
3. **Tag recall.** Tune design/research questions on development data, then score a
   new held-out set; the current one is used up.
4. **Remaining browser gaps.**
   - Generic form completion: a DONE decision is still `manual_check`.
   - Shared bounded selection for link and page actions: link selection is still first-match.
   - Cross-origin frames and complex editors.
   - Claude Code/Codex providers and the broader Browser Lab.
   Ordered details: [remaining work](../tasks/remaining-work.md).

## State and operational cautions

- Packaged default data: `~/.jet-browser`; development: repository `.runtime`.
  These are separate profiles and databases, not automatically migrated.
- `vendor/flutter_cef_browser/macos/Frameworks/` now holds the pinned vten CEF;
  `Frameworks.previous/` holds the original 2026-05 build, the one used by the
  earlier native checks. `scripts/install_cef.sh --check` tells which is installed.
- Scratch artifacts from this session (clean worktree, relocated bundle, isolated data
  with cloned weights) live under the session scratchpad, not in the repository.
  `git worktree prune` cleans the worktree record if that directory is removed.
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
