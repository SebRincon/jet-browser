"""Protocol tests use in-memory streams; no CLI, browser, network, or provider."""

import asyncio
import json
import os
from pathlib import Path

import pytest

from jet_browser.grok import GrokCancelled, GrokClient, GrokError, GrokStalled

GROK_USE_TOOL_META = {
    "x.ai/tool": {
        "version": 1,
        "name": "use_tool",
        "kind": "use_tool",
        "namespace": "grok_build",
        "label": "Use Tool",
        "read_only": False,
    }
}
GROK_WEB_FETCH_META = {
    "x.ai/tool": {
        "version": 1,
        "name": "web_fetch",
        "kind": "web_fetch",
        "namespace": "grok_build",
        "label": "Web Fetch",
        "read_only": True,
    }
}


class FakeInput:
    def __init__(self, process):
        self.process = process

    def write(self, data):
        message = json.loads(data)
        self.process.sent.append(message)
        self.process.on_message(message)

    async def drain(self):
        await asyncio.sleep(0)


class FakeProcess:
    def __init__(self):
        self.stdout = asyncio.StreamReader()
        self.stderr = asyncio.StreamReader()
        self.stdin = FakeInput(self)
        self.returncode = None
        self.exited = asyncio.Event()
        self.sent = []
        self.on_prompt = lambda message: None
        self.auto_initialize = True
        self.auto_cancel = True
        self.prompt_id = None

    def receive(self, message):
        self.stdout.feed_data((json.dumps({"jsonrpc": "2.0", **message}) + "\n").encode())

    def update(self, update_type, **fields):
        self.receive(
            {
                "method": "session/update",
                "params": {"sessionId": "session-1", "update": {"sessionUpdate": update_type, **fields}},
            }
        )

    def on_message(self, message):
        method = message.get("method")
        if method == "initialize" and self.auto_initialize:
            self.receive({"id": message["id"], "result": {"protocolVersion": 1}})
        elif method == "session/new":
            self.receive({"id": message["id"], "result": {"sessionId": "session-1"}})
        elif method == "session/prompt":
            self.prompt_id = message["id"]
            self.on_prompt(message)
        elif method == "session/cancel" and self.auto_cancel:
            self.finish("cancelled")

    def finish(self, reason="end_turn"):
        self.receive({"id": self.prompt_id, "result": {"stopReason": reason}})

    def terminate(self):
        self.returncode = -15
        self.stdout.feed_eof()
        self.stderr.feed_eof()
        self.exited.set()

    def kill(self):
        self.terminate()

    async def wait(self):
        await self.exited.wait()
        return self.returncode


@pytest.fixture
async def rig(monkeypatch, tmp_path):
    process = FakeProcess()
    events = []
    launches = []

    async def spawn(*args, **kwargs):
        profile = Path(args[args.index("--agent-profile") + 1])
        launches.append((args, kwargs, profile.read_text()))
        return process

    monkeypatch.setattr(asyncio, "create_subprocess_exec", spawn)
    monkeypatch.setenv("JET_GROK_PATH", "/fake/grok")
    monkeypatch.setenv("GROK_FOLDER_TRUST", "1")
    client = GrokClient(tmp_path, ["/fake/python", "-m", "jet_browser.mcp"], events.append)
    client.startup_timeout = 0.1
    client.cancel_timeout = 0.05
    return client, process, events, launches


async def wait_until(predicate):
    async with asyncio.timeout(1):
        while not predicate():
            await asyncio.sleep(0)


