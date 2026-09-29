# Website and feed collections in Jet Browser

Implemented 2026-09-28 with Grok Build source generation and independent review/tests. The website slice now also has an observed feed/X Bookmarks adapter. See [feed behavior, failure audit and live evidence](feed-collections.md). One chat remains the control surface.

## Try it

Quit Jet when it is idle, then load the new app and sidecar:

```sh
cd /Users/sebastian/Developer/Projects/jet-browser
./scripts/start.sh --restart-service
```

The launcher refuses to restart an active task. Navigate to the website section you want to organize. In chat, ask:

> Collect the linked pages in this website section, up to 10 pages. Categorize them into Pricing, Documentation, Support, and Company. Use SemIf for classification.

Grok prepares a fixed taxonomy and a bounded plan through `prepare_collection`, then starts the local loop. The active observed tab supplies the seed URL. You can name LFM, SemIf, or Laya explicitly; otherwise the existing local-model setting is used. This change does not silently change that setting.

A single collection card stays in the originating chat turn. Open it to see results beside the same conversation. Search, filter by category or Needs review, inspect captured text and model details, open sources, or copy CSV/Markdown. Pause finishes the current item; Resume continues saved work. Stop prevents subsequent dispatch and retains committed results. Opening a source or manually switching tabs is user takeover and can pause the loop.

## What executes

1. Grok describes the requested categorization once using 1–8 fixed categories. The backend validates the request, model, exact origin, section path, active observed tab, and page/time budgets.
2. The code-owned collector reads visible page text and observed links in scope. It follows each canonical URL once within the budget. It never accepts model-generated JavaScript or selectors.
3. The selected local model chooses a category or Needs review. The prompt receives at most 1,200 characters (500 for Laya Typed). Results record the actual returned model identity, excerpt length, nullable confidence, and inference timing.
4. SQLite atomically saves each item and discovery checkpoint. A restart pauses unfinished runs; explicit resume reobserves a pending page without replaying its navigation.
5. Grok receives bounded status and counts. Collected source text stays in the authenticated local workspace; it is not automatically sent back to Grok per item.

The default budget is 10 pages / 90 seconds; hard limits are 50 pages / 120 seconds. “Completed” means the observed in-scope link frontier was exhausted. Page/time limits and truncated capture yield partial results. This is not a promise to enumerate an entire website.

## Model diagnostic

Twenty synthetic snippets, one fixed four-category taxonomy, the same classifier, and installed local weights. These are development diagnostics, **not held-out accuracy or browser success rates**.

| Model | Expected category/review matches | Warm call median |
|---|---:|---:|
| LFM RLCD 350M | 8 / 20 | 43.91 ms |
| SemIf Qwen 4B | 18 / 20 | 94.27 ms |

Warm call median excludes the first model-loading call and the empty-input shortcut. SemIf's two misses abstained as Needs review. LFM's faster answers were substantially less reliable on this taxonomy; prefer SemIf for this initial categorization use case. Confidence is not invented for label-only models.

[Full synthetic results](collection-model-diagnostic-20260928.json) retain every case, model identity and timing. Reproduce explicitly from the project root:

```sh
backend/.venv/bin/python scripts/probe_collection_models.py
```

The probe uses local weights only, creates a new timestamped private report, and does not operate a browser. It is intentionally separate from ordinary unit tests.

## Verification and limits

Independent tests cover bounded plans; scope/canonicalization; private, session-scoped persistence; atomic commits; graph deduplication; exact budget completion; pause/resume; Stop before startup and during inference; service restart; model failure; invalid records; authenticated routes; exports; and planner routing. UI tests cover stable turn identity, compact completed steps, result virtualization, narrow layouts, refresh races, stale session data, and native-view visibility with mocked channels.

The initial website slice was verified offline. Subsequent feed work has live native and Grok-resume evidence: [feed verification](feed-collections.md#evidence). These feed runs do not prove complete coverage of arbitrary websites.

Current limits: no arbitrary field extraction, category editing/reclassification, guaranteed archive coverage, or automatic final research synthesis. X Bookmarks and generic permalink feeds now support bounded scrolling and per-item chunking; the website classifier still uses a bounded excerpt. The displayed excerpt coverage matters: a label may reflect only the beginning of a longer capture. Model agreement is not independent factual verification. Broader cookbook/lab benchmarks remain planned.

Eight actual SemIf routing probes also selected the expected local/Grok lane: four collection requests went to Grok planning; YouTube, Back, tab listing and Wikipedia remained local. No browser action or provider call was executed. [Per-case routing results](collection-route-diagnostic-20260928.json).

## Guided review

The existing local clankstamp tour includes the chat, loop runtime, integration and verification. From this project, open it with `clankstamp open run_20260924_002021_jet-browser --step step_012` when desired. It was not opened automatically. Strict validation reports zero errors and one existing warning: the repository has no first commit, so `repo.base_commit` is empty. No commit was created just to suppress that warning.
