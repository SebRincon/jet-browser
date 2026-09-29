"""Vetted workflow sources that Grok configures with a few options.

Writing a full script made Grok's authoring turn long enough to stall (see
docs/incidents/2026-09-28-grok-timeout.md). A template turns authoring into a
small, bounded choice. The rendered source is stored like any other workflow
source, so revisions, read_workflow and the JavaScriptCore runtime are unchanged.
"""

from __future__ import annotations

import json

# Local slices stop starting new items this long before the helper's wall timeout,
# so a recovery or summary that is already running can finish inside the slice.
_SLICE_RESERVE_SECONDS = 30

_TAGGED_FEED = r"""
const input = jet.input || {};
const budget = input.budget || {};
const sliceMs = Math.max(20, Number(budget.seconds) || 170) * 1000;
const sliceCalls = Math.max(20, Number(budget.calls) || 1000);
const startedAt = Date.now();
const prior = input.checkpoint && typeof input.checkpoint === 'object' ? input.checkpoint : {};
const state = {
  template: 'tagged_feed',
  reviews: prior.reviews | 0,
  reviewed_at: prior.reviewed_at | 0,
  partial: prior.partial | 0,
  failed_ids: Array.isArray(prior.failed_ids) ? prior.failed_ids.slice(-50) : [],
  slices: (prior.slices | 0) + 1,
  saved: 0
};
const skip = {};
state.failed_ids.forEach(function (id) { skip[id] = true; });
let calls = 0;
let failures = 0;
let lastError = '';

function call(name, args) {
  calls += 1;
  return jet.call(name, args);
}

function stop(status, summary) {
  state.saved = saved;
  call('run.checkpoint', { state: state, status: status, summary: summary });
  throw new Error('checkpoint did not end the slice');
}

function nearSliceEnd(reserveCalls) {
  return Date.now() - startedAt > sliceMs - OPTIONS.reserve_seconds * 1000 ||
    calls > sliceCalls - reserveCalls;
}

function tryModel(name, args) {
  try {
    return call(name, args) || {};
  } catch (error) {
    failures += 1;
    lastError = String((error && error.message) || error).slice(0, 120);
    return null;
  }
}

function reviewDue() {
  const every = state.reviews === 0 && OPTIONS.first_review > 0 ? OPTIONS.first_review : OPTIONS.review_every;
  return every > 0 && saved - state.reviewed_at >= every;
}

// Returns whether a record now exists for the item.
function organize(item) {
  let stored = false;
  if (item.truncated) {
    if (OPTIONS.recover_truncated) {
      const recovered = call('post.recover', { item_id: item.id }) || {};
      stored = true; // Recovery saves the observed evidence before opening the post.
      if (recovered.blocked) {
        state.partial += 1;
        call('run.progress', { message: 'Kept partial text; the full post could not be opened' });
      }
    } else {
      state.partial += 1;
    }
  }
  const classified = tryModel('model.classify', { item_id: item.id });
  if (!classified) {
    state.failed_ids.push(item.id);
    skip[item.id] = true;
    return stored;
  }
  let summary = '';
  if (OPTIONS.summarize) {
    const summarized = tryModel('model.summarize', { item_id: item.id });
    summary = summarized ? String(summarized.summary || '').slice(0, 1000) : '';
  }
  call('records.put', { item_id: item.id, tags: classified.tags || [], summary: summary });
  return true;
}

let saved = Number((call('records.list', { limit: 1 }) || {}).total) || 0;
if (saved >= OPTIONS.max_items) {
  stop('complete', 'Organized ' + saved + ' items; the requested limit is reached.');
}
const seen = {};
let observation = call('feed.observe', {}) || {};
let idle = 0;
while (true) {
  const items = observation.items || [];
  let revealed = 0;
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (!item || !item.id) continue;
    if (!seen[item.id]) {
      seen[item.id] = true;
      revealed += 1;
    }
    if (item.saved || skip[item.id]) continue;
    if (saved >= OPTIONS.max_items) {
      stop('complete', 'Organized ' + saved + ' items; the requested limit is reached.');
    }
    if (nearSliceEnd(12)) stop('continue', 'Organized ' + saved + ' items so far.');
    item.saved = true;
    if (organize(item)) saved += 1;
    if (failures >= 3) {
      stop('review', 'The local model failed on ' + failures + ' items (' + lastError + ').');
    }
    if (reviewDue()) {
      state.reviews += 1;
      state.reviewed_at = saved;
      stop('review', 'Organized ' + saved + ' items; checkpoint ' + state.reviews + ' is ready for review.');
    }
  }
  if (saved >= OPTIONS.max_items) {
    stop('complete', 'Organized ' + saved + ' items; the requested limit is reached.');
  }
  if (observation.end_of_feed === true) {
    stop('complete', 'Reached the end of the feed after organizing ' + saved + ' items.');
  }
  idle = revealed > 0 ? 0 : idle + 1;
  if (idle >= OPTIONS.max_idle_scrolls) {
    const decision = tryModel('model.decide', {
      question: 'No new items appeared after several scrolls. Should the collector keep scrolling?',
      choices: {
        scroll: 'Keep scrolling: the page is still loading or shows more items',
        stop: 'Stop: the page shows the end of the list, an error, or nothing new'
      },
      text: 'visible_items=' + items.length + ' loading=' + Boolean(observation.loading) +
        ' status=' + String(observation.status_text || '').slice(0, 200)
    });
    if (!decision || decision.choice !== 'scroll' || idle >= OPTIONS.max_idle_scrolls * 2) {
      stop('pause', 'No new items after ' + idle + ' scrolls; organized ' + saved +
        '. The feed may be finished or blocked.');
    }
  }
  if (nearSliceEnd(4)) stop('continue', 'Organized ' + saved + ' items so far.');
  observation = call('feed.scroll', { observation_id: observation.observation_id }) || {};
}
"""

