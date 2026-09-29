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

### Fixed

- Completed local tasks now ignore delayed progress updates that would restore a running state.

- Native accessibility startup lifecycle: let macOS control semantics tree rebuilds.
- Workflow recovery result contract and immediate Pause/Stop dispatch regressions.
- Workflow test formatting/import lint issues found during the handoff checks.

### Known limitations

- Grok can hit its five-minute authoring timeout before starting a workflow.
- Real top-100 bookmark completion, held-out accuracy and native background endurance
  remain unverified. Prefilled forms and complex browser controls need more work.
- Fresh-clone CEF acquisition and full engine dependency locking are incomplete;
  public signing/notarization and license review remain. This is a local test build.

Validation: see [verification](docs/VERIFICATION.md) for exact checks and retained
historical evidence. Build outputs, weights, credentials and user data are excluded.
