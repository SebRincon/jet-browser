"""Private, content-free diagnostics; no network exporter or global OTel setup."""

import contextvars
import copy
import json
import math
import os
import re
import threading
import time
import uuid
from collections import Counter, deque
from contextlib import contextmanager
from datetime import UTC, datetime
from itertools import islice
from pathlib import Path
from urllib.parse import urlsplit

from opentelemetry import context as otel_context
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.sampling import ALWAYS_ON
from opentelemetry.trace import Status, StatusCode

_binding = contextvars.ContextVar("jet_browser_trace_binding", default={})
_parent = contextvars.ContextVar("jet_browser_trace_parent", default=None)
_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:/+-]{0,95}$")
_SECRET = re.compile(r"(?i)(apikey[_-]|api[_-]?key[=:]|bearer|^sk[-_]|password[=:]|token[=:]|secret[=:])")
_STRING_FIELDS = frozenset({
    "stage", "route_id", "task_id", "command_id", "tab_id", "operation", "decision",
    "model", "provider", "method", "status", "error_type", "reason", "tool", "tool_id",
    "request_id", "kind", "choice", "host_id", "action", "turn_id", "session_id", "profile",
    "tag", "type", "component", "route", "backend", "worker_id", "source", "file_id",
    "tool_call_id", "tool_name", "tool_kind", "identity_source", "reason_type", "stop_reason",
})
_NUMBER_FIELDS = frozenset({
    "confidence", "probability", "status_code", "queue_ms", "load_ms", "inference_ms",
    "input_chars", "output_chars", "context_chars", "message_count", "steps", "native_calls",
    "typing_calls", "pid", "exit_code", "candidate_count", "duration_ms", "count", "attempt",
    "elapsed_ms", "tokens", "input_tokens", "output_tokens", "ttft_ms", "latency_ms",
    "input_characters", "characters", "total_characters", "chunks", "return_code",
    "text_characters", "text_chunks", "tool_calls", "size_bytes",
    "scroll_top", "scroll_height", "viewport_height",
    # Provider liveness and failed-turn recovery; counts only, never content.
    "quiet_ms", "thought_chunks", "thought_characters", "completed_tools",
    "saved_workflows", "started_workflows", "prepared_collections", "started_collections",
})
_BOOL_FIELDS = frozenset({
    "stop_requested", "verified", "allowed", "read_only", "connected", "page_changed",
    "cache_hit", "warm", "focus", "focused", "cancelled", "truncated", "forced_kill",
})
_DEPENDENCY_METRICS = {
    f"{name}.{ending}": name
    for name in ("model.load", "model.inference", "grok.acp.request", "grok.prompt")
    for ending in ("end", "error")
}
_SUCCESS_STATUSES = frozenset({"ok", "success", "completed", "2xx", "3xx"})
_ERROR_CATEGORIES = (
    ("connection refused", "connection_refused"), ("timed out", "timeout"),
    ("timeout", "timeout"), ("cancel", "cancelled"), ("permission denied", "permission_denied"),
    ("not found", "not_found"), ("unavailable", "unavailable"), ("disconnect", "disconnected"),
    ("invalid", "invalid_response"), ("stopped", "stopped"), ("closed", "closed"),
)
_ERROR_LABELS = frozenset(category for _, category in _ERROR_CATEGORIES) | {
    "error", "failed", "blocked", "stopped", "outcome_unknown", "unverified", "redacted",
}


def _label(value):
    if isinstance(value, str) and _LABEL.fullmatch(value) and not _SECRET.search(value):
        return value
    return None