# name -> (type, default, minimum, maximum); bounds apply to integers only.
_TAGGED_FEED_OPTIONS = {
    "summarize": (bool, True, None, None),
    "recover_truncated": (bool, True, None, None),
    "first_review": (int, 10, 0, 100),
    "review_every": (int, 0, 0, 1000),
    "max_idle_scrolls": (int, 3, 1, 10),
}

TEMPLATES = {
    "tagged_feed": {
        "version": 1,
        "description": (
            "Organize a feed or X Bookmarks: recover truncated posts, apply overlapping tags "
            "from the categories, optionally summarize, save link/author/date, skip saved items, "
            "pause for review after first_review items and then every review_every items "
            "(0 = none), continue long runs locally between time slices, stop at max_items, "
            "at the end of the feed, or after repeated scrolls reveal nothing new."
        ),
        "options": _TAGGED_FEED_OPTIONS,
        "capabilities": (
            "feed.observe", "feed.scroll", "post.recover", "model.decide", "model.classify",
            "model.summarize", "records.put", "records.list", "run.checkpoint", "run.progress",
        ),
        "body": _TAGGED_FEED,
    },
}


def catalog():
    """Template descriptions for workflow_sdk; no source bodies."""
    return [
        {
            "name": name,
            "version": spec["version"],
            "description": spec["description"],
            "options": {
                key: {"type": kind.__name__, "default": default,
                      **({"minimum": low, "maximum": high} if kind is int else {})}
                for key, (kind, default, low, high) in spec["options"].items()
            },
        }
        for name, spec in TEMPLATES.items()
    ]


def render(template, source_kind, limits):
    """Return (source, capabilities) for a template selection, or raise ValueError."""
    if not isinstance(template, dict):
        raise ValueError("template must be an object")
    unknown = set(template) - {"name", "options"}
    if unknown:
        raise ValueError("unknown field: " + sorted(unknown)[0])
    spec = TEMPLATES.get(template.get("name"))
    if spec is None:
        raise ValueError("unknown template; available: " + ", ".join(sorted(TEMPLATES)))
    raw = template.get("options", {})
    if not isinstance(raw, dict):
        raise ValueError("template options must be an object")
    unknown = set(raw) - set(spec["options"])
    if unknown:
        raise ValueError("unknown template option: " + sorted(unknown)[0])
    options = {}
    for key, (kind, default, low, high) in spec["options"].items():
        value = raw.get(key, default)
        if kind is bool:
            if not isinstance(value, bool):
                raise ValueError(key + " must be true or false")
        elif isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
            raise ValueError(f"{key} must be an integer from {low} to {high}")
        options[key] = value
    capabilities = list(spec["capabilities"])
    if source_kind != "x_bookmarks":
        # Exact-post recovery exists only for X Bookmarks.
        options["recover_truncated"] = False
        capabilities.remove("post.recover")
    if not isinstance(limits, dict) or not isinstance(limits.get("max_items"), int):
        raise ValueError("limits.max_items is required")
    options["max_items"] = limits["max_items"]
    options["reserve_seconds"] = _SLICE_RESERVE_SECONDS
    header = (
        f"// Jet built-in template {template['name']} v{spec['version']}. "
        "Options are fixed at save time; revise them with save_workflow.\n"
        "const OPTIONS = Object.freeze(" + json.dumps(options, sort_keys=True) + ");\n"
    )
    return header + spec["body"].lstrip("\n"), capabilities


def effective_options(source):
    """The frozen OPTIONS of rendered template source, or None for custom source."""
    prefix = "const OPTIONS = Object.freeze("
    for line in source.splitlines()[:3]:
        if line.startswith(prefix) and line.endswith(");"):
            return json.loads(line[len(prefix):-2])
    return None
