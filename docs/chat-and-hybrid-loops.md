# Chat reference audit and on-demand collection loops

> **Implementation update 2026-09-28:** The first website collection and chat slice is now implemented. See [current behavior and evidence](collections.md). Bookmark collection, broader lab coverage, and live native acceptance remain open. The design below includes future work.

2026-09-28. **Source audit and proposed design; not implemented or visually verified in the running app.** This extends the [active plan](../tasks/plan.md), keeping Flutter, local shadcn/vten chat and Grok Build ACP. [Exact source pins](../tasks/chat-loop-reference-audit.json) record 16 inspected implementation/license files. No upstream code was imported and no desktop-control tool was used.

## Product outcome

Jet is a browser with one capable assistant. The user asks for a result; the assistant can navigate, collect source information, organize it, and explain it. Grok handles broad intent, new plans, category definitions, synthesis and difficult exceptions. Narrow local-model calls handle repeated matching, classification, selection and checks. Code schedules and validates the loop, persists its progress and enforces the user's scope.

Existing local navigation stays fast and does not require Grok to plan every click. A novel collection job can ask Grok for a finite plan once, run many local steps, then return a compact result or unresolved question. Category definitions and loop settings are editable through the same conversation.

## What the two references actually do

Orca at `aedb9305cd1b3de859b5eafc1ee0d77fa0df8963` is not only a terminal wrapper. Its source includes both PTY-oriented and structured native chat paths. T3 Code at `d15210cd3da79f9a1a495a6309d912d76362a046` has a GUI transcript/composer architecture. Both are MIT at the inspected revisions; preserve notices if implementation is adapted. Their React/Electron components cannot be dropped into Flutter verbatim.

