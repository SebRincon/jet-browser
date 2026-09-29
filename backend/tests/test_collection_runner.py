import asyncio
import threading

import pytest

from jet_browser.collection_plan import CollectionPlan
from jet_browser.collection_runner import CollectionManager
from jet_browser.collection_store import CollectionStore

ROOT = "https://example.test/"


class Bridge:
    active_tab_id = "tab"
    host_id = "host"

    def __init__(self):
        self.current = ROOT
        self.reads = []
        self.navigations = []
        self.graph = {
            ROOT: ["a", "b", "a#duplicate", "https://else.test/", "a?q=1"],
            ROOT + "a": [],
            ROOT + "b": [],
            ROOT + "a?q=1": [],
        }

    def tab(self, value):
        return value


class Collector:
    def __init__(self, bridge, plan, stopped, expected_url=None):
        self.bridge, self.plan, self.stopped = bridge, plan, stopped

    async def read(self, url, navigate=True):
        b = self.bridge
        b.reads.append((url, navigate))
        if navigate and b.current != url:
            b.navigations.append(url)
            b.current = url
        if not navigate:
            assert b.current == url
        return {
            "url": b.current,
            "title": "Page",
            "text": "review" if url.endswith("/b") else "Documentation",
            "captured_at": 123.0,
            "truncated": False,
            "links": [x if x.startswith("https:") else ROOT + x for x in b.graph.get(url, [])],
        }


def classify(plan, text, stopped=None):
    return {
        "label_id": "needs_review" if text == "review" else "docs",
        "taxonomy_version": 1,
        "classifier_revision": "collection-choice-v1",
        "model": "fake@1",
        "confidence": None,
        "inference_ms": 1.0,
        "reason": None,
        "excerpt_chars": len(text),
        "model_calls": 1,
    }


def setup(tmp_path, *, max_pages=10, classifier=classify, collector=Collector):
    store = CollectionStore(tmp_path)
    bridge = Bridge()
    plan = CollectionPlan.from_request(
        {
            "request": "Collect docs",
            "title": "Docs",
            "categories": [{"id": "docs", "name": "Documentation", "description": "Technical guides"}],
            "max_pages": max_pages,
        },
        start_url=ROOT,
        tab_id="tab",
        model="lfm_rlcd",
    )
    run = store.create("session", "turn", plan)
    manager = CollectionManager(store, bridge, classifier=classifier, collector_factory=collector)
    return store, bridge, run["id"], manager


async def finish(m, rid):
    return await m.wait("session", rid, 5)


async def test_graph_dedup_scope_counts_and_completion(tmp_path):
    store, b, rid, m = setup(tmp_path)
    await m.start("session", rid)
    r = await finish(m, rid)
    assert (r["status"], r["reason"]) == ("completed", "observed_frontier_exhausted")
    assert r["counters"]["pages"] == 4 and r["counters"]["classified"] == 3 and r["counters"]["needs_review"] == 1
    assert r["counters"]["model_calls"] == 4 and len(b.navigations) == 3
    assert store.items("session", rid)["total"] == 4
    assert all(url.startswith(ROOT) for url in b.navigations)
    store.close()


async def test_exact_budget_and_partial_budget_are_distinct(tmp_path):
    store, b, rid, m = setup(tmp_path, max_pages=1)
    b.graph = {ROOT: []}
    await m.start("session", rid)
    assert (await finish(m, rid))["status"] == "completed"
    store.close()
    store, b, rid, m = setup(tmp_path / "second", max_pages=2)
    await m.start("session", rid)
    r = await finish(m, rid)
    assert r["status"] == "partial" and r["reason"] == "page_budget" and r["counters"]["pages"] == 2
    store.close()


async def test_failed_inference_keeps_pending_page_for_passive_resume(tmp_path):
    def fail(*a, **k):
        raise RuntimeError("worker unavailable")

    store, b, rid, m = setup(tmp_path, classifier=fail)
    await m.start("session", rid)
    r = await finish(m, rid)
    assert r["status"] == "paused" and r["reason"] == "model_unavailable"
    cp = store.get("session", rid)["checkpoint"]
    assert cp["pending_url"] == ROOT and cp["visited"] == []
    assert r["counters"]["pages"] == 0 and store.items("session", rid)["total"] == 0
    m.classifier = classify
    await m.control("session", rid, "resume")
    assert (await finish(m, rid))["status"] == "completed"
    assert b.reads[1] == (ROOT, False)
    store.close()


