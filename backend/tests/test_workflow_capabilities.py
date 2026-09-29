import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

from jet_browser.workflow_capabilities import WorkflowCapabilities, WorkflowStopped
from jet_browser.workflow_manager import WorkflowManager
from jet_browser.workflow_store import CAPABILITIES, WorkflowStore

URL = "https://x.com/i/bookmarks"
ITEM = {
    "url": "https://x.com/author/status/123",
    "text": "An open source mobile app",
    "truncated": True,
    "author": "Author",
    "published_at": "2026-09-28T10:00:00Z",
    "captured_at": 123.0,
}


def definition(source="return true;"):
    return dict(
        title="Bookmarks",
        source=source,
        tab_id="tab",
        start_url=URL,
        source_kind="x_bookmarks",
        model="qwen4b_semif_shared",
        categories=[
            dict(id="mobile", name="Mobile", description="Mobile apps"),
            dict(id="web", name="Web", description="Web apps"),
        ],
        capabilities=list(CAPABILITIES),
        limits=dict(max_seconds=60, max_calls=100, max_items=10),
    )


class Bridge:
    host_id = "host"
    active_tab_id = "other"
    supports_background = True

    def __init__(self):
        self.tabs = [dict(id="tab", url=URL)]
        self.tab_owners = {}

    def tab(self, tid):
        return next(t for t in self.tabs if t["id"] == tid)

    def claim_tab(self, tid, owner):
        self.tab_owners[tid] = owner

    def release_tab(self, tid, owner):
        if self.tab_owners.get(tid) == owner:
            self.tab_owners.pop(tid)

    def tab_owner(self, tid):
        return self.tab_owners.get(tid)


class Collector:
    def __init__(self, bridge, plan, stopped, **kwargs):
        self.calls = []

    async def read(self):
        return dict(items=[ITEM.copy()], loading=False, end_of_feed=False)

    async def scroll(self, snapshot):
        self.calls.append(snapshot)
        return dict(items=[], loading=False, end_of_feed=True)


class Worker:
    lock = threading.RLock()

    def __init__(self):
        self.models = []

    def predict(self, mode, req):
        self.models.append(mode)
        assert mode == "qwen4b_semif_shared"
        return {
            "model": "pinned-qwen-id",
            "answers": {
                k: dict(valid=True, label="yes" if k == "mobile" else "no", probabilities=None, confidence=None)
                for k in req["questions"]
            },
        }

    def summarize(self, mode, text):
        return dict(summary="An open source mobile application.", model="pinned-qwen-id")


def world(tmp_path):
    store = WorkflowStore(tmp_path)
    row = store.save("session", definition())
    wid = row["id"]
    store.update("session", wid, status="running")
    service = SimpleNamespace(store=SimpleNamespace(current_id="session"), bridge=Bridge())
    stop = threading.Event()
    events = []
    worker = Worker()

    async def recover(bridge, item, tab, stopped):
        return dict(
            ITEM,
            text=ITEM["text"] + " with a design system and documented examples.",
            truncated=False,
            captured_at=124.0,
        )

    cap = WorkflowCapabilities(
        service,
        store,
        "session",
        wid,
        stop,
        lambda event, args: events.append((event, args)),
        worker=worker,
        collector_factory=Collector,
        recover=recover,
    )
    return store, wid, service, stop, events, worker, cap


async def test_capture_recover_classify_patch_and_provenance(tmp_path):
    store, wid, service, stop, events, worker, cap = world(tmp_path)
    await cap.open()
    obs = await cap.feed_observe({})
    item = obs["items"][0]
    await cap.post_recover({"item_id": item["id"]})
    result = await cap.model_classify({"item_id": item["id"]})
    assert result["tags"] == ["mobile"]
    summary = await cap.model_summarize({"item_id": item["id"]})
    saved = await cap.records_put(dict(item_id=item["id"], tags=result["tags"], summary=summary["summary"]))
    row = store.get_record("session", wid, item["id"])
    assert row["original_capture"]["truncated"] is True and row["truncated"] is False
    assert row["audit"][0]["kind"] == "source_recovery"
    assert service.bridge.active_tab_id == "other"
    assert store.records("session", wid)["total"] == 1
    await cap.records_patch(
        dict(item_id=item["id"], expected_revision=saved["revision"], patch={"tags": ["mobile", "web"]})
    )
    assert store.get_record("session", wid, item["id"])["tags"] == ["mobile", "web"]
    stop.set()
    with pytest.raises(WorkflowStopped):
        await cap.feed_scroll({"observation_id": obs["observation_id"]})
    assert not cap.collector.calls
    cap.close()
    assert not service.bridge.tab_owners
    store.close()


