import asyncio
import json
import os
from concurrent.futures import ThreadPoolExecutor

import pytest
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

from jet_browser.tracing import TraceStore


async def test_span_context_survives_to_thread_and_explicit_callback_capture(tmp_path):
    store = TraceStore(tmp_path)
    with store.bind(session_id="session-1", turn_id="turn-1"):
        with store.span("chat.turn"):
            parent = store.current_context()
            captured = store.capture()
            await asyncio.to_thread(store.emit, "worker.ready", model="lfm_rlcd")
        assert store.current_context()["span_id"] is None

    def callback(index):
        with captured.bind(), store.span("native.input", steps=index):
            return store.emit("native.result", status="ok")

    with ThreadPoolExecutor(max_workers=3) as executor:
        rows = list(executor.map(callback, range(3)))
        restored = executor.submit(captured.run, store.current_context).result()
    assert restored == parent
    for row in rows:
        assert row["session_id"] == "session-1"
        assert row["turn_id"] == "turn-1"
        assert row["trace_id"] == parent["trace_id"]
        assert row["parent_span_id"] == parent["span_id"]
    worker = next(row for row in store.recent("session-1") if row["event"] == "worker.ready")
    assert worker["span_id"] == parent["span_id"]
    assert store.current_context()["session_id"] is None


def test_metadata_and_exception_payloads_cannot_leak_content(tmp_path):
    store = TraceStore(tmp_path)
    private_marker = "apikey_synthetic_redaction_test"
    with store.bind(session_id="s", turn_id="t"):
        row = store.emit(
            "router.result", prompt=private_marker, body={"token": private_marker}, text=private_marker,
            value=private_marker, output=private_marker, page_snapshot=private_marker, code=private_marker,
            env={"KEY": private_marker}, auth=private_marker, reasoning=private_marker,
            model="lfm_rlcd", choice="browser_task", confidence=0.91,
            probabilities={"browser_task": 0.91, private_marker: 0.09},
            url="https://alice:password@example.com/private/alice?token=hidden#secret",
            error=f"Connection refused for alice@example.com: {private_marker}",
            reason="Fill in the form with private user text",
        )
        with pytest.raises(ValueError):
            with store.span("provider.call") as span:
                raise ValueError(f"secret prompt: {private_marker}")
    payload = json.dumps(store.recent("s"))
    assert private_marker not in payload
    assert "alice" not in payload
    assert "hidden" not in payload
    assert "private user text" not in payload
    assert "prompt" not in row["attributes"]
    assert row["attributes"]["url"] == "https://example.com"
    assert row["attributes"]["probabilities"] == {"browser_task": 0.91}
    assert row["attributes"]["error"] == "connection_refused"
    assert span.status.status_code == StatusCode.ERROR
    assert not span.events  # SDK exception recording would retain the raw message/stack.
    error = store.recent("s")[-1]
    assert error["level"] == "error"
    assert error["attributes"]["error_type"] == "ValueError"
    assert error["duration_ms"] >= 0
    assert store.snapshot("s")["summary"]["error_count"] == 1


def test_jsonl_rotation_restart_permissions_and_partial_tail(tmp_path):
    store = TraceStore(tmp_path, max_bytes=1300, file_count=3, max_events=1000)
    with store.bind(session_id="s", turn_id="t"):
        for index in range(30):
            store.emit("native.result", steps=index, status="ok")
    paths = list((tmp_path / ".runtime/traces").glob("*.jsonl"))
    assert len(paths) == 3
    assert all(path.stat().st_size <= 1300 for path in paths)
    assert all(path.stat().st_mode & 0o077 == 0 for path in paths)
    assert (tmp_path / ".runtime/traces").stat().st_mode & 0o077 == 0
    with store.path.open("ab") as output:
        output.write(b'{"incomplete":')
    restarted = TraceStore(tmp_path, max_bytes=1300, file_count=3)
    retained = restarted.recent("s", limit=1000)
    assert 0 < len(retained) < 30
    assert retained[-1]["attributes"]["steps"] == 29
    with restarted.bind(session_id="s", turn_id="t"):
        restarted.emit("native.next", steps=30)
    assert TraceStore(tmp_path).recent("s")[-1]["event"] == "native.next"


def test_snapshot_is_scoped_bounded_and_metrics_do_not_write_poll_events(tmp_path):
    store = TraceStore(tmp_path)
    with store.bind(session_id="a", turn_id="old"):
        store.emit("native.end", duration_ms=1000)
    with store.bind(session_id="a", turn_id="new"):
        for duration in [10, 20, 30, 40, 50]:
            store.emit("native.end", duration_ms=duration)
    with store.bind(session_id="b", turn_id="other"):
        store.emit("chat.end", duration_ms=9999)
    snapshot = store.snapshot("a", limit=2)
    assert snapshot["turn_id"] == "new"
    assert len(snapshot["events"]) == 2
    assert snapshot["summary"]["event_count"] == 5
    assert snapshot["summary"]["p50_ms"] == 30
    assert snapshot["summary"]["p95_ms"] == 50
    snapshot["events"][0]["attributes"]["model"] = "changed"
    assert "changed" not in json.dumps(store.recent("a"))
    size = store.path.stat().st_size
    for _ in range(1100):
        store.metrics.record("http.state", 5)
    store.metrics.record("http.state", 15, status="error")
    assert store.path.stat().st_size == size
    stats = store.metrics.snapshot()["http.state"]
    assert stats["count"] == 1101
    assert stats["error_count"] == 1
    assert stats["sample_count"] <= 512
    assert stats["p50_ms"] == 5