async def test_immediate_stop_does_not_leave_running_record(tmp_path):
    store, b, rid, m = setup(tmp_path)
    await m.start("session", rid)
    r = await m.control("session", rid, "stop")
    assert r["status"] == "cancelled" and not m.running and not b.reads
    assert store.items("session", rid)["total"] == 0
    store.close()


@pytest.mark.parametrize("action", ["pause", "stop"])
async def test_control_during_classification_fences_next_dispatch(tmp_path, action):
    entered = threading.Event()
    release = threading.Event()

    def slow(*a, **k):
        entered.set()
        release.wait(3)
        return classify(*a, **k)

    store, b, rid, m = setup(tmp_path, classifier=slow)
    await m.start("session", rid)
    assert await asyncio.to_thread(entered.wait, 2)
    await m.control("session", rid, action)
    release.set()
    r = await finish(m, rid)
    assert len(b.reads) == 1 and r["status"] == ("paused" if action == "pause" else "cancelled")
    assert store.items("session", rid)["total"] == (1 if action == "pause" else 0)
    if action == "pause":
        m.classifier = classify
        await m.control("session", rid, "resume")
        assert (await finish(m, rid))["status"] == "completed"
        assert len(b.reads) == 4
    store.close()


async def test_restart_requires_resume_and_does_not_replay_pending_navigation(tmp_path):
    store, b, rid, m = setup(tmp_path)
    cp = {"frontier": [ROOT + "a"], "visited": [], "pending_url": ROOT + "a"}
    store.update("session", rid, status="running", checkpoint=cp)
    b.current = ROOT + "a"
    m = CollectionManager(store, b, classifier=classify, collector_factory=Collector)
    assert not b.reads and m.summary("session", rid)["status"] == "paused"
    await m.control("session", rid, "resume")
    assert (await finish(m, rid))["status"] == "completed"
    assert b.reads == [(ROOT + "a", False)] and not b.navigations
    store.close()


async def test_invalid_commit_cannot_advance_durable_progress(tmp_path):
    def invalid(*a, **k):
        return {**classify(*a, **k), "confidence": float("nan")}

    store, b, rid, m = setup(tmp_path, classifier=invalid)
    await m.start("session", rid)
    r = await finish(m, rid)
    assert r["status"] == "failed" and r["counters"]["pages"] == 0
    assert store.get("session", rid)["checkpoint"] == {"frontier": [], "visited": [], "pending_url": ROOT}
    assert store.items("session", rid)["total"] == 0
    store.close()


async def test_foreign_session_and_trace_failure(tmp_path):
    store, b, rid, m = setup(tmp_path)
    for op in [lambda: m.summary("foreign", rid), lambda: store.items("foreign", rid)]:
        with pytest.raises(ValueError):
            op()
    with pytest.raises(ValueError):
        await m.start("foreign", rid)

    def bad_trace(*a, **k):
        raise OSError("disk full")

    m.trace = bad_trace
    await m.start("session", rid)
    assert (await finish(m, rid))["status"] == "completed"
    store.close()


def background_bridge(bridge):
    bridge.supports_background = True
    bridge.active_tab_id = "user-tab"
    bridge.owners = {}

    def claim(tid, owner):
        assert tid == "tab" and tid not in bridge.owners
        bridge.owners[tid] = owner

    def release(tid, owner):
        if bridge.owners.get(tid) == owner:
            del bridge.owners[tid]

    bridge.claim_tab = claim
    bridge.release_tab = release


async def test_background_start_keeps_user_tab_and_releases_lease(tmp_path):
    store, bridge, rid, manager = setup(tmp_path)
    background_bridge(bridge)
    await manager.start("session", rid)
    assert bridge.owners.get("tab")
    assert (await finish(manager, rid))["status"] == "completed"
    await asyncio.sleep(0)
    assert not bridge.owners and bridge.active_tab_id == "user-tab"
    store.close()


@pytest.mark.parametrize("failure", ["constructor", "storage"])
async def test_failed_background_start_releases_lease(tmp_path, monkeypatch, failure):
    store, bridge, rid, manager = setup(tmp_path)
    background_bridge(bridge)

    def fail(*args, **kwargs):
        raise RuntimeError("injected startup failure")

    if failure == "constructor":
        manager.collector_factory = fail
    else:
        monkeypatch.setattr(store, "items", fail)
    with pytest.raises(RuntimeError, match="injected"):
        await manager.start("session", rid)
    assert not bridge.owners and not manager.running
    assert store.get("session", rid)["status"] == "prepared"
    store.close()