async def test_handshake_streams_while_request_pending_and_preserves_updates(rig):
    client, process, events, launches = rig
    try:
        await client.start()
        args, kwargs, profile = launches[0]
        assert args[0] == "/fake/grok"
        assert "--always-approve" not in args
        assert args[-1] == "stdio"
        assert "--no-leader" in args and "--no-subagents" in args
        assert [args[i + 1] for i, arg in enumerate(args) if arg == "--deny"] == ["Bash", "Edit", "Write"]
        assert "tools: [search_tool, use_tool, web_search, web_fetch]" in profile
        private_cwd = kwargs["cwd"]
        assert private_cwd != client.cwd
        assert (private_cwd / ".grok/config.toml").read_text() == '[permission]\nask = ["MCPTool(*)"]\n'
        assert kwargs["env"]["GROK_FOLDER_TRUST"] == "0"
        assert os.environ["GROK_FOLDER_TRUST"] == "1"
        assert kwargs["env"].get("GROK_HOME") == os.environ.get("GROK_HOME")
        assert process.sent[0]["params"]["clientCapabilities"]["terminal"] is False
        session = process.sent[1]["params"]
        assert session["cwd"] == str(private_cwd)
        assert session["mcpServers"] == [
            {"name": "browser", "command": "/fake/python", "args": ["-m", "jet_browser.mcp"], "env": []}
        ]
        assert session["_meta"]["yoloMode"] is False
        task = asyncio.create_task(client.prompt("Find this page"))
        await wait_until(lambda: process.prompt_id is not None)
        process.update("agent_message_chunk", content={"type": "text", "text": "Checking "})
        process.update("agent_thought_chunk", content={"type": "text", "text": "private thought"})
        process.update(
            "tool_call",
            toolCallId="tool-1",
            name="browser__read_page",
            title="Read current page",
            status="pending",
            rawInput={"tab_id": "t1"},
        )
        process.update("tool_call_update", toolCallId="tool-1", status="completed", rawOutput={"title": "Example"})
        await wait_until(lambda: any(e.get("status") == "completed" for e in events))
        assert not task.done()
        assert {"type": "text", "text": "Checking "} in events
        completed = next(e for e in events if e.get("status") == "completed")
        assert completed["title"] == "Read current page"
        assert completed["input"] == {"tab_id": "t1"}
        process.update("agent_message_chunk", content={"type": "text", "text": "done."})
        process.finish()
        assert await task == "Checking done."
        process.on_prompt = lambda message: process.finish()
        assert await client.prompt("Again") == ""
        ids = [m["id"] for m in process.sent if "method" in m and "id" in m]
        assert len(ids) == len(set(ids)) == 4
        assert "private thought" not in json.dumps(events)
    finally:
        await client.close()
    assert not Path(args[args.index("--agent-profile") + 1]).exists()