def test_logging_failure_cannot_replace_application_error(tmp_path, monkeypatch):
    store = TraceStore(tmp_path)
    original = os.open

    def denied(path, *args, **kwargs):
        if str(path).endswith(".jsonl"):
            raise OSError("private filesystem details must not escape")
        return original(path, *args, **kwargs)

    monkeypatch.setattr(os, "open", denied)
    with store.bind(session_id="s", turn_id="t"):
        with pytest.raises(RuntimeError, match="original failure"):
            with store.span("chat.turn"):
                raise RuntimeError("original failure")
    assert store.snapshot("s")["summary"]["logging_error"] > 0
    assert store.recent("s")[-1]["attributes"]["error_type"] == "RuntimeError"
    assert not trace.get_current_span().get_span_context().is_valid


async def test_concurrent_async_turns_and_nested_binding_do_not_bleed(tmp_path):
    store = TraceStore(tmp_path)

    async def turn(session, turn_id):
        with store.bind(session_id=session, turn_id=turn_id), store.span("chat.turn"):
            await asyncio.sleep(0)
            with store.bind(turn_id=turn_id + "-tool"):
                child = store.emit("tool.start", tool="read_page")
            main = store.emit("chat.progress", output_chars=20)
            return child, main

    results = await asyncio.gather(turn("a", "a-turn"), turn("b", "b-turn"))
    for session, (child, main) in zip(("a", "b"), results):
        assert child["session_id"] == main["session_id"] == session
        assert child["turn_id"] == session + "-turn-tool"
        assert main["turn_id"] == session + "-turn"
        assert child["trace_id"] == main["trace_id"]
    assert results[0][0]["trace_id"] != results[1][0]["trace_id"]
    assert store.current_context()["turn_id"] is None


def test_metrics_cardinality_and_poll_api_remain_bounded(tmp_path):
    store = TraceStore(tmp_path)
    for index in range(300):
        store.record(f"poll.{index}", index, status="ok")
    store.record("https://example.com/private?token=not-a-label", 1)
    assert len(store.metrics()) == 128
    assert store.metrics.dropped == 173
    assert not store.path.exists()
    store.close()


def test_dependency_callback_metrics_http_success_and_focus_contract(tmp_path):
    store = TraceStore(tmp_path)
    store.record("http.state", 2, status="2xx")
    store.record("http.redirect", 3, status="3xx")
    store.emit("model.inference.end", duration_ms=9, status="ok", focus=True)
    store.emit("model.inference.error", duration_ms=5, error_type="RuntimeError")
    with store.span("model.inference"):
        pass
    stats = store.metrics()
    assert stats["http.state"]["error_count"] == stats["http.redirect"]["error_count"] == 0
    assert stats["model.inference"]["count"] == 3  # The SDK span is counted once.
    assert stats["model.inference"]["error_count"] == 1
    assert store.recent(None)[0]["attributes"]["focus"] is True
    assert store.recent(None)[1]["level"] == "error"


def test_provider_diagnostics_retain_only_identifiers_and_counts(tmp_path):
    store = TraceStore(tmp_path)
    row = store.emit(
        "grok.stream.update", request_id=17, tool_call_id="call_2", tool_name="read_page",
        tool_kind="read", identity_source="canonical", return_code=0, forced_kill=False,
        reason_type="permission", stop_reason="end_turn", text_characters=81,
        text_chunks=2, tool_calls=1, input_characters=31, characters=40, total_characters=81,
        chunks=2, allowed=False, level="warning", text="must not retain this response",
    )
    assert row["attributes"]["request_id"] == "17"
    assert row["attributes"]["tool_name"] == "read_page"
    assert row["attributes"]["text_characters"] == 81
    assert row["attributes"]["forced_kill"] is False
    assert "text" not in row["attributes"]
    assert row["level"] == "warn"


def test_explicit_error_span_survives_normal_return_without_description_content(tmp_path):
    store = TraceStore(tmp_path)
    with store.bind(session_id="s", turn_id="t"):
        with store.span("task.run") as span:
            span.set_status(Status(StatusCode.ERROR, "Connection refused; secret user prompt and token"))
    row = store.recent("s")[-1]
    assert span.status.status_code == StatusCode.ERROR
    assert span.status.description == "connection_refused"
    assert row["level"] == "error"
    assert row["attributes"]["status"] == "error"
    assert row["attributes"]["error"] == "connection_refused"
    assert store.metrics()["task.run"]["error_count"] == 1
    assert "secret user prompt" not in json.dumps(store.recent("s"))
    assert TraceStore(tmp_path).recent("s")[-1]["attributes"]["error"] == "connection_refused"