| Inspected source | Evidence | Jet adaptation |
|---|---|---|
| [Orca NativeChatComposer](https://github.com/stablyai/orca/blob/aedb9305cd1b3de859b5eafc1ee0d77fa0df8963/src/renderer/src/components/native-chat/NativeChatComposer.tsx) and [structured session](https://github.com/stablyai/orca/blob/aedb9305cd1b3de859b5eafc1ee0d77fa0df8963/src/renderer/src/components/native-chat/NativeChatStructuredSession.tsx) | Composer is scoped to the pane and wired to a transport; structured questions and session state are separate from presentation | Keep ACP as transport, bind one composer to a session/run, and render pending questions as structured UI |
| [Orca tool runs](https://github.com/stablyai/orca/blob/aedb9305cd1b3de859b5eafc1ee0d77fa0df8963/src/renderer/src/components/native-chat/NativeChatToolRun.tsx) | Tool sequences collapse to a short summary; live state follows the turn rather than flickering between calls | One stable activity row per operation/batch; completed detail folded, failures discoverable |
| [Orca message list](https://github.com/stablyai/orca/blob/aedb9305cd1b3de859b5eafc1ee0d77fa0df8963/src/renderer/src/components/native-chat/NativeChatMessageList.tsx) and [autoscroll](https://github.com/stablyai/orca/blob/aedb9305cd1b3de859b5eafc1ee0d77fa0df8963/src/renderer/src/components/native-chat/native-chat-autoscroll.ts) | Windowed history, explicit reader-follow intent, older history and jump navigation | Preserve the reader's position and disclosure state; paginate old events and virtualize long collections |
| [Orca Grok transcript decoder](https://github.com/stablyai/orca/blob/aedb9305cd1b3de859b5eafc1ee0d77fa0df8963/src/main/native-chat/transcript-line-decoders-grok.ts) | Normalizes Grok user, assistant and tool records and filters bootstrap context | Borrow the principle of typed events; keep Jet's existing live ACP path rather than parsing terminal screens or tailing private files |
| [T3 composer surface](https://github.com/pingdotgg/t3code/blob/d15210cd3da79f9a1a495a6309d912d76362a046/apps/web/src/components/chat/ComposerSurface.tsx) | Composed shell, context and attached surfaces | Stable composer with a compact current-page/selection context strip; use existing dark tokens |
| [T3 primary actions](https://github.com/pingdotgg/t3code/blob/d15210cd3da79f9a1a495a6309d912d76362a046/apps/web/src/components/chat/ComposerPrimaryActions.tsx) | State-specific Send, Stop, queued-message and question actions | Keep Stop obvious; enable queued follow-ups only when the backend supports boundary-safe application |
| [T3 timeline anchoring](https://github.com/pingdotgg/t3code/blob/d15210cd3da79f9a1a495a6309d912d76362a046/apps/web/src/components/chat/timelineScrollAnchoring.ts) | Separate following, new-turn anchoring and free-reading modes; remember row/offset per thread | Stable layout as Markdown grows, restored session position, no forced autoscroll on a new batch |
| [T3 timeline logic](https://github.com/pingdotgg/t3code/blob/d15210cd3da79f9a1a495a6309d912d76362a046/apps/web/src/components/chat/MessagesTimeline.logic.ts) | Groups work, uses lifecycle-aware labels, preserves expanded-output position | Typed turn projection with one summary for hundreds of classification events |
| [T3 plan card](https://github.com/pingdotgg/t3code/blob/d15210cd3da79f9a1a495a6309d912d76362a046/apps/web/src/components/chat/ProposedPlanCard.tsx) and [question panel](https://github.com/pingdotgg/t3code/blob/d15210cd3da79f9a1a495a6309d912d76362a046/apps/web/src/components/chat/ComposerPendingUserInputPanel.tsx) | Plans collapse, questions preserve answers and have explicit progress | Brief scope/plan card and focused ambiguity questions; normal read tasks proceed within their authorized scope |
| [T3 citation source](https://github.com/pingdotgg/t3code/blob/d15210cd3da79f9a1a495a6309d912d76362a046/apps/web/src/components/chat/AssistantCitationSource.tsx) | Saved quote identity and changed-source handling; this is assistant-transcript citation behavior | Adapt identity/freshness handling to browser evidence cards; do not claim T3 already implements Jet's webpage extraction |

Inspection focused on relevant source paths and behavior, not every subsystem or a live visual comparison. The useful borrowings are interaction contracts, compact grouping and state handling. Jet should retain its own design tokens and avoid importing repository/worktree/git controls into the everyday browser.

## Current Jet gaps

- `app/lib/agent_pane.dart` combines event projection, turn grouping, tool presentation, history and settings. It already uses vendored vten widgets. Its `_turnView` keeps tool rows visible for a streaming turn, which will be noisy for a long batch. Extract a typed projection before adding more conditional widgets.
- `backend/jet_browser/tasks.py` is a bounded task executor, not a durable item-processing system. DONE remains `manual_check` for general tasks. Raising its 24-step/90-second budget is not sufficient for a bookmark archive.
- `sessions.py` stores conversations/routes/tasks; it lacks a collection's item identities, frontier, taxonomy versions and item-level checkpoints.
- Existing Grok tools can delegate a page task. They do not define a validated collection plan or bounded resumable foreach loop. H01–H08 add those contracts while extending B13/B18 rather than creating a competing executor.

## Intended everyday UI

Browser remains the primary surface. The assistant is a resizable right pane using the current high-contrast dark vten/shadcn theme. Header: conversation title, history and overflow actions. Diagnostics and model configuration live in overflow/details. The composer shows a removable current-page or selection chip; it does not show an engine taxonomy by default.

The transcript contains the request, a short useful reply, one current job row/card, and results. Actions expand inline. A collection opens in a browser-area workspace view with search, categories and source-linked items, leaving the same chat beside it. Lab lives behind an optional entry rather than occupying the normal chat screen.

Illustrative content below is a design example, not recorded results:

```text
You       Organize my bookmarks into useful categories.

Assistant I'll collect the saved posts into a Jet collection and
          group them by topic. I'll keep uncertain items for review.

          Organizing bookmarks                         Pause  Stop
          143 collected · 131 categorized · 12 to review
          Reading more saved posts…                    Details ▸

          AI development  46    Design  32    Research  28
          Other categories…                            Open collection

          [Current page: X bookmarks ×]
          Ask a follow-up…                             Send / Stop
```

Counts derive from committed records and are illustrative here. If total source size is unknown, display counts and current activity, not a fake percentage. Completed job shows the actual scope and stop reason. The source of work (Grok/local model) is available in details; no separate identities or composers are introduced.

The composer stays mounted, preserves drafts per session, handles IME correctly and exposes accessible actions. Streaming updates neither move focus nor pull a reader back to the bottom. Pending questions are tied to their run/revision. Follow-ups while busy are visibly queued and applied at the next safe boundary only after H04 supports it; until then preserve the draft and existing Stop semantics. Never imply queued text has already changed the running plan.

## Hybrid loop contract

Grok defines a bounded program using registered operations, not executable Python/JavaScript, generated selectors, or an unbounded shell loop. The model can choose operations and propose category descriptions; code validates types, capability, scope, budgets and target identity before execution.

```text
Request → direct local skill, or Grok prepares a collection plan
        → code validates scope + fields + categories + limits
        → discover a batch of observed unique records
        → extract exact source fields
        → classify with a pinned taxonomy and local model
        → persist evidence, result and checkpoint
        → continue discovery until an explicit stop condition
        → Grok summarizes or resolves bounded exceptions when needed
```

Registered operations initially: discover observed links/items; read a bound item/page; extract declared fields; classify against a taxonomy; filter/deduplicate/sort/group in code; save a record; advance a cursor/scroll; verify a predicate; request missing input; ask Grok a bounded question; summarize collected evidence. No arbitrary recursion or generated workflow node types. Browser actions are sequential; only independent classification work may batch within adapter limits and hardware ownership.

Proposed additive records:

- `CollectionPlan`: original request, plan revision, source adapter, source scope, destination collection, requested fields, taxonomy version, single/multi-label mode, permitted operations, stop predicates, page/item/time/provider budgets and evidence requirements.
- `CollectionItem`: collection/account-scope identity, stable source ID/canonical URL, observed content/version, captured field spans, label IDs, taxonomy/model/prompt revision, assessment/abstention and processing state. Do not use a virtualized DOM row index as identity.
- `Checkpoint`: run/plan revision, visited and pending source IDs, cursor hint, processed-item keys, per-item outcomes, failed/unknown operations and completion reason. Cursor is a hint to reobserve; never replay stale element handles.
- `RunEvent`: monotonically sequenced run/turn/step/item IDs and typed lifecycle events. The transcript reduces events into compact activity; the collection retains individual records. Reconnect requests events after a sequence and deduplicates them.

Source content remains untrusted data and cannot change category rules or action permissions. Authorization belongs to the existing code/task scope. A new plan revision cannot silently expand origins, record count, write actions or spending. A model or taxonomy outage pauses with retained progress rather than silently swapping models or inventing labels.

Lifecycle: prepared → running → pausing → paused / needs-input / needs-reasoning / completed / partial / failed / cancelled. Stop cancels future dispatch; an already acknowledged action may finish. Pause checkpoints at an action boundary. Resume revalidates the source and skips committed item/version keys. Recovery may reread/reclassify; it never automatically repeats a site mutation with unknown outcome. Do not promise exactly-once external side effects across a crash.

## Bookmark organization walkthrough

1. Use the account/profile already selected by the user in Jet when they start this real task; never silently switch accounts or clone cookies. Lab tests use a synthetic bookmark site in the isolated lab profile. A login wall is a specific blocker; the user signs in through the normal page.
2. Default destination is a **Jet collection**. The instruction organizes captured references locally; moving/deleting bookmarks or changing X folders is a separately supported mutation flow. Do not claim X folders were changed by local categorization.
3. If categories are supplied, preserve them. Otherwise Grok proposes a small editable taxonomy from a bounded representative sample/summary. A local-only mode can use supplied categories without remote content sharing. Make what is sent to a remote planner explicit in context settings and the run details.
4. Collect observed post IDs/links, text, author/time where available, and linked URLs. Preserve missing/truncated/deleted/protected content as such. Do not fabricate the contents of unopened links or images. Quote/repost relationships are distinct from duplicates.
5. The local engine labels batches against fixed category definitions with an uncertain bucket. Multi-label mode uses explicit independent label judgments; mutually exclusive mode selects one label. Adapter limits and null confidence remain honest.
6. Deduplicate by source identity/version, retain capture evidence, and advance the observed list. Virtualized rows, repeated batches, delayed loads, redirects and rate limits require explicit handling. No undocumented/private API dependency is assumed.
7. Stop at an observed end, user-selected scope, budget, stalled discovery or block. A stable screen with no new IDs for a bounded number of attempts is **stalled/partial**, not proof every bookmark was seen. Never invent the total bookmark count.
8. Show editable categories, needs-review items and source links. A taxonomy edit creates a new version; keep old assignments inspectable and reclassify affected records explicitly. Resume uses the same taxonomy/model policy unless a recorded revision changes it.

Useful follow-ups: “Show only browser automation,” “Move these to Design,” “Add a Hardware category,” “Summarize the Research group,” “Continue collecting,” and “Export this collection as CSV.” Local collection edits and source-site mutations are distinguished in the UI.

## Website information walkthrough

Interpret “find all information on this website” as a visible bounded scope card: selected origin/section, field/topic coverage, page/time limit and exclusions. Default to the current origin, readable pages reached through observed links, and a bounded first pass. Code canonicalizes URLs conservatively, preserves meaningful query parameters, recognizes duplicates, and avoids calendar/filter traps. Cross-origin links are references unless included in the user's scope.

Grok can turn the request into requirements such as pricing, features, support, policies and documentation. Local decisions route pages to those requirements, extract exact values/passages, and classify relevance. Code stores a frontier and tracks fulfilled/missing requirements. Grok writes the final explanation from evidence, with unresolved fields disclosed.

The result states “visited 28 discovered pages in this section; 3 inaccessible; limit reached” rather than “everything on the website.” Scope expansion can be requested naturally. Source changes do not overwrite an earlier quote silently. Authenticated content and remote planning context follow the same explicit context policy as bookmark jobs.

## Test and release order

First implement U01's clean turn projection using existing real event types plus clearly synthetic fixtures for future states. Then H01–H05 establish validated plans, collection storage, local classification, resumable execution and Grok delegation. U02/U03 expose supported controls/results. H06/H07 add website and bookmark adapters; H08 proves end-to-end behavior. B01–B10/B33–B34 remain prerequisites where referenced. Existing broader demos stay in the backlog.

Add D21 bookmarks and D22 website collection, taking the catalog to 22 families and the broad corpus target to 440 cases. In addition to ordinary accuracy/latency, measure unique-item discovery recall, duplicate rate, field coverage, classification quality/abstention, recovery correctness, taxonomy drift, Grok calls per 100 items, and total completion claims.

Owned fixtures include repeated/virtualized rows, delayed load, reordering, deleted records, login expiry, partial text, missing source totals, pagination traps, nested links, conflicting categories, page prompt injection, Stop during a batch, process restart and duplicate/out-of-order events. UI checks cover long Markdown/code, 1,000+ items, collapsed activity, scroll preservation, draft/session switching, narrow panes and unavailable sources. Whole-loop oracles are authored independently; a good per-item label does not prove complete discovery.

Primary model comparisons remain hosted Jev, LFM RLCD and SemIf, with Laya variants extended. SemIf/LFM/Laya are separate local engines, not local Jev weights. Measure the whole hybrid run including Grok and helper work; do not multiply a single-label latency by item count and call it measured throughput.
