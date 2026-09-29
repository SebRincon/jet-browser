# Agent handoff

Checkpoint: 2026-09-28, app `0.1.0+1`. This is the initial source baseline on
`main`, not a public release. Start with [AGENTS.md](../AGENTS.md), then
[architecture](architecture.md) and [development commands](development.md).

## What the product does

Jet is a standalone Chromium browser with a Flutter/shadcn shell and vten's
vendored chat presentation. There is one conversation. SemIf 4B routes simple
requests locally; Grok Build handles general reasoning and authors JavaScript
workflows. Local models repeatedly observe, decide, classify and summarize;
Grok reviews checkpoints, repairs records or revises the same script. Compact
job cards expose progress, Pause/Stop, records and artifacts.

Implemented: native tabs/navigation, shared durable history, local adapters,
correlated private traces, bounded website/feed collections, tab-bound jobs,
exact-X-post recovery/Show more, overlapping workflow tags, local summaries,
audited corrections, workspace previews/CSV, versioned scripts and in-app setup.
See [workflow contract](portable-workflows.md), [tab ownership](tab-bound-jobs.md)
and [workspace contract](background-jobs-and-workspace.md).

The packaged app bundles CPython, local-engine dependencies, Grok CLI and a native
JavaScriptCore helper. Users download weights and sign in through setup. Developers
still need build tooling and CEF assets; a fresh Git clone is not a ready-made app.

## Current reliability and next work

1. **Grok workflow authoring can time out before any workflow starts.** The latest
   real bookmark request failed at the fixed 300-second ACP deadline after its
   three preflight tools succeeded. The local router took about 366 ms. No workflow
   was saved or run, and no records were collected by that failed attempt. The
   provider's underlying stall is unknown; this was not the local model or Keychain.
   Start in `backend/jet_browser/grok.py`, `workflow_tools.py` and `service.py`.
   Add safe stage/activity metadata and smaller authoring stages; test cancellation
   and controlled recovery without replaying browser mutations. Do not just raise
   the deadline or record raw reasoning. See [incident](incidents/2026-09-28-grok-timeout.md).
2. **Endurance and accuracy are still open.** Synthetic Grok author/run/review/revise
   succeeded; the real top-100 bookmark task is unfinished. Reinspect the correct
   session/data root before resuming. Native background scrolling, recovery and
   multi-hour runs need dedicated acceptance. Calibrate tags on held-out records.
3. **Finish reproducible distribution.** Automate exact CEF asset acquisition,
   lock all model-engine transitive dependencies, validate the packaging Grok binary,
   then test a clean macOS account/machine. Signing is currently ad hoc; Developer
   ID/notarization and license review remain before public distribution.
4. **Known browser gaps:** prefilled-form input after navigation, independent
   generic form completion, selection beyond 15 tabs, cross-origin frames and
   complex editors. Claude Code/Codex providers and the broader Browser Lab remain
   future work. Ordered details live in [remaining work](../tasks/remaining-work.md).

The Flutter accessibility startup crash was repaired by removing the permanently
held Dart semantics handle. Packaged startup, native DOM read and chat hide/restore
then passed. The [native evidence](native-startup-accessibility.md) supersedes old
“waiting for Keychain” notes; it does not establish full background endurance.

## State and operational cautions

- Packaged default data: `~/.jet-browser`; development: repository `.runtime`.
  These are separate profiles and databases, not automatically migrated.
- The last isolated native test used `/private/tmp/jet-portable-acceptance/data`
  on port `9168`. Its window was closed after the timeout; process state can change.
  Check health/instance identity before acting. Do not terminate another instance.
- Workspaces normally use `~/.jet-browser/workspaces` even when `JET_DATA_ROOT`
  changes. Set `JET_WORKSPACE_ROOT` explicitly as well for complete test isolation.
- The developer `./jet` CLI still targets repository credentials and port `9148`.
  It does not automatically follow packaged or isolated instances. Use the app's
  diagnostics or an authenticated client configured for that instance.
- Scripts/auth tokens, browser profiles, model weights, raw traces and collected
  posts are intentionally not committed. Sanitized evidence and provenance are.
  Files under `artifacts/`, `.runtime/`, `dist/` and `.clankstamp/` mentioned by old
  docs may exist only on the original machine.
- Do not restart a live job just to load a UI change. Stop is a dispatch fence,
  not an undo operation; an already-dispatched action may finish.

## Evidence and reading map

This baseline also fixes delayed local-task progress overwriting a completed
result. The existing packaged app predates that guard; rebuild/package before
native validation. See [verification](VERIFICATION.md) for this commit's checks and dated historical
results. No paid calls or user bookmark actions are required for the normal suite.

| Work area | Read first |
| --- | --- |
| Chat/UI | [chat interface](chat-interface.md), [vten port audit](vten-chat-port-audit.md) |
| Workflow authoring/review | [portable workflows](portable-workflows.md), `docs/examples/grok-bookmarks-v1.js` and `v2.js` |
| Fixed collection runner | [collections](collections.md), [supervised collections](supervised-collections.md) |
| Browser ownership/recovery | [tab-bound jobs](tab-bound-jobs.md), [feed extraction](feed-collections.md) |
| Providers/diagnostics | [Grok ACP](grok-acp.md), [tracing](tracing.md) |
| Models/navigation | [local-first audit](local-first-agent-audit.md), [navigation goals](navigation-goals.md) |
| Scope/backlog | [specification](SPEC.md), [remaining work](../tasks/remaining-work.md) |
