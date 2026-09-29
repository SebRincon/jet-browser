# Tab-bound jobs, post recovery and embedded workflows

Updated 2026-09-28. Source and tests are implemented; the open Jet instance was deliberately left running on its previous binary. The newly built app and sidecar must both be restarted before background-tab support is available. No live-account background recovery was claimed.

## Working on one tab while the user browses another

Collections claim a specific observed tab for each run. The native host advertises `background_tabs`; older hosts keep the previous active-tab rule. Tab switches do not revoke the claim. Collection DOM reads, guarded scrolling and scoped website navigation dispatch to that exact tab. Native pointer, keyboard and screenshot tasks remain foreground-only. The application still serializes agent browser jobs; this change allows manual browsing on other tabs, not multiple concurrent model jobs.

The existing CEF native views remain alive while hidden. Background detail tabs are created outside the visible viewport and kept hidden without selecting them. This is DOM execution in an existing native-view browser, not a new off-screen screenshot renderer. Hidden-page throttling and long-duration behavior still need native endurance testing.

The collector continues to check tab identity, host identity, document, URL, source, scroll target and Stop. Navigating the owned source tab, closing it, replacing the host, or revoking ownership prevents subsequent work. Claims are released on completion, pause, stop and startup failure. Revoked queued commands cannot dispatch. A user may select the job tab to watch it; navigating that tab changes its source and stops the job.

The tab strip shows an agent badge. Its tooltip includes the job title, saved and categorized counts, elapsed time and state. The selected tab also shows a compact status row with saved count, elapsed time, Pause, Stop and Details. The badge supports keyboard activation. Existing collection cards retain the fuller progress and review information.

## Recovering incomplete post evidence

`recover_collection_item` operates on an exact saved post in a paused X Bookmarks collection. It opens that numeric status URL in one temporary tab, reads the matching main post, and may click one observed Show more control. Main author and date exclude quoted/reply metadata. Expansion checks the old text, URL and document identity before dispatch. It does not click unrelated controls or retry a mutation.

On background-capable hosts, recovery preserves the user's foreground tab. Cleanup closes only its own inactive detail tab; if the user selects that detail tab, it stays open. Stop prevents later browser mutations, including cleanup. The old-host path still requires the feed in the foreground and restores it only when safe.

Recovered evidence is reclassified locally and saved atomically with the original capture, previous hash and recovery metadata. Session scope and expected-hash checks prevent stale edits. Automatic Grok checkpoint review can repair up to three sampled items; its tool output contains status/counts, not full recovered text. Access to small review samples follows the user's existing authorization.

Unavailable, deleted, restricted and ambiguous targets retain explicit blocked outcomes. This capability does not eliminate all needs-review results. It is not yet automatically invoked for every incomplete item within the feed runner.

## JavaScript workflow runtime: now integrated

`native/JetWorkflow` embeds Apple's [JavaScriptCore](https://developer.apple.com/documentation/javascriptcore). The release build now includes `Contents/Helpers/JetWorkflow`. That helper executes JavaScript without Node, Python or Lua. Each invocation has a fresh context and exposes only `jet.input` and `jet.call(name, arguments)`.

The parent controller supplies explicit handlers. There are no page DOM, network, shell, process or filesystem globals. Source, RPC payloads, call count and wall time are bounded; Stop kills the helper process. This isolates the available JavaScript API, not the operating system or a JIT exploit. A workflow does not gain browser permissions from page content or generated code. The sidecar launches the helper; the CEF application process must never fork after initialization.

The initial helper foundation is now connected to Grok workflow tools, versioned storage, local multitagging/summaries, exact-post recovery, checkpoint reviews and audited correction. The app bundles the controller/model runtimes and Grok CLI, with model downloads and login in the setup view. See [portable workflows](portable-workflows.md) for the current contract and real Grok acceptance. The implementation sequence previously listed here is complete; clean-account native acceptance and production signing remain open.

## Bookmark organization state

The current user collection is paused with 50 saved posts. The requested top-100 job is unfinished, and the original source tab was navigated away from. It was not resumed after the user asked to stop.

An operator-only local enrichment script adds overlapping tags and concise summaries to already-saved records and can publish HTML/CSV/JSON into the agent workspace. Ten saved posts were enriched locally. The tagging uses local SemIf 4B; summaries use the local 4B text model. The temporary summary server was shut down while the job is paused. That older operator script remains separate from the collection schema. The new Grok workflow path provides native multitag/summaries and durable records; it has not migrated or resumed this user collection. No X bookmark/folder writes were performed, and no top-100 report was published.

## Verification and remaining limits

The backend suite passed 310 tests with isolated Chromium DOM checks enabled. Cases cover inactive-feed reads/scrolls, revoked ownership, lease cleanup, source identity, exact post expansion, temporary-tab cleanup, audited repair and JavaScript deadlines/capabilities/Stop. Flutter tests cover dispatch to exact inactive tabs, rejecting background native input, status controls, keyboard activation and responsive layouts. See the companion source-pinned verification record for final shell/build counts.

The bundled helper was invoked directly from the app bundle with only `/usr/bin:/bin` in PATH and correctly reported absent Node/page globals. Native CEF background operation on the user's X account has not been tested because the live browser was intentionally left untouched. The newer packaging and workflow-authoring verification is in [portable workflows](portable-workflows.md); native background endurance remains open.

Review: `clankstamp open run_20260924_002021_jet-browser --step step_020` from the repository.
