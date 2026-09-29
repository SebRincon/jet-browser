# Supervised collection loops

Implemented 2026-09-28. This extends [background jobs](background-jobs-and-workspace.md) with an agent review layer; the local finite-choice model still performs repeated classification and scroll decisions.

## Flow

1. Grok prepares one feed collection with the initial taxonomy, local model, scope and finite limits. New feed plans pause after ten saved items. Existing plans retain their behavior until supervision is configured.
2. Each item is saved before checking the review condition. At a checkpoint the local job pauses, preserving its identity, deduplication set and progress. It cannot collect item eleven before the first review is resolved.
3. A single Grok review waits for the chat to become idle. It receives category totals, coverage, classification failure reasons, and, only with permission, at most five excerpts of 400 characters each. It reviews a sample; this is not an independent audit of every label.
4. The first batch and significant classification uncertainty require a user response. Grok can propose new categories. The native card displays a sample table, counts, observed metadata and the question. The user can revise the plan in the same chat, select periodic reviews, or continue locally until a configured limit or blocker.
5. With periodic reviews approved, Grok checks at a default ten minutes of active local execution and may continue if no changes are needed. Continuous mode disables scheduled reviews; uncertainty and source/limit/Stop fences remain active. These modes do not promise infinite execution.

The uncertainty trigger is a control heuristic: at least ten new items since the last review, at least five marked `needs_review`, and at least 30% needing review. It is not a calibrated accuracy score. Reasons distinguish model abstention, incomplete/truncated capture, empty text and other failures. A new topic cannot repair an incomplete source capture.

## Iteration and evidence

`configure_collection` pauses a running feed when needed and updates its existing policy. It can append categories (eight total), change review cadence/mode, set authorized sample sharing, and select fields from `url`, `text`, `author`, `published_at`, and `captured_at`. Source kind, source identity and model remain unchanged. Fields are observed metadata and export/review columns, not arbitrary model-generated extractors. URL and text remain required.

Adding categories increments `taxonomy_version`. Existing items keep their original classification and version; changes apply to future classifications. There is no automatic historical relabeling or metadata backfill. Author names and post dates are read from supported DOM evidence. Missing values are null, and the post date is never replaced by the capture time. The full observed metadata is retained locally; selected fields determine review/export output.

`collection_review` reads a bounded review packet. Remote samples are omitted unless both sharing is enabled and a checkpoint is pending. `review_collection` can ask the user, accept an already-approved periodic interval, or approve an explicit user continuation. Suggested categories are proposals, not mutations. The HTTP control route accepts `approve_checkpoints` or `approve_continuous` plus the exact `review_id`; stale or cross-session approvals fail.

Examples in the shared chat:

- “Organize these bookmarks; show me the first ten before continuing.”
- “Add a category for typography, and include author and post date.”
- “That format looks right. Continue with a check-in every ten minutes.”
- “Keep going locally until you hit the limit; only ask if something needs attention.”

## Ownership and limits

Automatic reviews have their own restricted Grok ACP profile with only tool discovery and use of the collection's two review tools. Native web fetch/search and other browser/workspace tools are unavailable to this profile. The service additionally fences tool identity, collection identity and automatic user approval. Source samples are untrusted data, never authority.

Reviews never overlap a foreground chat turn, browser task or collection. A queued review waits at most 120 seconds; a Grok review has a 90-second timeout. A timeout, malformed/no decision, cancellation or changed conversation leaves a review for the user. A restart never replays a queued review or browser action. Stop cancels waiting/active review tasks and prevents automatic resume.

Time, item and scroll budgets are retained across automatic checkpoint continuations. An explicit user approval establishes the next authorized bounded run. Existing global caps remain: four hours maximum, 5,000 stored items and 10,000 scrolls; default time is 30 minutes. Source identity is rechecked on resume. Reload/restart resumes from the observed feed position, not a guaranteed remote archive cursor.

The consent preference is stored privately in `.runtime/supervision_preferences.json`. The user's consent in this session enabled small checkpoint samples for this installation and the selected collection. Other installations default to metadata-only reviews; each collection can override sharing through an explicit user instruction.

## Verification and limits

- 284 backend tests passed, including 13 real Chromium DOM cases. First-ten stopping, metadata provenance, deduplication, revision preservation, stale approvals, restricted ACP permissions, chat/session races, Stop and total-budget fencing are covered.
- 50 Flutter tests passed; the review card was rendered and inspected at narrow and normal widths. Flutter analysis and Ruff passed. The macOS release built successfully; the existing CEF helper copy-script warning remains.
- The actual local SemIf 4B model plus isolated Chromium saved ten unique synthetic posts in 7.95 seconds (nine categorized, one needing review) and stopped at the first checkpoint, with zero Grok calls. Repeat with `scripts/probe_background_feed.py --supervised --chromium <headless-shell-path>`.
- A live Grok ACP checkpoint reviewed the user's saved 1,102-post collection and returned `awaiting_user`, with all items/counters preserved. It separated 336 abstentions, 336 incomplete captures and five empty excerpts. Author/date fields on historical rows remained unavailable. The native browser reconnected successfully.
- [Verification record](supervision-verification-20260928.json) contains metadata-only evidence. No post samples are included in repository artifacts.

Not established: multi-hour endurance, generic arbitrary-field extraction, expanded-post recovery, automatic historical reclassification, held-out label accuracy, and remote archive cursor restoration. Category additions and fields apply prospectively. The real checkpoint result establishes the agent handoff, not that the 425 assigned labels are all correct.

Review tour: `clankstamp open run_20260924_002021_jet-browser --step step_018`.
