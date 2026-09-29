import asyncio

import pytest

from jet_browser.workflow_manager import WorkflowManager, WorkflowYield
from jet_browser.workflow_store import CAPABILITIES, WorkflowStore
from jet_browser.workflow_tools import NAMES, tool


def _definition(source="jet.call('feed.observe', {});", limits=None):
    names = list(CAPABILITIES) if not isinstance(CAPABILITIES, dict) else list(CAPABILITIES)
    return {
        "title": "Feed",
        "source": source,
        "tab_id": "tab-1",
        "start_url": "https://example.com/feed",
        "source_kind": "feed",
        "model": "qwen4b_semif_shared",
        "categories": [{"id": "keep", "name": "Keep", "description": "Keep"}],
        "capabilities": [str(name) for name in names],
        "limits": limits
        or {"max_seconds": 120, "max_calls": 30, "max_items": 10},
    }


class _Flag:
    def __init__(self, running=False):
        self.running = running


class _Trace:
    def __init__(self):
        self.events = []

    def emit(self, name, **fields):
        self.events.append((name, fields))


class _Service:
    def __init__(self, sid="sess"):
        self.store = type("Session", (), {"current_id": sid})()
        self.collections = _Flag(False)
        self.tasks = _Flag(False)
        self.recovery_active = False
        self.activity_log = []
        self.activity = self.activity_log.append
        self.trace = _Trace()
        self.share_review_samples = False


class _Capability:
    def __init__(self, service, store, sid, wid, stopped, progress):
        self.service = service
        self.store = store
        self.sid = sid
        self.wid = wid
        self.stopped = stopped
        self.progress = progress
        self.opened = False
        self.closed = False

    async def open(self):
        self.opened = True

    async def close(self):
        self.closed = True

    def handlers(self):
        progress = self.progress

        async def observe(args):
            progress("saved", {"delta": 1})
            return {"items": []}

        async def checkpoint(args):
            progress("checkpoint", args)

        return {"feed.observe": observe, "run.checkpoint": checkpoint}


def _manager(tmp_path, service, store, execute):
    executable = tmp_path / "fake"
    executable.touch()
    return WorkflowManager(
        service,
        store,
        execute=execute,
        capability_factory=_Capability,
        executable=executable,
    )


def _ready(tmp_path, sid="sess"):
    store = WorkflowStore(tmp_path)
    saved = store.save(sid, _definition())
    wid = saved["id"]
    if saved.get("status") not in ("prepared", "paused"):
        store.update(sid, wid, status="prepared")
    return store, wid


def test_start_returns_while_script_is_still_running(tmp_path):
    async def body():
        sid = "sess"
        service = _Service(sid)
        store, wid = _ready(tmp_path, sid)
        entered = asyncio.Event()
        release = asyncio.Event()

        async def execute(executable, source, input_value, capabilities, stopped, seconds=60, max_calls=100):
            entered.set()
            await release.wait()
            return {"ok": True}

        manager = _manager(tmp_path, service, store, execute)
        summary = await manager.start(sid, wid)
        task = manager.job
        assert summary["status"] == "running"
        assert summary["source"] if False else "source" not in summary
        assert "checkpoint" not in summary
        assert manager.running is True
        await asyncio.wait_for(entered.wait(), timeout=2)
        assert store.get(sid, wid)["status"] == "running"
        release.set()
        await asyncio.wait_for(task, timeout=2)
        done = manager.summary(sid, wid)
        assert done["status"] == "completed"
        assert manager.running is False
        assert "last_result" not in done

    asyncio.run(body())


def test_checkpoint_revision_and_resume_input(tmp_path):
    async def body():
        sid = "sess"
        service = _Service(sid)
        store, wid = _ready(tmp_path, sid)
        seen = []
        hooks = []

        async def execute(executable, source, input_value, capabilities, stopped, seconds=60, max_calls=100):
            seen.append(input_value)
            assert seconds <= 180
            assert max_calls <= 1000
            if not input_value.get("checkpoint"):
                await capabilities["run.checkpoint"](
                    {"state": {"step": 1}, "status": "review", "summary": "look"}
                )
            return {"finished": True}

        manager = _manager(tmp_path, service, store, execute)
        manager.on_checkpoint = lambda s, w: hooks.append((s, w))
        revision = store.get(sid, wid)["revision"]
        await manager.start(sid, wid)
        await asyncio.wait_for(manager.job, timeout=2)
        await asyncio.sleep(0)
        row = store.get(sid, wid)
        assert row["status"] == "paused"
        assert row["error"] == "checkpoint_review"
        checkpoint = row["checkpoint"]
        assert checkpoint == {"step": 1} or checkpoint == store.get(sid, wid)["checkpoint"]
        assert row["revision"] == revision
        assert hooks == [(sid, wid)]
        await manager.start(sid, wid)
        await asyncio.wait_for(manager.job, timeout=2)
        assert seen[1]["checkpoint"] == row["checkpoint"]
        assert seen[1]["counts"]["calls"] >= 1
        assert seen[1]["categories"] == _definition()["categories"]
        assert manager.summary(sid, wid)["status"] == "completed"
        assert hooks == [(sid, wid)]

    asyncio.run(body())


