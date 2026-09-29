# Local feed collection and the failed bookmark run

Implemented and tested 2026-09-28. Grok Build generated the product changes; independent review, regression tests and Jet-native runs caught and corrected contract, cancellation, source, extraction and tracing errors. No source account changes or desktop takeover were used.

## Why the old request failed

The retained run accepted an X bookmark request as a website crawl. Grok invoked `prepare_collection` and `start_collection`, but that executor knew only how to follow links. It read two History pages, followed the Likes tab, and reported `observed_frontier_exhausted`. It dispatched no scroll and classified whole page text rather than posts. The tool contract permitted an intent/capability mismatch. A prompt instruction alone did not prevent it.

The old run remains unchanged in the private collection database. Its complete snapshot and trace are retained in `.runtime/artifacts/collection-loop-failure-20260928.json`.

## What now runs

1. `inspect_collection_source` observes the exact active tab, selected archive tab, supported adapter, rendered item count and scroll container. It exposes only capability metadata and observed archive navigation links to Grok. Likes cannot pass the Bookmarks check. Preparing an X archive with the website crawler is rejected.
2. Grok fixes a small taxonomy and selects `source_kind: x_bookmarks` once. The seed comes from the observed browser. Feed plans are schema 2; old website plans remain readable as schema 1. The selected local model stays explicit and has no remote fallback.
3. A code-owned DOM extractor isolates primary post permalinks, tweet text, quoted evidence and meaningful media alt text. It excludes navigation, sidebars, author controls and social counts. Extraction follows the current viewport with overlap, including feeds that retain hundreds of old DOM nodes. The executor finds the actual nested scroller or document root.
4. The local model classifies each unseen post. Longer captures use at most six non-overlapping chunks: 1,200 characters each, or 500 for Laya Typed. Disagreement, unexamined tails, empty evidence and collapsed Show more content become Needs review. Actual model identity, examined characters, calls and timing are saved.
5. Each item, its classification, counters and last-post checkpoint commit atomically to local SQLite. Stable permalinks deduplicate across scrolling, changed text, interruptions and restarts. The executor observes again after inference and before scrolling, preserving host, tab, source, document, scroller and position checks.
6. The loop scrolls once, waits for new DOM evidence, and repeats. A pending-scroll marker is durable before dispatch; an uncertain response pauses and is never replayed automatically. Resume first observes the current view. Pause finishes the current item; Stop prevents subsequent dispatch. Saving progress does not require a Grok call per post.

Feed limits are per pass: defaults 100 items, 30 scrolls and 90 seconds; maxima 500 items, 100 scrolls and 120 seconds. A run stores at most 5,000 unique posts. Budget limits pause with Resume available. Three observations with neither new items nor forward scroll progress pause as `feed_stalled`. Reaching the visible bottom is never proof of full archive coverage. Feed runs do not report completed without an archive-end contract.

## Try it in the one chat

On an observed X Bookmarks page:

> Categorize my bookmarks into Technology, Science, News, Design, and Other. Use local SemIf. Scroll through up to 100 posts and save progress.

Open the collection card to search, filter, inspect source evidence or export the saved posts. The Resume control starts another bounded pass directly. A chat request to continue receives the saved collection ID/status in Grok's context and resumes the same taxonomy. The inspector supplies the observed Bookmarks link when the browser is on Likes.

The backend is live. The updated release UI was built; the existing native window was retained to preserve its session and scroll position. New post/scroll labels load on the next native app restart.

## Evidence

[Machine-readable results and source fingerprints](feed-verification-20260928.json):

- 242 backend tests passed, including 9 real Chromium DOM cases; 41 Flutter tests passed. Ruff and Flutter analyze passed. Release built successfully with the existing CEF helper-copy warning.
- Four bounded native passes saved **35 distinct posts**, made **24 scrolls**, and recorded **35 local model calls**. 29 labels were accepted by the classifier and 6 items require review. These labels have not been independently human-scored.
- Total local-loop time: **42.26 seconds** across four passes, including startup, inference, DOM reads and settling. Median per-item inference: **100.4 ms**. Actual runtime identity: `Qwen3.5-4B@851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`, selected through `qwen4b_semif_shared`.
- Two chat-driven resumes used one Grok prompt each, then local classification. Complete chat turns took 49.73 and 51.28 seconds; this overhead is not hidden in the local inference figure. Tools were list/inspect/history/control/status; no per-post read_page or Grok labeling calls were made.
- The last pass used the same authenticated Resume endpoint as the UI, added five posts in 9.95 seconds, and made no Grok call. It exercised the final viewport cap fix. All 35 saved URLs were unique. The run is paused at its scroll budget, ready to continue.

Traces contain collection IDs, active turn correlation, item/chunk counts, scroll measurements, model identity, timings and pause reasons. Source text and post URLs remain in the private collection store, outside metadata traces. The live test exposed incorrect correlation to the original turn; a regression now verifies that resumed item/scroll events appear under the active turn. Per-pass duration and cumulative elapsed time are separate fields.

Reproduce offline from `backend/` using an installed isolated Chromium binary:

```sh
JET_TEST_CHROMIUM=/path/to/chrome-headless-shell .venv/bin/python -m pytest tests -q
.venv/bin/ruff check jet_browser tests
```

The DOM harness creates a temporary profile and fulfills page requests from local fixture HTML; it does not use an account or a remote provider. Without `JET_TEST_CHROMIUM`, those nine cases explicitly skip. Fixtures cover selected-source identity, quotes/sidebar exclusion, nested scrolling, delayed append, user takeover, document replacement, generic permalinks, login/Stop, collapsed content and long retained DOM lists. Runner/tool tests cover deduplication, fresh resume budgets, atomic failures, cancellation races, uncertain scrolls, private metadata and turn correlation.

## Remaining limits

This is observed browser collection, not an account export API. There is no durable server cursor, guaranteed total, full archive proof or account-switch identity pin. After a page reload, Resume deduplicates saved posts while starting from the current view; it does not pretend to restore an old remote cursor or pixel position. Keep the intended account and feed open. Generic article feeds require stable same-origin permalinks. X's English Bookmarks identity and DOM structure may change; unsupported views pause. Deleted/inaccessible posts, explicit rate-limit diagnosis, category edits, held-out label accuracy and automatic final synthesis remain future work. Better DOM extraction and a deterministic executor address the observed failure; embeddings were not required for this repair.
