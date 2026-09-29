# Background collection jobs and agent files

Implemented 2026-09-28. **Latest update:** [Tab-bound execution and post recovery](tab-bound-jobs.md) supersede the active-tab restriction on newly built hosts. The current open app was not restarted. **Updated:** new feed jobs now have [agent-supervised checkpoints](supervised-collections.md); the first ten items pause for review, and automatic continuations share one authorized budget. The original unsupervised execution behavior below remains relevant to legacy jobs. This supersedes the six-scroll test-pass default for feed collections. Existing plans retain their explicit limits until reconfigured.

The user asks once in the shared chat. Grok chooses the observed source, fixed taxonomy, installed local model and limits. New feed jobs default to local SemIf 4B; explicit model choices and existing saved models are preserved. The browser action model setting remains separate. One local job repeatedly observes, classifies unseen posts, saves each item and scrolls. A finite local-model progress check runs before scrolling, periodically, and on loading/stalled/status evidence. Code retains authority over the source, Stop, budgets and duplicate suppression. Neither model-generated scripts nor recursive remote-agent calls are involved.

Feed defaults are 30 minutes, 5,000 newly saved items and 2,000 scrolls per explicit start/resume. Grok can configure up to four hours and 10,000 scrolls. The collection has a separate 5,000-item storage ceiling. Existing small plans remain readable; a request to continue broadly can enlarge only their execution limits while preserving identity, categories and saved progress. A limit, source change, uncertain action, login requirement, repeated wait, stall or model uncertainty pauses the job with its saved evidence. A stall is not proof that the entire archive was collected. A service restart requires explicit Resume.

Chat remains available during a background collection for reasoning, progress and document work. The collection retains its job tab. The user can browse other tabs on the new background-capable host. Agent browser navigation tools still wait until the collection is paused or stopped. The UI presents saved/review counts, an activity indicator and Pause/Stop/Open; diagnostics are expandable. Grok gives a short confirmation instead of duplicating the card.

The agent workspace lives in `~/.jet-browser/workspaces/<conversation-id>/`. `scratch` and `artifacts` contain immutable files written through finite list/read/write tools. Each write creates a new file identity; earlier versions remain available. Supported formats are Markdown, plain text, JSON, CSV and static HTML. Files and the index are private to the OS user, scoped to the current conversation, and bounded in size. Automatic provider context includes metadata only; an explicit workspace read supplies document content to Grok.

Workspace opens beside the same chat. Markdown renders in the Flutter pane; other text is selectable. Opening an artifact in a browser tab uses a short-lived preview capability rather than a bearer token or a general filesystem server. The HTML preview is sandboxed, with scripts, external resources and forms disabled. Opening another tab manually does not stop a collection on a background-capable host. This does not add an arbitrary terminal or filesystem tool to the provider.

## Verification

267 backend tests (including 11 real Chromium DOM tests), 46 Flutter tests, Ruff and Flutter analysis passed; macOS release built. The final source-pinned record is [background job verification](background-job-verification-20260928.json).

A single real SemIf + isolated Chromium feed run saved 15 unique synthetic posts over 14 scrolls in 10.07 seconds, with two local progress decisions and zero Grok calls. Fourteen posts were classified and one was retained for review. This is an integration diagnostic, not a human-scored accuracy benchmark.

Direct finite-choice progress wording fixed a failed first prompt that reused topic categorization. SemIf matched all six curated states (ready, ready after a batch, loading, rate limit, login, error); warm inference was 113–133 ms. LFM 350M matched only the loading case on this prompt and is not the default feed supervisor. No hidden larger-model fallback occurs for an explicit LFM request. This six-case set is a diagnostic, not held-out calibration.

The real Grok ACP chat created an HTML artifact and scratch note in a separate test conversation; the HTML preview rendered in Jet. The original conversation and its 50 saved posts were preserved. The UI folds intermediate job narration into expandable steps while retaining it in history. The workspace guide is saved in the original conversation.

Limits: 200 KB per document, 500 files / 50 MiB per conversation; the current list shows the latest 100 files. HTML previews are static and expire after 10 minutes. Job time/item/scroll budgets apply to each explicit start/resume; the 5,000 saved-item ceiling is cumulative. Jobs stop on service restart, host loss or source changes and do not restore an assumed archive cursor. No archive completeness or human-scored categorization accuracy claim is made.


Replay the explicit model/browser diagnostic (requires the local SemIf model and development dependencies):

```sh
backend/.venv/bin/python scripts/probe_background_feed.py --chromium /path/to/chrome-headless-shell --output /private/tmp/jet-feed-proof.json
```

The harness uses a temporary Chromium profile, fulfills document requests with synthetic HTML, persists the outcome before failing acceptance checks, and never opens the user account. `--help` does not load a model or launch a browser.


The guided code review is in the existing clankstamp tour. Open it with `clankstamp open run_20260924_002021_jet-browser --step step_016` from this project. The checkout has no first commit, so the review records source hashes and an empty base SHA rather than inventing one.