@pytest.mark.parametrize(
    "call,allowed",
    [
        ({"name": "browser__run_task"}, True),
        ({"name": "browser__browser_action"}, True),
        ({"name": "browser__conversation_history"}, True),
        ({"name": "browser__prepare_collection"}, True),
        ({"name": "browser__start_collection"}, True),
        ({"name": "browser__collection_status"}, True),
        ({"name": "browser__control_collection"}, True),
        ({"name": "browser__start_collection_shell"}, False),
        ({"name": "web_fetch", "rawInput": {"url": "https://example.org"}}, True),
        ({"name": "web_search", "rawInput": {"query": "example documentation"}}, True),
        (
            {
                "kind": "fetch",
                "_meta": GROK_WEB_FETCH_META,
                "rawInput": {"variant": "WebFetch", "url": "https://en.wikipedia.org/wiki/Elon_Musk"},
            },
            True,
        ),
        (
            {
                "_meta": {
                    "x.ai/tool": {
                        "version": 1,
                        "name": "web_search",
                        "kind": "web_search",
                        "namespace": "grok_build",
                        "read_only": True,
                    }
                }
            },
            True,
        ),
        ({"title": "web_fetch", "rawInput": {"url": "https://example.org"}}, False),
        ({"name": "foreign__web_fetch", "_meta": GROK_WEB_FETCH_META}, False),
        ({"name": "run_terminal_cmd", "_meta": GROK_WEB_FETCH_META}, False),
        ({"name": "web_fetch", "_meta": GROK_USE_TOOL_META}, False),
        (
            {
                "_meta": {
                    "x.ai/tool": {
                        "version": 1,
                        "name": "web_fetch",
                        "kind": "web_fetch",
                        "namespace": "grok_build",
                        "read_only": False,
                    }
                }
            },
            False,
        ),
        (
            {
                "_meta": {
                    "x.ai/tool": {
                        "version": 1,
                        "name": "web_fetch",
                        "kind": "web_fetch",
                        "namespace": "foreign",
                        "read_only": True,
                    }
                }
            },
            False,
        ),
        (
            {
                "_meta": {
                    "x.ai/tool": {
                        "version": 1,
                        "name": "read_file",
                        "kind": "read_file",
                        "namespace": "grok_build",
                        "read_only": True,
                    }
                }
            },
            False,
        ),
        ({"name": "use_tool", "rawInput": {"tool_name": "browser__read_page", "tool_input": {}}}, True),
        ({"name": "use_tool", "rawInput": {"tool_name": "browser__run_task", "file": "/tmp/spoof"}}, False),
        ({"name": "run_terminal_cmd", "rawInput": {"tool_name": "browser__run_task"}}, False),
        ({"title": "browser__run_task"}, False),
        ({"name": "browser__run_task_extra"}, False),
        ({"name": "other__run_task"}, False),
        ({"name": "use_tool", "rawInput": {"tool_name": "other__run_task"}}, False),
        (
            {
                "title": "browser__list_tabs",
                "_meta": GROK_USE_TOOL_META,
                "rawInput": {"variant": "UseTool", "tool_name": "browser__list_tabs", "tool_input": {}},
            },
            True,
        ),
        (
            {
                "title": "browser__list_tabs",
                "_meta": GROK_USE_TOOL_META,
                "rawInput": {"variant": "UseTool", "tool_name": "foreign__mutate", "tool_input": {}},
            },
            False,
        ),
        (
            {
                "title": "browser__list_tabs",
                "_meta": GROK_USE_TOOL_META,
                "rawInput": {"variant": "UseTool", "tool_name": "browser__list_tabs", "file": "/tmp/request"},
            },
            False,
        ),
        (
            {
                "name": "run_terminal_cmd",
                "_meta": GROK_USE_TOOL_META,
                "rawInput": {"variant": "UseTool", "tool_name": "browser__list_tabs", "tool_input": {}},
            },
            False,
        ),
        (
            {
                "_meta": {"x.ai/tool": {"version": 1, "name": "use_tool", "kind": "use_tool", "namespace": "foreign"}},
                "rawInput": {"variant": "UseTool", "tool_name": "browser__list_tabs", "tool_input": {}},
            },
            False,
        ),
        (
            {
                "_meta": GROK_USE_TOOL_META,
                "rawInput": {"variant": "Shell", "tool_name": "browser__list_tabs", "tool_input": {}},
            },
            False,
        ),
    ],
)
async def test_permission_identifies_exact_tool_and_uses_provided_option_id(rig, call, allowed):
    client, process, events, _ = rig
    try:
        task = asyncio.create_task(client.prompt("Complete this form"))
        await wait_until(lambda: process.prompt_id is not None)
        process.update("tool_call", toolCallId="owned", **{"title": "Observed call", **call})
        # A partial permission request must be merged with the original report.
        process.receive(
            {
                "id": "agent-request",
                "method": "session/request_permission",
                "params": {
                    "sessionId": "session-1",
                    "toolCall": {"toolCallId": "owned"},
                    "options": [
                        {"kind": "allow_always", "optionId": "never-this"},
                        {"kind": "allow_once", "optionId": "actual-allow-id"},
                        {"kind": "reject_once", "optionId": "actual-deny-id"},
                    ],
                },
            }
        )
        await wait_until(lambda: any(m.get("id") == "agent-request" for m in process.sent))
        response = next(m for m in process.sent if m.get("id") == "agent-request")
        assert response["result"]["outcome"] == {
            "outcome": "selected",
            "optionId": "actual-allow-id" if allowed else "actual-deny-id",
        }
        assert any(e.get("status") == ("permission_allowed" if allowed else "permission_denied") for e in events)
        process.finish()
        await task
    finally:
        await client.close()


async def test_unknown_client_methods_and_permissions_without_once_option_fail_closed(rig):
    client, process, _, _ = rig
    try:
        task = asyncio.create_task(client.prompt("Read this"))
        await wait_until(lambda: process.prompt_id is not None)
        process.receive({"id": "fs", "method": "fs/write_text_file", "params": {}})
        process.receive(
            {
                "id": "p",
                "method": "session/request_permission",
                "params": {
                    "sessionId": "session-1",
                    "toolCall": {"name": "browser__read_page"},
                    "options": [{"kind": "allow_always", "optionId": "no"}],
                },
            }
        )
        await wait_until(lambda: any(m.get("id") == "p" for m in process.sent))
        assert next(m for m in process.sent if m.get("id") == "fs")["error"]["code"] == -32601
        assert next(m for m in process.sent if m.get("id") == "p")["result"] == {"outcome": {"outcome": "cancelled"}}
        process.finish()
        await task
    finally:
        await client.close()