def _number(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            return value if math.isfinite(value) and abs(value) < 1e15 else None
        except (OverflowError, ValueError):
            pass
    return None


def _error(value):
    # Arbitrary exception prose can embed prompts, CLI output or credentials. Retain
    # only diagnostic categories, never excerpts, tracebacks or str(exception).
    if isinstance(value, str):
        lowered = value[:4096].lower()
        if lowered in _ERROR_LABELS:
            return lowered
        for fragment, category in _ERROR_CATEGORIES:
            if fragment in lowered:
                return category
    return "redacted"


def _url(value):
    if not isinstance(value, str) or len(value) > 8192:
        return None
    try:
        parsed = urlsplit(value)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            return None
        host = parsed.hostname
        if not re.fullmatch(r"[a-zA-Z0-9.:-]{1,253}", host):
            return None
        if ":" in host:
            host = f"[{host}]"
        port = f":{parsed.port}" if parsed.port is not None else ""
        return f"{parsed.scheme}://{host}{port}"
    except ValueError:
        return None


def _metadata(attrs):
    safe = {}
    for key, value in attrs.items():
        cleaned = None
        if key in _STRING_FIELDS:
            if key == "request_id" and isinstance(value, int) and not isinstance(value, bool) and abs(value) < 1e15:
                cleaned = str(value)
            else:
                cleaned = _label(value)
        elif key in _NUMBER_FIELDS:
            cleaned = _number(value)
        elif key in _BOOL_FIELDS and isinstance(value, bool):
            cleaned = value
        elif key == "error":
            cleaned = _error(value)
        elif key in {"url", "origin"}:
            cleaned = _url(value)
        elif key == "probabilities" and isinstance(value, dict):
            cleaned = {}
            for label, probability in islice(value.items(), 32):
                if _label(label) and _number(probability) is not None and 0 <= probability <= 1:
                    cleaned[label] = probability
        if cleaned is not None:
            safe[key] = cleaned
    return safe


def _percentile(values, quantile):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * quantile) - 1)]


class Metrics:
    """Fixed memory rolling latency samples, separate from the event journal."""

    def __init__(self, max_names=128, sample_count=512):
        self._max_names = max_names
        self._sample_count = sample_count
        self._values = {}
        self._lock = threading.RLock()
        self.dropped = 0

    def record(self, name, duration_ms, status="ok"):
        duration = _number(duration_ms)
        with self._lock:
            if not _label(name) or duration is None or duration < 0:
                self.dropped += 1
                return
            if name not in self._values:
                if len(self._values) >= self._max_names:
                    self.dropped += 1
                    return
                self._values[name] = {"count": 0, "error_count": 0, "durations": deque(maxlen=self._sample_count)}
            metric = self._values[name]
            metric["count"] += 1
            metric["error_count"] += status not in _SUCCESS_STATUSES
            metric["durations"].append(duration)

    def snapshot(self):
        with self._lock:
            return {
                name: {
                    "count": metric["count"], "error_count": metric["error_count"],
                    "sample_count": len(metric["durations"]),
                    "p50_ms": _percentile(metric["durations"], 0.5),
                    "p95_ms": _percentile(metric["durations"], 0.95),
                    "max_ms": max(metric["durations"], default=None),
                    "last_ms": metric["durations"][-1],
                }
                for name, metric in self._values.items()
            }

    def __call__(self):
        return self.snapshot()


class CapturedContext:
    """A reusable callback context; each run uses an independent Context copy."""

    def __init__(self):
        self._context = contextvars.copy_context()
        self._binding = dict(_binding.get())
        self._parent = _parent.get()
        self._otel = otel_context.get_current()

    def run(self, callback, *args, **kwargs):
        return self._context.copy().run(callback, *args, **kwargs)

    @contextmanager
    def bind(self):
        binding_token = _binding.set(self._binding)
        parent_token = _parent.set(self._parent)
        otel_token = otel_context.attach(self._otel)
        try:
            yield self
        finally:
            otel_context.detach(otel_token)
            _parent.reset(parent_token)
            _binding.reset(binding_token)