async def test_source_change_and_invented_evidence_are_rejected(tmp_path):
    store, wid, service, stop, events, worker, cap = world(tmp_path)
    await cap.open()
    obs = await cap.feed_observe({})
    with pytest.raises(ValueError):
        await cap.records_put(dict(item_id="f" * 64, tags=["mobile"], summary="fake"))
    with pytest.raises(ValueError):
        await cap.records_put(dict(item_id=obs["items"][0]["id"], text="invented", tags=[], summary=""))
    service.bridge.tabs[0]["url"] = "https://x.com/home"
    with pytest.raises(ValueError, match="source changed"):
        await cap.feed_scroll({"observation_id": obs["observation_id"]})
    assert not cap.collector.calls
    cap.close()
    store.close()


async def test_real_javascript_yields_revises_and_resumes_saved_records(tmp_path):
    executable = Path(__file__).resolve().parents[2] / ".runtime/bin/jet-workflow"
    if not executable.exists():
        pytest.skip("Build workflow runtime")
    store = WorkflowStore(tmp_path)
    service = SimpleNamespace(
        store=SimpleNamespace(current_id="session"),
        bridge=Bridge(),
        collections=SimpleNamespace(running=False),
        tasks=SimpleNamespace(running=False),
        recovery_active=False,
        activity=lambda _: None,
    )
    first = """const item = jet.call('feed.observe', {}).items[0];
    const tags = jet.call('model.classify', {item_id:item.id}).tags;
    jet.call('records.put', {item_id:item.id,tags:tags,summary:'Initial summary'});
    jet.call('run.checkpoint', {state:{item_id:item.id},status:'review',summary:'First sample'});
    jet.call('feed.scroll', {});"""
    row = store.save("session", definition(first))
    wid = row["id"]

    def factory(s, st, sid, wid, stop, progress):
        return WorkflowCapabilities(s, st, sid, wid, stop, progress, worker=Worker(), collector_factory=Collector)

    manager = WorkflowManager(service, store, capability_factory=factory, executable=executable)
    await manager.start("session", wid)
    await manager.job
    row = store.get("session", wid)
    assert row["status"] == "paused" and row["error"] == "checkpoint_review"
    assert row["counters"]["saved"] == 1 and row["counters"]["scrolls"] == 0
    source = """const rows=jet.call('records.list',{}).items;
    jet.call('records.patch',{item_id:rows[0].id,expected_revision:rows[0].revision,patch:{summary:'Repaired summary'}});
    jet.call('run.checkpoint',{state:{done:true},status:'complete',summary:'Done'});"""
    store.save("session", definition(source), workflow_id=wid, expected_revision=1)
    await manager.start("session", wid)
    await manager.job
    row = store.get("session", wid)
    assert row["status"] == "completed", row["error"]
    assert row["counters"]["saved"] == 1 and row["revision"] == 2
    assert store.records("session", wid)["items"][0]["summary"] == "Repaired summary"
    assert not service.bridge.tab_owners
    store.close()


async def test_capability_manifest_is_enforced_by_real_runtime(tmp_path):
    executable = Path(__file__).resolve().parents[2] / ".runtime/bin/jet-workflow"
    if not executable.exists():
        pytest.skip("Build workflow runtime")
    store, wid, service, stop, events, worker, cap = world(tmp_path)
    service.collections = SimpleNamespace(running=False)
    service.tasks = SimpleNamespace(running=False)
    service.recovery_active = False
    store.update("session", wid, status="paused")
    d = definition("jet.call('feed.scroll',{});")
    d["capabilities"] = ["feed.observe"]
    store.save("session", d, workflow_id=wid, expected_revision=1)
    manager = WorkflowManager(service, store, capability_factory=lambda *args: cap, executable=executable)
    await manager.start("session", wid)
    await manager.job
    assert "capability is not enabled" in store.get("session", wid)["error"]
    assert not cap.collector.calls
    store.close()


async def test_blocked_recovery_has_explicit_script_branch_and_preserves_source(tmp_path):
    from jet_browser.post_recovery import RecoveryBlocked

    store, wid, service, stop, events, worker, cap = world(tmp_path)

    async def blocked(*args):
        raise RecoveryBlocked("deleted")

    cap.recover = blocked
    await cap.open()
    item = (await cap.feed_observe({}))["items"][0]
    outcome = await cap.post_recover({"item_id": item["id"]})
    assert outcome == {"status": "blocked", "blocked": True, "reason": "deleted"}
    row = store.get_record("session", wid, item["id"])
    assert row["truncated"] is True
    assert row["text"] == ITEM["text"]
    assert not row["summary"] and not row["tags"]
    assert not worker.models
    cap.close()
    store.close()