@pytest.mark.parametrize("graceful", [True, False])
async def test_cancel_finishes_prompt_and_never_dispatches_second_turn(rig, graceful):
    client, process, events, _ = rig
    process.auto_cancel = graceful
    try:
        task = asyncio.create_task(client.prompt("Long task"))
        await wait_until(lambda: process.prompt_id is not None)
        with pytest.raises(GrokError, match="already running"):
            await client.prompt("Must not queue")
        await client.cancel()
        with pytest.raises(GrokCancelled):
            await asyncio.wait_for(task, 1)
        cancels = [m for m in process.sent if m.get("method") == "session/cancel"]
        assert len(cancels) == 1 and "id" not in cancels[0]
        assert len([m for m in process.sent if m.get("method") == "session/prompt"]) == 1
        assert any(e.get("status") == "cancelled" for e in events)
        assert not client._pending
        if not graceful:
            assert process.returncode is not None
    finally:
        await client.close()


async def test_process_exit_resolves_waiter_without_exposing_stderr(rig):
    client, process, events, _ = rig
    task = asyncio.create_task(client.prompt("Long task"))
    await wait_until(lambda: process.prompt_id is not None)
    process.stderr.feed_data(b"provider-secret must not enter UI logs\n")
    process.terminate()
    with pytest.raises(GrokError, match="closed|exited"):
        await asyncio.wait_for(task, 1)
    assert "provider-secret" not in json.dumps(events)
    assert not client._pending
    await client.close()


async def test_startup_timeout_closes_process_and_pending_requests(rig):
    client, process, _, _ = rig
    process.auto_initialize = False
    with pytest.raises(GrokError, match="timed out"):
        await client.start()
    assert process.returncode is not None
    assert not client._pending
    await client.close()


async def test_cancel_during_startup_and_close_are_bounded(rig):
    client, process, _, _ = rig
    process.auto_initialize = False
    task = asyncio.create_task(client.prompt("Starting"))
    await wait_until(lambda: len(process.sent) == 1)
    await client.cancel()
    with pytest.raises(GrokCancelled):
        await asyncio.wait_for(task, 1)
    assert not any(m.get("method") == "session/prompt" for m in process.sent)
    await client.close()


async def test_external_task_cancellation_does_not_orphan_cli(rig):
    client, process, _, _ = rig
    task = asyncio.create_task(client.prompt("Long task"))
    await wait_until(lambda: process.prompt_id is not None)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert process.returncode is not None
    assert not client._pending
    await client.close()


async def test_remote_error_and_bad_json_resolve_prompt(rig):
    client, process, _, _ = rig
    task = asyncio.create_task(client.prompt("Question"))
    await wait_until(lambda: process.prompt_id is not None)
    process.receive({"id": process.prompt_id, "error": {"code": -32000, "message": "Authentication required"}})
    with pytest.raises(GrokError, match="Authentication required"):
        await asyncio.wait_for(task, 1)
    assert not client._pending
    await client.close()


async def test_foreign_session_updates_are_ignored(rig):
    client, process, events, _ = rig
    try:
        task = asyncio.create_task(client.prompt("Question"))
        await wait_until(lambda: process.prompt_id is not None)
        process.receive(
            {
                "method": "session/update",
                "params": {
                    "sessionId": "foreign",
                    "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "wrong"}},
                },
            }
        )
        process.finish()
        assert await task == ""
        assert not any(e.get("text") == "wrong" for e in events)
    finally:
        await client.close()


def trace_collector(records):
    return lambda event, **attributes: records.append({"event": event, **attributes})


