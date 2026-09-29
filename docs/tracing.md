# Local diagnostics

Jet Browser records content-free diagnostic events and OpenTelemetry span identities
locally. There is no collector, network exporter, automatic instrumentation or global
OpenTelemetry configuration. The service owns one `TraceStore`; its journal lives in
`.runtime/traces/` and is independent of conversation history and browser task evidence.

Use the diagnostics to answer:

- Which route and model handled this turn, and did execution reach the native browser?
- Was time spent waiting for the queue, loading/inferencing locally, in Grok, or in a
  native browser request?
- Which stage failed or stopped, and did a later action dispatch after Stop?
- Did a task/thread/native reply remain attached to the correct conversation and turn?

## Reading a turn

`store.snapshot(session_id, turn_id=None, limit=120)` returns `turn_id`, `events` and
`summary`. An omitted turn selects the newest retained turn in that session. The summary
contains `event_count`, `error_count`, `duration_ms`, event-name counts, latency p50/p95,
and the visible `logging_error` counter. The return limit is capped at 2,000 events;
the summary covers the selected turn's complete **retained in-memory** event set.
`store.recent(session_id, turn_id=None, limit=120)` can also return events across all
turns of a session. Returned objects are copies.

Every JSONL row has the same fields:

```text
id, ts, event, level, session_id, turn_id,
trace_id, span_id, parent_span_id, duration_ms, attributes
```

Timestamps are UTC ISO 8601. Each span emits `<name>.start` and `<name>.end`; the end
records its duration and status. Errors preserve exception **type**, never the raw
exception message or stack. Follow `parent_span_id` to group nested work, and use
`trace_id` to correlate thread and callback events. A completed root span supplies
the turn's end-to-end duration. Before that is available, the summary uses the elapsed
time between retained events. Nested durations are not summed, which would double-count
work. p50/p95 use the nearest-rank percentile over retained duration-bearing events,
not a promise of model benchmark accuracy.

The integration serves these data on authenticated local state/trace/metrics routes.
The journal can also be read directly with local tools; it is not an upload destination.
For example, print event names and times for one turn without displaying attributes:

```python
import json
from pathlib import Path

for path in sorted(Path('.runtime/traces').glob('events*.jsonl')):
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:  # A running writer may have an incomplete final line.
            continue
        if row.get('turn_id') == 'TURN_ID':
            print(row['ts'], row['event'], row['duration_ms'], row['span_id'])
```

Sort by `ts` when combining rotated files. `events.jsonl` is current; `events.1.jsonl`
is the most recently rotated archive.

## Instrumentation and correlation

```python
with traces.bind(session_id=session_id, turn_id=turn_id):
    with traces.span('chat.turn', model=model):
        captured = traces.capture()
        await asyncio.to_thread(local_work)  # contextvars propagate automatically

# A different request/callback must restore context explicitly:
with captured.bind():
    with traces.span('native.input', command_id=command_id):
        await send_observed_action()

# For synchronous callbacks on a thread pool:
executor.submit(captured.run, on_native_result, result)
```

`capture().run` makes a fresh context copy for each invocation, so it is reusable by
concurrent callbacks. For async callbacks, enter `captured.bind()` while awaiting or
creating the task; calling an async function through `run` only creates its coroutine.
Omitted IDs in nested `bind` calls preserve current IDs; leaving either context manager
restores the caller's context. A capture can attach late replies to an already ended
parent span, without re-opening that span. Correlation does **not** authorize browser
actions, revive cancelled work, or replace the run/command identity checks.

Span attributes and events go through the same allowlist. Call sites must use stable,
code-owned event/metric names. Useful attributes include model, provider, operation,
observed opaque IDs, a finite decision/choice, confidence/probabilities, counts, durations,
queue/load/inference times, cache state, native focus/tag/type, page-change flags, and
verification/cancellation status. Probability maps are capped at 32 validated labels.
Do not pass page-derived text as a choice, model name or identifier.

## Content boundary

The diagnostic store drops arbitrary/unknown metadata, including prompts, messages,
page snapshots, input values, model output, generated code, auth, environment variables
and hidden reasoning. Free-form `reason` is dropped unless it is a short machine label.
Free-form error strings become a known category such as `timeout` or
`connection_refused`, or `redacted`. No exception stack is recorded by the SDK.

URLs retain only HTTP(S) origin; credentials, paths, queries and fragments are omitted.
This is stricter than dropping only query parameters because paths can also identify a
person or contain a token. Short metadata strings must match the bounded label format;
recognized secret prefixes are rejected. Explicit field allowlisting complements, and
does not replace, caller discipline: never place user text in an allowed ID/label field.

## Bounds, metrics and failures

- The trace directory and its `.runtime` parent are owner-only (`0700`); journal files
  are `0600`. Opening trace files refuses symlinks. No credentials are copied into it.
- By default, at most five files of 8 MiB each are retained. Oldest archives rotate out.
  The store assumes one service process owns the directory.
- Memory holds the newest 6,000 events. Restart reads the retained journal into that
  bound, revalidates metadata, skips malformed rows and discards an incomplete final
  line before a later append. It does not replay browser work.
- `traces.record(name, duration_ms, status='ok')` and
  `traces.metrics.record(...)` update in-memory aggregates without writing log rows.
  `traces.metrics()`/`.snapshot()` return count, errors and p50/p95/max/last latency.
  Each of at most 128 metric names retains 512 recent duration samples. Counts are
  cumulative for this process; percentiles use the rolling sample. Metrics reset on
  service restart. Invalid/excess names increment `metrics_dropped`.
- Polling routes should record metrics only, avoiding a stream of `/state` log events.
  Use fixed route templates or `unknown`, never raw paths, IDs or URLs as metric names.
  HTTP `2xx`/`3xx` and `ok`/`success`/`completed` count as successful outcomes. Exact
  `model.load`, `model.inference`, `grok.acp.request` and `grok.prompt` `.end`/`.error`
  callback events with durations also update their dependency metric; SDK spans of
  these names are counted once, not again through their emitted end event.
- Disk failures fail open: app operations continue, in-memory events remain available,
  and `summary.logging_error` increments. It is a cumulative diagnostic-operation
  failure count, not a count of distinct filesystem incidents. No filesystem exception
  prose is exposed. A failure inside an application span still raises the original
  application exception.
- `close()` shuts down the private SDK provider; each journal append is already closed.
  The store does not guarantee the last filesystem write survives power loss.

Tests in `backend/tests/test_tracing.py` cover real thread and async correlation,
content omission, SDK exception redaction, restart/rotation/permissions, partial-tail
recovery, fail-open I/O, session scoping, bounded metrics and polling without log writes.