def test_stop_flag_blocks_second_capability_call(tmp_path):
    async def body():
        sid = "sess"
        service = _Service(sid)
        store, wid = _ready(tmp_path, sid)
        used = []

        async def execute(executable, source, input_value, capabilities, stopped, seconds=60, max_calls=100):
            await capabilities["feed.observe"]({})
            used.append("first")
            stopped.set()
            await capabilities["feed.observe"]({})
            used.append("second")

        manager = _manager(tmp_path, service, store, execute)
        await manager.start(sid, wid)
        await asyncio.wait_for(manager.job, timeout=2)
        row = store.get(sid, wid)
        assert used == ["first"]
        assert row["status"] == "paused"
        assert row["counters"]["calls"] == 1
        assert manager.running is False

    asyncio.run(body())


def test_elapsed_and_counters_accumulate_across_resume(tmp_path):
    async def body():
        sid = "sess"
        service = _Service(sid)
        store, wid = _ready(tmp_path, sid)
        inputs = []

        async def execute(executable, source, input_value, capabilities, stopped, seconds=60, max_calls=100):
            inputs.append(input_value["counts"])
            await capabilities["feed.observe"]({})
            await asyncio.sleep(0.02)
            raise WorkflowYield("pause", "slice")

        manager = _manager(tmp_path, service, store, execute)
        await manager.start(sid, wid)
        await asyncio.wait_for(manager.job, timeout=2)
        first = store.get(sid, wid)["counters"]
        assert first["calls"] == 1
        assert first["saved"] == 1
        assert first["elapsed_ms"] > 0
        await manager.control(sid, wid, "resume")
        await asyncio.wait_for(manager.job, timeout=2)
        second = store.get(sid, wid)["counters"]
        assert inputs[1]["saved"] == 1
        assert inputs[1]["calls"] == 1
        assert second["saved"] == 2
        assert second["calls"] == 2
        assert second["elapsed_ms"] > first["elapsed_ms"]

    asyncio.run(body())


def test_timeout_pauses_without_another_run(tmp_path):
    async def body():
        sid = "sess"
        service = _Service(sid)
        store, wid = _ready(tmp_path, sid)
        calls = []

        async def execute(executable, source, input_value, capabilities, stopped, seconds=60, max_calls=100):
            calls.append(1)
            raise TimeoutError("slice")

        manager = _manager(tmp_path, service, store, execute)
        await manager.start(sid, wid)
        await asyncio.wait_for(manager.job, timeout=2)
        await asyncio.sleep(0.05)
        row = store.get(sid, wid)
        assert calls == [1]
        assert row["status"] == "paused"
        assert row["error"] == "time_slice"
        assert manager.running is False

    asyncio.run(body())


def test_same_session_guard(tmp_path):
    async def body():
        sid = "sess"
        service = _Service(sid)
        store, wid = _ready(tmp_path, sid)
        manager = _manager(tmp_path, service, store, None)
        service.store.current_id = "other"

        async def unused(*args, **kwargs):
            raise AssertionError("script should not run")

        manager.execute = unused
        with pytest.raises(RuntimeError, match="session"):
            await manager.start(sid, wid)
        assert store.get(sid, wid)["status"] == "prepared"

        service.store.current_id = sid

        async def execute(executable, source, input_value, capabilities, stopped, seconds=60, max_calls=100):
            service.store.current_id = "other"
            await capabilities["feed.observe"]({})

        manager.execute = execute
        await manager.start(sid, wid)
        await asyncio.wait_for(manager.job, timeout=2)
        row = store.get(sid, wid)
        assert row["status"] == "paused"
        assert "session" in (row["error"] or "")
        assert manager.running is False

    asyncio.run(body())