async def test_trace_correlates_protocol_timing_stream_and_tool_without_content(rig, monkeypatch):
    original, process, events, _ = rig
    traces = []
    client = GrokClient(original.cwd, original.mcp_command, events.append, trace=trace_collector(traces))
    private_marker = "sensitive-content-marker"
    monkeypatch.setenv("PROVIDER_TEST_SECRET", private_marker)
    try:
        task = asyncio.create_task(client.prompt(private_marker))
        await wait_until(lambda: process.prompt_id is not None)
        process.stderr.feed_data(f"{private_marker}\n".encode())
        process.update("agent_thought_chunk", content={"type": "text", "text": private_marker})
        for text in ("", private_marker, " done"):
            process.update("agent_message_chunk", content={"type": "text", "text": text})
        process.update(
            "tool_call",
            toolCallId="tool-42",
            title=private_marker,
            kind="read",
            status="pending",
            _meta=GROK_USE_TOOL_META,
            rawInput={
                "variant": "UseTool",
                "tool_name": "browser__read_page",
                "tool_input": {"private": private_marker},
            },
        )
        process.update(
            "tool_call_update",
            toolCallId="tool-42",
            status="completed",
            rawOutput={"page": private_marker},
            content=[{"text": private_marker}],
        )
        process.finish()
        assert await task == private_marker + " done"
    finally:
        await client.close()

    assert private_marker not in json.dumps(traces)
    assert [e["event"] for e in traces if e["event"].startswith("grok.provider.")] == [
        "grok.provider.start",
        "grok.provider.ready",
        "grok.provider.close",
    ]
    sends = [e for e in traces if e["event"] == "grok.acp.request.send"]
    ends = [e for e in traces if e["event"] == "grok.acp.request.end"]
    assert [(e["method"], e["request_id"]) for e in sends] == [
        ("initialize", 1),
        ("session/new", 2),
        ("session/prompt", 3),
    ]
    assert [(e["method"], e["request_id"]) for e in sends] == [(e["method"], e["request_id"]) for e in ends]
    assert all(e["duration_ms"] >= 0 for e in ends)
    assert len([e for e in traces if e["event"] == "grok.stream.first_text"]) == 1
    chunks = [e for e in traces if e["event"] == "grok.stream.text"]
    assert [(e["characters"], e["total_characters"], e["chunks"]) for e in chunks] == [
        (0, 0, 1),
        (len(private_marker), len(private_marker), 2),
        (5, len(private_marker) + 5, 3),
    ]
    tools = [e for e in traces if e["event"] == "grok.tool.update"]
    assert [e["status"] for e in tools] == ["pending", "completed"]
    assert all(
        e["tool_name"] == "browser__read_page"
        and e["tool_call_id"] == "tool-42"
        and e["tool_kind"] == "read"
        and e["identity_source"] == "grok_meta"
        for e in tools
    )
    completed = next(e for e in traces if e["event"] == "grok.prompt.end")
    assert completed["stop_reason"] == "end_turn"
    assert completed["text_characters"] == len(private_marker) + 5 and completed["text_chunks"] == 3
    assert completed["tool_calls"] == 1
    assert completed["duration_ms"] >= 0


@pytest.mark.parametrize(
    "call,options,session_id,expected_name,expected_reason",
    [
        ({"kind": "fetch", "_meta": GROK_WEB_FETCH_META}, True, "session-1", "web_fetch", "allowed_read_only_web"),
        (
            {"_meta": GROK_USE_TOOL_META, "rawInput": {"variant": "UseTool", "tool_name": "browser__read_page"}},
            True,
            "session-1",
            "browser__read_page",
            "allowed_browser_tool",
        ),
        (
            {"name": "use_tool", "rawInput": {"tool_name": "foreign__mutate"}},
            True,
            "session-1",
            "foreign__mutate",
            "tool_identity_not_allowed",
        ),
        ({"title": "web_fetch"}, True, "session-1", None, "missing_programmatic_identity"),
        ({"name": "web_fetch"}, False, "session-1", "web_fetch", "missing_allow_once_option"),
        ({"name": "web_fetch"}, True, "foreign", "web_fetch", "foreign_session"),
    ],
)
async def test_trace_permission_decision_explains_denial_without_raw_input(
    rig, call, options, session_id, expected_name, expected_reason
):
    client, process, _, _ = rig
    traces = []
    client.trace = trace_collector(traces)
    private_marker = "private-permission-argument"
    try:
        task = asyncio.create_task(client.prompt("Read"))
        await wait_until(lambda: process.prompt_id is not None)
        raw = {**call.get("rawInput", {}), "tool_input": {"text": private_marker}, "url": private_marker}
        process.receive(
            {
                "id": "permission-1",
                "method": "session/request_permission",
                "params": {
                    "sessionId": session_id,
                    "toolCall": {**call, "toolCallId": "call-1", "title": private_marker, "rawInput": raw},
                    "options": [
                        {"kind": "allow_once", "optionId": "actual-once"},
                        {"kind": "reject_once", "optionId": "reject-once"},
                    ]
                    if options
                    else [],
                },
            }
        )
        await wait_until(lambda: any(m.get("id") == "permission-1" for m in process.sent))
        decision = next(e for e in traces if e["event"] == "grok.permission.decision")
        assert decision["tool_name"] == expected_name
        assert decision["reason"] == expected_reason
        assert decision["allowed"] is expected_reason.startswith("allowed_")
        assert decision["level"] == ("info" if decision["allowed"] else "warn")
        assert decision["request_id"] == "permission-1" and decision["tool_call_id"] == "call-1"
        assert private_marker not in json.dumps(traces)
        process.finish()
        await task
    finally:
        await client.close()