class TraceStore:
    """One process owns one private rotating journal. Logging never blocks task success."""

    def __init__(self, root, *, max_bytes=8 * 1024 * 1024, file_count=5, max_events=6000):
        self.directory = Path(root) / ".runtime" / "traces"
        self.path = self.directory / "events.jsonl"
        self.max_bytes = max(512, max_bytes)
        self.file_count = max(1, min(20, file_count))
        self._events = deque(maxlen=max(1, max_events))
        self._lock = threading.RLock()
        self.logging_error = 0
        self.metrics = Metrics()
        # Deliberately private: no global provider, exporter, autoinstrumentation,
        # SDK exception capture, environment resource attributes or network traffic.
        self._provider = TracerProvider(resource=Resource({"service.name": "jet-browser"}), sampler=ALWAYS_ON)
        self._tracer = self._provider.get_tracer("jet_browser.local")
        try:
            self._prepare_directory()
            self._load()
        except (OSError, ValueError):
            self.logging_error += 1

    def _prepare_directory(self):
        for directory in (self.directory.parent, self.directory):
            if directory.is_symlink():
                raise OSError("Trace directory cannot be a symlink")
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            directory.chmod(0o700)

    def _archive(self, index):
        return self.directory / f"events.{index}.jsonl"

    def _open(self, path, flags):
        return os.open(path, flags | getattr(os, "O_NOFOLLOW", 0), 0o600)

    def _load(self):
        paths = [self._archive(index) for index in range(self.file_count - 1, 0, -1)] + [self.path]
        for path in paths:
            if not path.exists():
                continue
            descriptor = self._open(path, os.O_RDWR)
            with os.fdopen(descriptor, "r+b") as source:
                os.fchmod(source.fileno(), 0o600)
                last_complete = 0
                for line in source:
                    if not line.endswith(b"\n"):
                        # A killed writer can leave a tail; discard it before appending.
                        source.seek(last_complete)
                        source.truncate()
                        break
                    last_complete = source.tell()
                    try:
                        row = json.loads(line)
                        if isinstance(row, dict) and _label(row.get("event")):
                            self._events.append(self._safe_loaded(row))
                    except (ValueError, TypeError):
                        continue

    def _safe_loaded(self, row):
        # The journal is private, but revalidate retained rows rather than trusting
        # old formats or accidental edits to bring content back into /state.
        clean = {key: None for key in (
            "id", "ts", "event", "level", "session_id", "turn_id", "trace_id",
            "span_id", "parent_span_id", "duration_ms", "attributes",
        )}
        for key in ("id", "event", "session_id", "turn_id", "trace_id", "span_id", "parent_span_id"):
            clean[key] = _label(row.get(key))
        try:
            timestamp = datetime.fromisoformat(row["ts"])
            clean["ts"] = timestamp.replace(tzinfo=timestamp.tzinfo or UTC).astimezone(UTC).isoformat()
        except (ValueError, TypeError, KeyError):
            clean["ts"] = datetime.now(UTC).isoformat()
        clean["level"] = row.get("level") if row.get("level") in {"debug", "info", "warn", "error"} else "info"
        clean["duration_ms"] = _number(row.get("duration_ms"))
        clean["attributes"] = _metadata(row.get("attributes", {})) if isinstance(row.get("attributes"), dict) else {}
        return clean

    def _append(self, row):
        line = (json.dumps(row, ensure_ascii=True, allow_nan=False, separators=(",", ":")) + "\n").encode()
        if len(line) > self.max_bytes:
            self.logging_error += 1
            return
        self._prepare_directory()
        if self.path.exists() and self.path.stat().st_size + len(line) > self.max_bytes:
            if self.file_count == 1:
                self.path.unlink()
            else:
                self._archive(self.file_count - 1).unlink(missing_ok=True)
                for index in range(self.file_count - 2, 0, -1):
                    source = self._archive(index)
                    if source.exists():
                        source.replace(self._archive(index + 1))
                self.path.replace(self._archive(1))
        descriptor = self._open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
        with os.fdopen(descriptor, "ab") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(line)

    @contextmanager
    def bind(self, session_id=None, turn_id=None):
        binding = dict(_binding.get())
        if session_id is not None:
            binding["session_id"] = _label(session_id)
        if turn_id is not None:
            binding["turn_id"] = _label(turn_id)
        token = _binding.set(binding)
        try:
            yield self
        finally:
            _binding.reset(token)

    def current_context(self):
        current = trace.get_current_span().get_span_context()
        return {
            "session_id": _binding.get().get("session_id"),
            "turn_id": _binding.get().get("turn_id"),
            "trace_id": f"{current.trace_id:032x}" if current.is_valid else None,
            "span_id": f"{current.span_id:016x}" if current.is_valid else None,
            "parent_span_id": _parent.get(),
        }

    def capture(self):
        return CapturedContext()

    def record(self, name, duration_ms, status="ok"):
        self.metrics.record(name, duration_ms, status)

    def close(self):
        try:
            self._provider.shutdown()
        except Exception:
            with self._lock:
                self.logging_error += 1

    def emit(self, event, **attrs):
        try:
            span_event = attrs.pop("_span_event", False)
            context = self.current_context()
            for name in ("session_id", "turn_id"):
                if name in attrs:
                    context[name] = _label(attrs.pop(name))
            level = attrs.pop("level", None)
            if level is None:
                level = "info"
                if isinstance(event, str) and event.endswith(".error"):
                    level = "error"
                if attrs.get("status") in ("error", "failed", "timeout"):
                    level = "error"
            if level == "warning":
                level = "warn"
            duration = _number(attrs.pop("duration_ms", None))
            row = {
                "id": uuid.uuid4().hex, "ts": datetime.now(UTC).isoformat(),
                "event": _label(event) or "diagnostic.invalid_event",
                "level": level if level in {"debug", "info", "warn", "error"} else "info",
                **context, "duration_ms": duration, "attributes": _metadata(attrs),
            }
            with self._lock:
                self._events.append(row)
                try:
                    self._append(row)
                except (OSError, ValueError, TypeError):
                    self.logging_error += 1
            if not span_event and duration is not None and event in _DEPENDENCY_METRICS:
                status = row["attributes"].get("status", "ok")
                if row["level"] == "error" or event.endswith(".error"):
                    status = "error"
                self.record(_DEPENDENCY_METRICS[event], duration, status)
            return copy.deepcopy(row)
        except Exception:
            # Diagnostics must not replace the original user-operation failure.
            with self._lock:
                self.logging_error += 1
            return None

    @contextmanager
    def span(self, name, **attrs):
        safe_name = _label(name) or "diagnostic.invalid_span"
        started = time.perf_counter()
        parent = trace.get_current_span().get_span_context()
        parent_token = _parent.set(f"{parent.span_id:016x}" if parent.is_valid else None)
        safe_attrs = _metadata(attrs)
        # OTel accepts scalar attributes, not probability maps. The latter remain
        # in sanitized JSONL only. Never call record_exception.
        otel_attrs = {key: value for key, value in safe_attrs.items() if not isinstance(value, dict)}
        status = "ok"
        try:
            with self._tracer.start_as_current_span(
                safe_name, attributes=otel_attrs, record_exception=False, set_status_on_exception=False,
            ) as span:
                self.emit(safe_name + ".start", **safe_attrs)
                try:
                    yield span
                except BaseException as error:
                    status = "cancelled" if isinstance(error, (KeyboardInterrupt, SystemExit)) or type(error).__name__ == "CancelledError" else "error"
                    span.set_status(Status(StatusCode.ERROR, status))
                    self.emit(safe_name + ".end", **{
                        **safe_attrs, "status": status, "level": "error", "error_type": type(error).__name__,
                        "_span_event": True,
                        "duration_ms": round((time.perf_counter() - started) * 1000, 3),
                    })
                    raise
                else:
                    terminal = {}
                    if span.status.status_code == StatusCode.ERROR:
                        status = "error"
                        category = _error(span.status.description)
                        span.set_status(Status(StatusCode.ERROR, category))
                        terminal = {"level": "error", "error": category}
                    else:
                        span.set_status(Status(StatusCode.OK))
                    self.emit(safe_name + ".end", **{
                        **safe_attrs, **terminal, "status": status, "_span_event": True,
                        "duration_ms": round((time.perf_counter() - started) * 1000, 3),
                    })
        finally:
            self.metrics.record(safe_name, (time.perf_counter() - started) * 1000, status=status)
            _parent.reset(parent_token)

    def recent(self, session_id, turn_id=None, limit=120):
        limit = max(0, min(int(limit), 2000))
        with self._lock:
            rows = [row for row in self._events if (session_id is None or row["session_id"] == session_id)
                    and (turn_id is None or row["turn_id"] == turn_id)]
            return copy.deepcopy(rows[-limit:] if limit else [])

    def snapshot(self, session_id, turn_id=None, limit=120):
        with self._lock:
            rows = [row for row in self._events if row["session_id"] == session_id]
            if turn_id is None:
                turn_id = next((row["turn_id"] for row in reversed(rows) if row["turn_id"] is not None), None)
            rows = [row for row in rows if row["turn_id"] == turn_id]
            durations = [row["duration_ms"] for row in rows if row["duration_ms"] is not None]
            # End-to-end elapsed time is from a root span when available; adding
            # nested span durations would incorrectly double-count work.
            roots = [row["duration_ms"] for row in rows if row["duration_ms"] is not None
                     and row["parent_span_id"] is None and row["event"].endswith(".end")]
            elapsed = max(roots, default=None)
            if elapsed is None and len(rows) > 1:
                elapsed = max(0, (datetime.fromisoformat(rows[-1]["ts"]) - datetime.fromisoformat(rows[0]["ts"])).total_seconds() * 1000)
            summary = {
                "event_count": len(rows), "error_count": sum(row["level"] == "error" for row in rows),
                "duration_ms": round(elapsed or 0, 3), "p50_ms": _percentile(durations, 0.5),
                "p95_ms": _percentile(durations, 0.95), "logging_error": self.logging_error,
                "by_event": dict(Counter(row["event"] for row in rows)),
                "retained_event_limit": self._events.maxlen, "metrics_dropped": self.metrics.dropped,
            }
            return {"turn_id": turn_id, "events": self.recent(session_id, turn_id, limit), "summary": summary}
