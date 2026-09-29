# Changelog

## Unreleased — 2026-09-28 baseline

### Added

- Standalone macOS Chromium browser, dark Flutter/shadcn UI and vendored vten chat.
- One local-first conversation, Grok ACP/MCP, durable history and private tracing.
- Local LFM, Laya and SemIf adapters; intent-aware navigation and bounded collection jobs.
- Tab-bound background workflows, overlapping tags, local summaries, exact-post
  recovery, Grok checkpoint review, versioned JavaScript and audited record repairs.
- Conversation workspaces, safe artifact previews, CSV export and compact progress cards.
- Bundled controller/model/provider/script runtimes and in-app model setup.
- Initial Git baseline, agent guidance, architecture/development docs and current handoff.

- Built-in `tagged_feed` workflow template: Grok organizes a feed or X Bookmarks with a
  small `save_workflow` template call instead of writing JavaScript. Workflows can
  checkpoint `continue` to start the next time slice locally without a Grok turn.

- Reproducible build inputs: `scripts/install_cef.sh` installs and verifies vten's
  pinned CEF release (`cef-147.0.11-vten-frame-lease-075`), converting it to a
  versioned framework bundle; hash-pinned local-engine locks
  (`vendor/local-engines/locks/`, `scripts/lock_engines.sh`); the packager rejects an
  unpinned Grok CLI or CEF and bundles the CEF license and Chromium credits.

### Fixed

- Tab switching/closing can select among more than 15 tabs: bounded chunks with an
  escape and a final round between chunk winners (previously the first 24 tabs in one
  over-limit question).

- A fresh clone could not build: `.gitignore`'s `models/` also hid ten CEF plugin
  source files under `lib/src/models/`.

- Grok turns now end after 150 s of provider silence (no tool running) as well as at
  the 300 s ceiling, with the stage and completed tools named. After a failed turn Jet
  reports from saved state whether a workflow or collection was saved or started, and
  the chat status shows the stage. Reasoning volume is traced without content.
- Completed local tasks now ignore delayed progress updates that would restore a running state.

- Native accessibility startup lifecycle: let macOS control semantics tree rebuilds.
- Workflow recovery result contract and immediate Pause/Stop dispatch regressions.
- Workflow test formatting/import lint issues found during the handoff checks.

### Known limitations

- Grok workflow authoring now uses a template call for feed organization; a real
  provider rerun of the top-100 bookmark request has not yet confirmed it.
- Real top-100 bookmark completion, held-out accuracy and native background endurance
  remain unverified. Prefilled forms and complex browser controls need more work.
- The pinned CEF (vten frame-lease build) has passed a clean-worktree build, package
  and headless service smoke test, but not yet a native UI run. Public
  signing/notarization and a full license review remain. This is a local test build.

Validation: see [verification](docs/VERIFICATION.md) for exact checks and retained
historical evidence. Build outputs, weights, credentials and user data are excluded.