@pytest.mark.parametrize("exception", [RuntimeError("trace sink failed"), asyncio.CancelledError()])
async def test_trace_sink_failure_cannot_cancel_or_break_provider(rig, exception):
    client, process, _, _ = rig

    def broken_trace(event, **attributes):
        raise exception

    client.trace = broken_trace
    process.on_prompt = lambda message: process.finish()
    assert await client.prompt("Read") == ""
    await client.close()
    assert process.returncode is not None


async def test_trace_callback_can_be_replaced_for_reused_reader_and_counts_reset(rig):
    client, process, _, _ = rig
    first, second = [], []
    client.trace = trace_collector(first)

    def complete(message):
        process.update("agent_message_chunk", content={"type": "text", "text": "x"})
        process.finish()

    process.on_prompt = complete
    try:
        assert await client.prompt("First") == "x"
        first_snapshot = list(first)
        client.trace = trace_collector(second)
        assert await client.prompt("Second") == "x"
        assert first == first_snapshot
        assert not any(e["event"].startswith("grok.provider.") for e in second)
        assert len([e for e in second if e["event"] == "grok.stream.first_text"]) == 1
        assert next(e for e in second if e["event"] == "grok.prompt.end")["text_characters"] == 1
        assert next(e for e in second if e["event"] == "grok.acp.request.send")["request_id"] == 4
    finally:
        await client.close()


@pytest.mark.parametrize("failure", ["remote_error", "timeout", "cancel", "python_cancel"])
async def test_trace_request_and_prompt_terminal_events_cover_failures(rig, failure):
    client, process, _, _ = rig
    traces = []
    client.trace = trace_collector(traces)
    client.prompt_timeout = 0.05
    private_marker = "private-provider-error-details"
    try:
        task = asyncio.create_task(client.prompt("Question"))
        await wait_until(lambda: process.prompt_id is not None)
        if failure == "remote_error":
            process.receive({"id": process.prompt_id, "error": {"code": -32000, "message": private_marker}})
        elif failure == "cancel":
            await client.cancel()
        elif failure == "python_cancel":
            task.cancel()
        with pytest.raises(asyncio.CancelledError if failure == "python_cancel" else GrokError):
            await task
        end_event = "grok.prompt.cancel" if failure in {"cancel", "python_cancel"} else "grok.prompt.error"
        terminal = [e for e in traces if e["event"] in {"grok.prompt.end", "grok.prompt.error", "grok.prompt.cancel"}]
        assert len(terminal) == 1 and terminal[0]["event"] == end_event
        request_end = next(
            e
            for e in traces
            if e.get("method") == "session/prompt" and e["event"] in {"grok.acp.request.end", "grok.acp.request.error"}
        )
        assert request_end["request_id"] == process.prompt_id and request_end["duration_ms"] >= 0
        if failure == "timeout":
            assert request_end["error_type"] == "GrokStalled" and request_end["reason"] == "deadline"
        if failure == "cancel":
            assert any(e["event"] == "grok.prompt.cancel_requested" for e in traces)
            assert any(e["event"] == "grok.acp.notification.send" for e in traces)
        assert private_marker not in json.dumps(traces)
    finally:
        await client.close()


async def test_trace_startup_timeout_has_bounded_safe_failure_events(rig):
    client, process, _, _ = rig
    traces = []
    client.trace = trace_collector(traces)
    process.auto_initialize = False
    with pytest.raises(GrokError, match="timed out"):
        await client.start()
    assert next(e for e in traces if e["event"] == "grok.acp.request.error")["error_type"] == "TimeoutError"
    assert next(e for e in traces if e["event"] == "grok.provider.error")["error_type"] == "GrokError"
    assert next(e for e in traces if e["event"] == "grok.provider.close")["return_code"] == -15
    await client.close()


@pytest.mark.parametrize(
    "name,allowed",
    [
        ("browser__review_collection", True),
        ("browser__collection_review", True),
        ("web_fetch", False),
        ("browser__open_url", False),
    ],
)
async def test_checkpoint_profile_is_narrower_than_general_chat(rig, name, allowed):
    client, process, events, _ = rig
    client.review_only = True
    try:
        task = asyncio.create_task(client.prompt("Review this checkpoint"))
        await wait_until(lambda: process.prompt_id is not None)
        profile = (client._session_cwd / "browser.md").read_text()
        assert "tools: [search_tool, use_tool]\n" in profile
        process.receive(
            {
                "id": "checkpoint-permission",
                "method": "session/request_permission",
                "params": {
                    "sessionId": "session-1",
                    "toolCall": {"toolCallId": "review", "name": name},
                    "options": [{"kind": "allow_once", "optionId": "yes"}, {"kind": "reject_once", "optionId": "no"}],
                },
            }
        )
        await wait_until(lambda: any(m.get("id") == "checkpoint-permission" for m in process.sent))
        result = next(m for m in process.sent if m.get("id") == "checkpoint-permission")
        assert result["result"]["outcome"]["optionId"] == ("yes" if allowed else "no")
        process.finish()
        await task
    finally:
        await client.close()


