# Jet Browser — standalone first version

## Objective

Create a separate, runnable macOS browser in this repository. The browser has its own Chromium profile, custom tabs/address bar and ONE agent chat interface. Local browser tasks are tools invoked by that main agent and appear as inline activity/results in the same conversation, not a separate local chat or task composer. Grok Build CLI supplies general chat/research and can delegate bounded browser tasks to the same local finite-choice models tested in the Jev demo. The app has no runtime dependency on the vten IDE or its daemon.

The user selected Grok Build CLI first. Codex and Claude adapters remain future work rather than simulated integrations.

## UI requirement (user clarification)

Use vten's actual `shadcn_flutter` design system, independently vendored at `vendor/shadcn_flutter` with its license and source provenance. The chat transcript, composer, tool rows, and 2026 dark theme are an independent fork at `vendor/vten_chat`, copied from the local vten UI and adapted only at the host boundary. The standalone app resolves those local paths. No runtime link to vten.

The main composer enters one shared, local-first conversation. A dedicated SemIf/Qwen 4B router first classifies the request: supported browser/application commands run locally, while reasoning/research or an unsupported local flow hands off to Grok with the actual context and partial results. Settings select the page-action model separately. A single Stop control cancels routing, Grok and any delegated browser task. Direct local-task APIs remain developer/testing interfaces.

Default to a high-contrast dark shell, following vten's GUI agent chat: readable body text, distinct user/assistant hierarchy, Markdown headings/lists/links/code blocks, copyable code, and inline browser-tool progress. Links open in the same browser. The local practice page also uses a dark palette; ordinary websites retain their own appearance.

## Architecture and provenance

- Native Flutter shell uses the independently reusable `flutter_cef_browser` package from vten's CEF submodule at `a14b590260a0ed334a7a089db0f733f5818bc0c9`. Copy required native assets independently, preserving licenses.
- Source vten checkout: `cc497919140469d58c71849f44210e35c3206766`. No source checkout is modified.
- Python sidecar owns chat sessions, a serialized task queue, run identity, cancellation, traces and authenticated native-browser requests.
- Durable sessions retain messages, routing decisions and task evidence across restarts. Both the local router and Grok receive bounded relevant history; old page observations are explicitly historical. Switching sessions never replays actions.
- Local application actions cover browser tabs, back/forward/reload, explicit URL navigation, search discovery and observed page tasks. A small local text helper extracts query text; it does not generate selectors or arbitrary code. Unsupported or ambiguous requests hand off with a visible reason.
- Grok uses ACP `grok agent --no-leader stdio`, per-session MCP configuration and streamed updates. A private stdio MCP adapter exposes finite browser tools.
- Local model/controller code is extracted from the existing Jev Ultrafast worktree, base `1231850a0bf1a0c0341fe408ef1668dbbfdfac46`, including its uncommitted tuned controller. Preserve copied-source hashes in provenance.
- Native browser observation/input uses the exact app-owned tab through the CEF controller. Remote debugging remains disabled. The private host bridge accepts code-owned operations only from the authenticated sidecar; these are never exposed as unrestricted model tools.
- Sidecar and local model processes start outside the CEF process. Provider sessions and model inference are separate from the native app.

## Commands and structure

`scripts/setup.sh` prepares dependencies; `scripts/start.sh` launches sidecars then the app. `uv run --project backend pytest backend/tests` tests Python behavior. `cd app && flutter test` tests the shell; `flutter analyze` and `flutter build macos --release` validate it. Final executable commands are verified and recorded in README.

`app/` contains the browser shell. `backend/jet_browser/` contains the service, private browser bridge, models and MCP adapter. `vendor/` contains copied independent libraries with provenance. `docs/` explains architecture and limits; `tasks/` tracks implementation. `.runtime/` stores private run state and the persistent browser profile, and is ignored.

## API contract

Every request except an identity-only health check requires a per-install bearer token stored in `.runtime/token` with owner-only permissions. Loopback binding only. Reject foreign Origin/Host values.

- `GET /health`: application identity/readiness only.
- `GET /state`: current chat messages, activity, task status, installed models and browser tabs.
- `GET /traces?turn_id=...&limit=2000`: retained events for the selected conversation only, with timing/error summary. Defaults to its latest turn.
- `GET /metrics`: authenticated process-lifetime counts/errors and bounded rolling latency percentiles; no content or high-cardinality labels.
- `POST /chat` `{message}`: start local routing and one bounded conversation turn; streamed results appear in state.
- `POST /sessions` `{}`: create/select a new conversation when idle.
- `POST /sessions/select` `{session_id}`: restore one known conversation when idle.
- State adds `session`, `sessions`, and `routes`; messages identify `source` as `local` or `grok`.
- `POST /chat/stop`: cancel the current turn.
- `POST /tasks` `{goal, model, tab_id?}`: run a bounded local browser goal on an observed tab. Default to current selected tab. Return task id.
- `POST /tasks/stop`: cancel future actions after any in-flight input.
- `POST /browser/sync` `{host_id, active_tab_id, tabs:[{id,url,title}]}`: register/heartbeat the exact visible app tabs.
- `GET /browser/commands?host_id=...`: private long-poll for one native request, with command id and tab id.
- `POST /browser/results` `{host_id,command_id,result?,error?}`: return a native request result once.

