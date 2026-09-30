# Changelog

## Unreleased — 2026-09-28 baseline

### Added

- Open-source release preparation: Apache-2.0 `LICENSE` and `NOTICE`, a public README, and
  `docs/dependencies/THIRD_PARTY.md` listing every dependency with repository, pinned
  commit or revision, and license. The Flutter packages are now git submodules pinned by
  SHA to public repos (SebRincon/flutter_cef_browser, vten_chat, shadcn_flutter_jet);
  laya-mlx installs from upstream commit `0a85951`; local paths in docs became repository
  links.

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
- `scripts/sign_release.sh`: inside-out Developer ID signing with the hardened runtime and
  per-component entitlements, optional notarization and stapling; `--list` dry run.
- Tag calibration harness (`scripts/eval_tagging.py`) and a 90-post synthetic corpus with
  fixed development/calibration/held-out splits; SemIf 4B baseline recorded in
  `docs/evidence/tagging-semif-20260928.json`.
- `tagged_feed` v2: the local model decides whether an unflagged post that ends mid-thought
  should be opened in full, and untagged posts get a one-best-category second pass
  (`model.best_tag`): development micro F1 0.791 → 0.854 with no added false tags.
- Reviewer repair tools: Grok can list untagged or cut-off records (ids only), have code open
  and expand an exact X post into a record, and re-run local tagging on up to 20 records;
  reviews are told to fix records and improve the loop instead of deferring.
- `save_workflow` compiles custom JavaScript first (`JetWorkflow --check`, no execution) and
  rejects syntax errors with their line or calls to undeclared capabilities;
  `workflow_status` reports the loop's own counters for the next refinement.
- Grok is no longer pinned: the packager bundles the latest release (`grok update`), and a
  bundled app updates Grok in its own Grok home at every start and uses the newer copy
  (floor 1.0.41). Verified live with Grok 1.0.44.

### Fixed

- Development checkouts were treated as packaged apps for the Grok home because the repo
  also holds `model-downloads.json`; only `bundle-manifest.json` now marks a bundle.

- A recovery that finds less text than the saved capture is a blocked `no_additional_text`
  result, not a script error; `patch_workflow_records` batches up to 20 corrections so repair
  turns stay under the time limit. Second live repair pass: untagged 14 → 6.

- Found in the live repair of the real run: `patch_workflow_record` refused completed runs; a
  failed turn that had already repaired records claimed nothing was saved; and the stage text
  said "writing the workflow" after Grok merely read the guide. Repairs on real data took
  untagged bookmarks from 23 to 14 and the last cut-off post from 1 to 0.

- Packaged Jet runs Grok with its own home (`<data>/.runtime/grok-home`): the user's global
  `~/.grok` MCP servers, hooks and plugins no longer load into Jet's Grok sessions, and
  sign-in happens in Jet's setup. An empty-HOME audit of the packaged runtime passed.

- An unresponsive X detail tab during truncated-post recovery now blocks that one recovery
  (`detail_unresponsive`, partial evidence kept) instead of pausing the whole run; seen at
  item 51 of the real top-100 run.

- Real top-100 run: the workflow checkpoint review denied read-only `list_tabs`, and Grok
  then ended the turn as cancelled, leaving the run paused at ten. Reviews now allow
  `list_tabs`, the review prompt says `run_workflow` re-verifies the tab, and a turn Grok
  ends itself is reported as such instead of as a user Stop.
- A covered Jet window no longer counts as hidden to Chromium
  (`disable-backgrounding-occluded-windows`, `disable-renderer-backgrounding`). Native runs
  showed hidden pages dropping the first press into a prefilled field (3/3 with SemIf);
  with the window in front the same check passed.

- Packaged app: direct browser tasks (`/tasks`, used by the composer's inline actions) and
  delegated `run_task` now start the bundled typing helper first; before, a fill failed with
  "Model connection failed" unless a chat turn had already started it. Found in the first
  native run on the pinned CEF.

- Native clicks and fills are sent only after a harmless pointer move reaches the observed
  target, and text only after the field has focus. Misrouted or dropped native input now
  stops the task with delivery diagnostics instead of pressing another control or typing
  elsewhere (the retained prefilled-form failure).

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

- The real top-100 bookmark request has not yet been rerun; a paid synthetic rerun of the
  same request shape passed (template saved at 31 s, 20/20 records).
- Real top-100 bookmark completion, held-out accuracy and native background endurance
  remain unverified. Prefilled forms and complex browser controls need more work.
- The pinned CEF (vten frame-lease build) has passed a clean-worktree build, package
  and headless service smoke test, but not yet a native UI run. Public
  signing/notarization and a full license review remain. This is a local test build.

Validation: see [verification](docs/VERIFICATION.md) for exact checks and retained
historical evidence. Build outputs, weights, credentials and user data are excluded.