def browser_tool(process, call_id, tool, status):
    process.update(
        "tool_call",
        toolCallId=call_id,
        title="Use Tool",
        kind="other",
        status=status,
        _meta=GROK_USE_TOOL_META,
        rawInput={"variant": "UseTool", "tool_name": "browser__" + tool, "tool_input": {}},
    )


async def test_silent_provider_after_sdk_is_stalled_with_stage_and_no_retry(rig):
    """The 2026-09-28 incident shape: tools succeed, then the provider goes quiet."""
    client, process, events, _ = rig
    traces = []
    client.trace = trace_collector(traces)
    client.idle_timeout = 0.1
    client.prompt_timeout = 5
    task = asyncio.create_task(client.prompt("Organize my bookmarks"))
    await wait_until(lambda: process.prompt_id is not None)
    for index, tool in enumerate(("list_tabs", "inspect_collection_source", "workflow_sdk")):
        browser_tool(process, f"call-{index}", tool, "pending")
        process.update("tool_call_update", toolCallId=f"call-{index}", status="completed")
    process.update("agent_thought_chunk", content={"type": "text", "text": "private plan"})
    with pytest.raises(GrokStalled) as raised:
        await asyncio.wait_for(task, 2)
    stalled = raised.value
    assert stalled.reason == "idle" and stalled.stage == "thinking"
    assert stalled.completed_tools == ("list_tabs", "inspect_collection_source", "workflow_sdk")
    assert "after reading the workflow guide" in str(stalled) and "no tool will be retried" in str(stalled)
    assert process.returncode is not None and not client._pending
    assert [m.get("method") for m in process.sent].count("session/prompt") == 1
    assert any(e.get("type") == "error" and "workflow guide" in e["message"] for e in events)
    stages = [(e["stage"], e["tool_name"]) for e in traces if e["event"] == "grok.prompt.stage"]
    assert ("tool", "workflow_sdk") in stages and stages[-1] == ("thinking", None)
    error = next(e for e in traces if e["event"] == "grok.acp.request.error")
    assert error["error_type"] == "GrokStalled" and error["reason"] == "idle"
    assert "private plan" not in json.dumps(traces) + json.dumps(events)
    await client.close()


async def test_streaming_reasoning_keeps_turn_alive_and_traces_only_volume(rig):
    client, process, events, _ = rig
    traces = []
    client.trace = trace_collector(traces)
    client.idle_timeout = 0.15
    client.heartbeat_interval = 0.03
    client.prompt_timeout = 5
    task = asyncio.create_task(client.prompt("Question"))
    await wait_until(lambda: process.prompt_id is not None)
    for _ in range(8):
        process.update("agent_thought_chunk", content={"type": "text", "text": "secret-thought"})
        await asyncio.sleep(0.05)
    process.update("agent_message_chunk", content={"type": "text", "text": "Answer"})
    process.finish()
    assert await asyncio.wait_for(task, 2) == "Answer"
    beats = [e for e in traces if e["event"] == "grok.prompt.activity"]
    assert beats and beats[-1]["thought_chunks"] >= 1
    assert beats[-1]["thought_characters"] == beats[-1]["thought_chunks"] * len("secret-thought")
    assert "secret-thought" not in json.dumps(traces) + json.dumps(events)
    await client.close()


async def test_running_tool_suspends_idle_limit_but_not_turn_ceiling(rig):
    client, process, _, _ = rig
    client.idle_timeout = 0.05
    client.prompt_timeout = 5
    task = asyncio.create_task(client.prompt("Open a page"))
    await wait_until(lambda: process.prompt_id is not None)
    browser_tool(process, "slow", "run_task", "in_progress")
    await asyncio.sleep(0.2)
    assert not task.done() and client.stage["stage"] == "tool" and client.stage["tool"] == "run_task"
    process.update("tool_call_update", toolCallId="slow", status="completed")
    process.finish()
    await asyncio.wait_for(task, 2)
    await client.close()