Native commands: evaluate a code-owned expression, capture a screenshot, navigate, native pointer/key/text input where supported. Requests have deadlines and unique ids. Host loss or tab replacement prevents later dispatch. The Python bridge preserves stale-document checks.

Public MCP tools: list tabs, open a URL, read current page, run a local browser task, read task status/result and stop. Results include actual page evidence and model/helper timings. DONE is reported as model completion; custom tasks are not labelled independently verified without a checker.

Additional MCP tools: `browser_action` takes a finite application action plus an observed tab id; `conversation_history` retrieves bounded relevant history from the current session. Neither exposes raw browser protocol or code execution.

## Style and boundaries

Use small typed functions and explicit errors, e.g. `submit_task(goal: str, model: str, tab_id: str) -> Task`. UI wording describes actual observed behavior. Keep source evidence separate from conclusions. Retain blocked/error outcomes and no hidden larger-model fallback.

Always validate observed target identity and cancellation before mutations. Never retry a mutation or let page text alter agent permissions. Grok browser-tool permission requests follow the user's explicit task scope; unrelated requests are surfaced or denied, never globally auto-approved.

Keep setup reversible, reuse installed model caches where practical, and provide reproducible bootstrap steps. Publishing, global CLI configuration and production distribution are outside this first version.

## Acceptance and testing

1. Standalone app builds, launches and navigates a normal page with custom chrome; vten can be closed.
2. Grok streams a real chat response through the app's own session.
3. Grok can call a task-level browser tool, the selected local model/helper acts on a local form, and Grok receives the observed result.
4. The UI has one chat composer. Local browser tasks appear as tool activity/results in that conversation; stop and competing-run behavior are tested. A direct local-task API is retained for developer checks.
5. No runtime source imports point into vten or the original oui experiments; large external cache paths, if used, are explicit and replaceable.
6. Tests exercise bridge identity/deadlines, cancellation and action preservation, ACP streaming/error/tool permission handling, plus a real native-browser smoke test. Preserve the live trace.
7. README states which providers/models actually ran and any remaining limits.
8. The Wikipedia-page request completes through the local route with zero Grok calls, with observed URL/title evidence and timing. General research still reaches Grok.
9. Follow-up navigation, session switching, restart restoration and Grok's understanding of prior local actions are tested. Routing and local execution share one inference owner and cannot race.
10. Routing, provider permissions, model/helper work and native input dispatch/acknowledgement share a turn identity. Rotated private diagnostics exclude content and credentials; an induced failure can be located through its trace.
11. The chat renders the vendored vten transcript, divider, composer, tool rows, and 2026 dark theme. It retains manual scrolling and exposes diagnostics from a header action without adding a second chat interface.

## Intent completion and local-first audit — 2026-09-24

Search must distinguish an actual destination from an explicitly requested results list. It checks the original request against observed page evidence, records exact evidence separately from semantic model assessments, follows only observed links through bounded candidate batches, and preserves Stop/stale-document/no-mutation-retry behavior. This checker does not establish generic form completion. See [completion behavior](intent-completion.md).

The [local-first audit](local-first-agent-audit.md) maps all 18 official Jev cookbooks. The next increment implements typed navigation goals for search and explicit URLs, direct known-site homepages without query extraction, and YouTube channel/video/playlist/results checks. Current visible content and canonical identity must agree before the local model assesses the subject; a model assessment is recorded separately from structural proof. See [navigation goals](navigation-goals.md). General form completion, GitHub repository/release workflows, extraction and calibration remain follow-on work.

## Desktop usability and test harness

Keep the vten chat instance mounted while resizing or hiding it so drafts and transcript position survive. Offer editable examples only when there is no draft. History supports title search; busy state blocks duplicate submissions and retains Stop. Current-turn progress names the requested destination and distinguishes checked structure, model assessment, stopped work and manual verification.

The explicit native harness owns its QA session, tab and turn. It checks the actual final URL/title/heading independently of route success, retains partial failures, stops only its own turn, and yields on user takeover. Neither import nor --help contacts a provider or reads a token. See [UI and harness audit](ui-ux-audit.md).

## Chat reference and hybrid-loop scope — 2026-09-28