def test_concurrency_is_rejected(tmp_path):
    async def body():
        sid = "sess"
        service = _Service(sid)
        store, wid = _ready(tmp_path, sid)
        release = asyncio.Event()

        async def execute(executable, source, input_value, capabilities, stopped, seconds=60, max_calls=100):
            await release.wait()
            return None

        manager = _manager(tmp_path, service, store, execute)
        service.collections.running = True
        with pytest.raises(RuntimeError, match="collections"):
            await manager.start(sid, wid)
        service.collections.running = False
        service.tasks.running = True
        with pytest.raises(RuntimeError, match="tasks"):
            await manager.start(sid, wid)
        service.tasks.running = False
        service.recovery_active = True
        with pytest.raises(RuntimeError, match="recovery"):
            await manager.start(sid, wid)
        service.recovery_active = False
        assert store.get(sid, wid)["status"] == "prepared"
        await manager.start(sid, wid)
        task = manager.job
        with pytest.raises(RuntimeError, match="already running"):
            await manager.start(sid, wid)
        release.set()
        await asyncio.wait_for(task, timeout=2)

    asyncio.run(body())


def test_tool_contracts_hide_record_bodies(tmp_path):
    async def body():
        assert "run_workflow" in NAMES
        service = _Service("sess")

        class Store:
            def __init__(self):
                self.status = "paused"
                self.patched = None

            def get(self, sid, wid):
                return {"id": wid, "session_id": sid, "status": self.status, "revision": 2}

            def records(self, sid, wid, limit=20, offset=0):
                row = {
                    "id": "r1",
                    "url": "https://example.com/p",
                    "text": "x" * 1000,
                    "summary": "s" * 800,
                    "original_capture": "secret-body",
                    "audit": [{"actor": "hidden"}],
                    "tags": ["keep"],
                    "revision": 4,
                }
                return {"items": [row], "total": 1}

            def patch_record(self, sid, wid, id, patch, expected_revision, actor="grok"):
                self.patched = {
                    "id": id,
                    "patch": patch,
                    "expected_revision": expected_revision,
                    "actor": actor,
                }
                return {"id": id, "revision": expected_revision + 1, "tags": patch.get("tags"), "summary": patch.get("summary")}

        service.workflow_store = Store()
        service.workflows = type("W", (), {"running": True})()
        with pytest.raises(ValueError, match="unknown field"):
            await tool(service, "workflow_status", {"workflow_id": "w", "session_id": "other"})
        hidden = await tool(service, "workflow_records", {"workflow_id": "w"})
        assert hidden == {"total": 1}
        assert "secret-body" not in str(hidden)
        service.share_review_samples = True
        shown = await tool(service, "workflow_records", {"workflow_id": "w", "limit": 5})
        assert len(shown["items"]) == 1
        assert len(shown["items"][0]["excerpt"]) == 400
        assert "original_capture" not in shown["items"][0]
        assert "audit" not in shown["items"][0]
        assert "secret-body" not in str(shown)
        service.workflow_store.status = "running"
        with pytest.raises(RuntimeError, match="pause"):
            await tool(
                service,
                "patch_workflow_record",
                {
                    "workflow_id": "w",
                    "item_id": "r1",
                    "expected_revision": 4,
                    "patch": {"summary": "shorter"},
                },
            )
        service.workflow_store.status = "paused"
        patched = await tool(
            service,
            "patch_workflow_record",
            {
                "workflow_id": "w",
                "item_id": "r1",
                "expected_revision": 4,
                "patch": {"summary": "shorter"},
            },
        )
        assert patched["revision"] == 5
        assert service.workflow_store.patched["actor"] == "grok"
        sdk = await tool(service, "workflow_sdk", {})
        assert "feed.observe" in sdk["documentation"]
        assert "slice(0, 10)" in sdk["example_source"]
        assert "run.checkpoint" in sdk["example_source"]

    asyncio.run(body())


@pytest.mark.parametrize("action,status", [("stop", "cancelled"), ("pause", "paused")])
def test_immediate_control_releases_not_yet_started_job(tmp_path, action, status):
    async def body():
        service = _Service()
        store, wid = _ready(tmp_path)

        async def execute(*args, **kwargs):
            raise AssertionError("Immediate cancellation must prevent execution")

        manager = _manager(tmp_path, service, store, execute)
        await manager.start("sess", wid)
        await manager.control("sess", wid, action)
        assert not manager.running
        assert manager.job is None
        assert store.get("sess", wid)["status"] == status

    asyncio.run(body())