async def test_tool_that_never_finishes_still_hits_turn_ceiling(rig):
    client, process, _, _ = rig
    client.idle_timeout = 0.05
    client.prompt_timeout = 0.2
    task = asyncio.create_task(client.prompt("Open another page"))
    await wait_until(lambda: process.prompt_id is not None)
    browser_tool(process, "stuck", "run_task", "in_progress")
    with pytest.raises(GrokStalled) as raised:
        await asyncio.wait_for(task, 2)
    assert raised.value.reason == "deadline" and "while running run_task" in str(raised.value)
    await client.close()


async def test_grok_extension_updates_count_as_provider_activity(rig):
    client, process, _, _ = rig
    client.idle_timeout = 0.1
    client.prompt_timeout = 5
    task = asyncio.create_task(client.prompt("Question"))
    await wait_until(lambda: process.prompt_id is not None)
    for _ in range(6):
        process.receive({"method": "_x.ai/session/update", "params": {
            "sessionId": "session-1", "update": {"sessionUpdate": "hook_execution", "runs": []}}})
        await asyncio.sleep(0.04)
    process.finish()
    assert await asyncio.wait_for(task, 2) == ""
    await client.close()


async def test_stop_during_silent_turn_is_bounded_and_not_reported_as_stall(rig):
    client, process, _, _ = rig
    client.idle_timeout = 10
    process.auto_cancel = False
    task = asyncio.create_task(client.prompt("Question"))
    await wait_until(lambda: process.prompt_id is not None)
    await client.cancel()
    with pytest.raises(GrokCancelled):
        await asyncio.wait_for(task, 1)
    assert process.returncode is not None
    await client.close()


@pytest.mark.parametrize(
    "name,allowed",
    [
        ("browser__run_workflow", True),
        ("browser__workflow_records", True),
        ("browser__list_tabs", True),  # Read-only; a denial cancelled a real review turn.
        ("browser__inspect_collection_source", False),
        ("browser__browser_action", False),
        ("browser__open_url", False),
        ("web_fetch", False),
    ],
)
async def test_workflow_review_profile_allows_read_only_tab_listing(rig, name, allowed):
    client, process, _, _ = rig
    client.review_only = "workflow"
    try:
        task = asyncio.create_task(client.prompt("Review this workflow checkpoint"))
        await wait_until(lambda: process.prompt_id is not None)
        process.receive({"id": "wf-permission", "method": "session/request_permission", "params": {
            "sessionId": "session-1", "toolCall": {"toolCallId": "review", "name": name},
            "options": [{"kind": "allow_once", "optionId": "yes"}, {"kind": "reject_once", "optionId": "no"}]}})
        await wait_until(lambda: any(m.get("id") == "wf-permission" for m in process.sent))
        result = next(m for m in process.sent if m.get("id") == "wf-permission")
        assert result["result"]["outcome"]["optionId"] == ("yes" if allowed else "no")
        process.finish()
        await task
    finally:
        await client.close()


async def test_provider_ended_turn_is_an_error_not_a_user_stop(rig):
    client, process, events, _ = rig
    task = asyncio.create_task(client.prompt("Review"))
    await wait_until(lambda: process.prompt_id is not None)
    browser_tool(process, "denied", "list_tabs", "pending")
    process.update("tool_call_update", toolCallId="denied", status="failed")
    process.finish("cancelled")
    with pytest.raises(GrokError, match="ended the turn itself after a denied tool") as raised:
        await asyncio.wait_for(task, 2)
    assert not isinstance(raised.value, GrokCancelled)
    await client.close()


async def test_grok_child_uses_the_jet_owned_home(rig, tmp_path):
    original, process, events, launches = rig
    home = tmp_path / "grok-home"
    client = GrokClient(original.cwd, original.mcp_command, events.append, grok_home=home)
    client.startup_timeout = 0.1
    try:
        await client.start()
        env = launches[-1][1]["env"]
        assert env["GROK_HOME"] == str(home) and env["GROK_FOLDER_TRUST"] == "0"
    finally:
        await client.close()


async def test_grok_client_launches_the_chosen_binary(rig, tmp_path):
    original, process, events, launches = rig
    chosen = tmp_path / "grok-1.0.50"
    client = GrokClient(original.cwd, original.mcp_command, events.append, executable=chosen)
    client.startup_timeout = 0.1
    try:
        await client.start()
        assert launches[-1][0][0] == str(chosen)
    finally:
        await client.close()