The user selected Orca and T3 Code as interaction references while retaining Flutter, locally vendored shadcn/vten chat, one conversation, and Grok Build ACP. The [pinned source audit and design](chat-and-hybrid-loops.md) defines the extension; the broader roadmap remains planned; website/feed collections and the agent workspace are now implemented as described below. Compact grouped activity, stable composer/scroll, focused questions, and a collection view beside the same chat take priority over exposing model internals.

Grok may create a validated finite collection plan; local decision models perform repeated classification/selection while code owns discovery, deduplication, durable checkpoints, budgets and stopping conditions. Website collection stays inside a declared scope; bookmark organization defaults to a Jet collection. Source writes are a separate supported task. Completion distinguishes exhausted observed scope from capped/stalled/blocked partial work. Generated workflow JavaScript is now permitted only through the isolated JetWorkflow SDK described below. Arbitrary page code, model selectors, extra chat and desktop takeover remain excluded.

Acceptance and implementation children are [U01–U03/H01–H08](../tasks/chat-loop-work-items.md). They extend the existing browser task loop and B13/B18 plans rather than introducing another executor. Context shared with remote Grok remains explicit and bounded; local-only supplied-taxonomy processing is a defined mode.

## Website collection first slice — implemented

See [collections](collections.md) for current behavior and verification. Service state includes session-scoped collection summaries. The exact finite MCP tools are `prepare_collection`, `start_collection`, `collection_status`, and `control_collection`. Authenticated local routes provide `GET /collections/{id}`, `POST /collections/{id}/control`, and `GET /collections/{id}/export?format=csv|markdown`. The native browser content area switches to a collection workspace while the same chat remains available. Source text is stored locally and is not included in automatic MCP status results. X/bookmark ingestion now uses the guarded feed adapter; the wider Browser Lab remains future work. See [feed collections](feed-collections.md).


## Continuous local jobs and agent workspace — implemented

See [background jobs and workspace](background-jobs-and-workspace.md). Feed plans now support long, configurable time/item/scroll budgets, periodic finite local progress review, same-identity limit changes on explicit resume, and saved per-post checkpoints. A background collection retains ownership of its source tab while the user can browse other tabs and the same chat can answer questions and create documents. Agent browser jobs remain serialized. The default for new feeds is tested local SemIf 4B; explicit model choices are preserved.

Finite `workspace_list`, `workspace_read`, and `workspace_write` tools expose private per-conversation scratch/artifact files under `~/.jet-browser/workspaces`. Authenticated `/workspace` routes support the Flutter pane. The exact `/artifacts/view/{token}` route is a separate short-lived capability preview: no bearer token in its URL, no general filesystem access, strict Host/Origin checks, CSP sandbox, no scripts or external resources. It joins `/health` and the local `/fixture` as an intentional bearer-auth exception.

## Agent-supervised feed checkpoints — implemented

[Supervised collections](supervised-collections.md) add a first-ten checkpoint, bounded Grok review, user escalation and same-collection category/field revisions. Authorized samples are at most five 400-character excerpts per checkpoint; full collections remain local. Automatic review has a restricted ACP profile and cannot authorize itself, switch conversations or renew user budgets. Native cards show counts, elapsed time, sample rows and continuation controls. Existing labels retain taxonomy versions; missing metadata stays missing.

## Tab-bound execution and portable workflow direction — 2026-09-28

[Tab-bound jobs](tab-bound-jobs.md) implement background collection DOM execution, quiet tab status, exact-post expansion/recovery and audited evidence replacement. An embedded JavaScriptCore helper is bundled as the first workflow-runtime foundation. Grok-authored workflow lifecycle and the self-contained local app bundle are implemented. Native relocated browser acceptance and production distribution signing remain open. This historical foundation has now been integrated: [portable workflows](portable-workflows.md) records the current product contract, bundled runtime, setup UI and real Grok acceptance.


## Portable agent-authored workflows — implemented

Grok creates versioned JavaScript with `save_workflow`, runs it in the background, inspects authorized checkpoint samples, repairs tags/summaries and revises the same workflow before resuming. The local SDK covers guarded feed observation/scrolling, exact-post recovery, local decisions/multi-tagging/summaries, durable records and checkpoints. Scope, model and original budgets cannot be increased by revision. Taxonomy and source may change while paused; historical records retain original evidence and audit history. Stop fences further dispatch.

The native launcher starts a bundled relocatable controller before exec into Flutter/CEF. Bundled model dependencies, Grok CLI and Apple's JavaScriptCore remove end-user language/toolchain installation. Pinned model downloads and Grok device login are exposed in the same application; data lives under `~/.jet-browser`. Setup appears before browser initialization. A local ad hoc package is built; Developer ID/notarization and another-machine native validation remain release work.

Acceptance includes real Grok authoring, a two-record checkpoint, audited summary correction, revision and a third local record; isolated real Chromium and all four packaged local inference engines were exercised. See [current evidence](portable-workflows-verification-20260928.json). This does not complete the paused real top-100 bookmark job or prove archive-scale accuracy.
