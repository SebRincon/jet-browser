import asyncio
import copy
import threading
from dataclasses import replace

import pytest

from jet_browser.collection_plan import CollectionPlan
from jet_browser.collection_runner import CollectionManager
from jet_browser.collection_store import CollectionStore
from jet_browser.feed_runner import classify_feed_item
from jet_browser.site_collection import CollectionBlocked

URL = "https://x.com/i/history"
CATS = [{"id": "tech", "name": "Technology", "description": "Software, computers, AI"}]


def plan(**kwargs):
    return CollectionPlan.from_request(
        {
            "request": "Organize my X bookmarks",
            "title": "Bookmarks",
            "categories": CATS,
            "source_kind": "x_bookmarks",
            **kwargs,
        },
        start_url=URL,
        tab_id="tab",
        model="lfm_rlcd",
    )


def classify(p, text, stopped=None):
    return dict(
        label_id="tech",
        taxonomy_version=1,
        classifier_revision=p.classifier_revision,
        model="fake@1",
        confidence=None,
        inference_ms=1.0,
        reason=None,
        excerpt_chars=len(text),
        model_calls=1,
    )


def item(i):
    return dict(
        url=f"https://x.com/test/status/{i}",
        title=f"Post {i}",
        text="Software article",
        truncated=False,
        captured_at=123.0 + i,
    )


class Bridge:
    active_tab_id = "tab"
    host_id = "host"

    def __init__(self):
        self.frames = [[item(1), item(2)], [item(2), item(3)], [item(3), item(4)]]
        self.index = 0
        self.scrolls = 0
        self.reads = 0
        self.blocked = None

    def tab(self, value):
        return value


class Feed:
    def __init__(self, bridge, plan, event, expected_url=None):
        self.b = bridge

    async def read(self):
        b = self.b
        b.reads += 1
        if b.blocked:
            raise CollectionBlocked(b.blocked)
        return dict(
            url=URL,
            document_id="doc",
            items=copy.deepcopy(b.frames[b.index]),
            scroll=dict(top=b.index * 400.0, height=2400.0, viewport=600.0, root="document"),
            loading=False,
            end_of_feed=False,
        )

    async def scroll(self, before):
        b = self.b
        b.scrolls += 1
        b.index = min(b.index + 1, len(b.frames) - 1)
        return await self.read()


def setup(tmp_path, classifier=classify, factory=Feed, **limits):
    s = CollectionStore(tmp_path)
    b = Bridge()
    m = CollectionManager(
        s,
        b,
        classifier=classifier,
        feed_collector_factory=factory,
        reviewer=lambda *a, **k: {"action": "continue_scroll", "model": "fake-review", "reason": None},
    )
    r = s.create("s", "t", plan(**limits))
    return s, b, m, r["id"]


async def finish(m, rid):
    return await m.wait("s", rid, 5)


def test_old_plan_round_trip_and_wrong_crawler_guard():
    old = CollectionPlan.from_request(
        {"request": "Docs", "title": "Docs", "categories": CATS},
        start_url="https://docs.test/",
        tab_id="tab",
        model="lfm_rlcd",
    )
    assert old.to_dict()["schema_version"] == 1
    assert "source_kind" not in old.to_dict()
    assert CollectionPlan.from_dict(old.to_dict()) == old
    for source in (URL, URL + "/likes", "https://x.com/i/bookmarks"):
        with pytest.raises(ValueError):
            CollectionPlan.from_request(
                {"request": "Bookmarks", "title": "Bookmarks", "categories": CATS},
                start_url=source,
                tab_id="tab",
                model="lfm_rlcd",
            )


def test_feed_scope_and_contract():
    p = plan()
    assert CollectionPlan.from_dict(p.to_dict()) == p
    assert p.to_dict()["schema_version"] == 2
    assert p.in_scope(URL) and not p.in_scope(URL + "/likes")
    assert p.item_in_scope(item(1)["url"])
    assert not p.item_in_scope("https://x.com/settings")
    assert not p.item_in_scope("https://other.test/test/status/1")
    for key, value in [("source_kind", "whatever"), ("max_items", True), ("max_scrolls", 10001)]:
        with pytest.raises(ValueError):
            plan(**{key: value})


async def test_virtualized_dedup_stall_is_not_archive_completion(tmp_path):
    s, b, m, rid = setup(tmp_path)
    await m.start("s", rid)
    r = await finish(m, rid)
    assert (r["status"], r["reason"], r["resumable"]) == ("paused", "feed_stalled", True)
    assert r["counters"]["pages"] == 4
    assert r["counters"]["model_calls"] == 4
    assert s.items("s", rid)["total"] == 4
    assert b.scrolls == 5
    cp = s.get("s", rid)["checkpoint"]["feed"]
    assert cp["last_url"] == item(4)["url"] and cp["scrolls"] == 5
    assert not cp["pending_scroll"]
    with pytest.raises(ValueError):
        s.seen_urls("other_session", rid)


async def test_resume_uses_new_pass_budget_without_reclassifying(tmp_path):
    s, b, m, rid = setup(tmp_path, max_items=2)
    await m.start("s", rid)
    assert (await finish(m, rid))["reason"] == "item_budget"
    assert b.scrolls == 0
    await m.control("s", rid, "resume")
    r = await finish(m, rid)
    assert r["counters"]["pages"] == 4 and r["counters"]["model_calls"] == 4
    assert s.items("s", rid)["total"] == 4


async def test_changed_post_text_does_not_create_new_saved_item(tmp_path):
    s, b, m, rid = setup(tmp_path, max_items=2)
    await m.start("s", rid)
    await finish(m, rid)
    b.frames[0][0]["text"] = "Updated counts and edited text"
    await m.control("s", rid, "resume")
    r = await finish(m, rid)
    assert r["counters"]["pages"] == 4 and s.items("s", rid)["total"] == 4


async def test_uncertain_scroll_is_not_retried_and_restart_does_not_dispatch(tmp_path):
    class LostResponse(Feed):
        async def scroll(self, before):
            self.b.scrolls += 1
            raise CollectionBlocked("scroll_uncertain")

    s, b, m, rid = setup(tmp_path, factory=LostResponse)
    await m.start("s", rid)
    r = await finish(m, rid)
    assert r["reason"] == "scroll_uncertain" and b.scrolls == 1
    assert s.get("s", rid)["checkpoint"]["feed"]["pending_scroll"]
    CollectionManager(s, b, classifier=classify, feed_collector_factory=Feed)
    assert b.scrolls == 1


@pytest.mark.parametrize("action", ["pause", "stop"])
async def test_stop_and_pause_during_inference(tmp_path, action):
    entered, release = threading.Event(), threading.Event()

    def slow(*args, **kwargs):
        entered.set()
        release.wait(3)
        return classify(*args, **kwargs)

    s, b, m, rid = setup(tmp_path, classifier=slow)
    await m.start("s", rid)
    assert await asyncio.to_thread(entered.wait, 2)
    await m.control("s", rid, action)
    release.set()
    r = await finish(m, rid)
    assert b.scrolls == 0
    assert r["status"] == ("paused" if action == "pause" else "cancelled")
    assert s.items("s", rid)["total"] == (1 if action == "pause" else 0)


async def test_takeover_during_inference_does_not_commit_or_scroll(tmp_path):
    s, b, m, rid = setup(tmp_path)

    def takeover(*args, **kwargs):
        b.blocked = "source_changed"
        return classify(*args, **kwargs)

    m.classifier = takeover
    await m.start("s", rid)
    r = await finish(m, rid)
    assert r["reason"] == "source_changed" and b.scrolls == 0
    assert s.items("s", rid)["total"] == 0


async def test_failed_commit_does_not_advance_checkpoint(tmp_path):
    s, b, m, rid = setup(tmp_path)
    m.classifier = lambda *a, **kw: dict(classify(*a, **kw), confidence=float("nan"))
    await m.start("s", rid)
    r = await finish(m, rid)
    assert r["status"] == "failed"
    assert s.get("s", rid)["checkpoint"]["feed"]["last_url"] is None
    assert r["counters"]["pages"] == 0


def test_chunk_aggregation_and_unexamined_tail():
    p = plan()
    result = classify_feed_item(classify, p, "a" * 2500, threading.Event())
    assert result["model_calls"] == 3 and result["excerpt_chars"] == 2500
    assert result["label_id"] == "tech"
    result = classify_feed_item(classify, p, "a" * 7300, threading.Event())
    assert result["model_calls"] == 6 and result["excerpt_chars"] == 7200
    assert result["label_id"] == "needs_review" and result["reason"] == "capture_limited"
    result = classify_feed_item(classify, replace(p, model="laya_typed"), "a" * 1200, threading.Event())
    assert result["model_calls"] == 3

    def conflict(p, text, **kw):
        return dict(classify(p, text, **kw), label_id="needs_review" if text.startswith("b") else "tech")

    assert classify_feed_item(conflict, p, "a" * 1200 + "b", threading.Event())["label_id"] == "needs_review"


async def test_pause_arrives_during_observation_before_scroll(tmp_path):
    s, b, m, rid = setup(tmp_path)

    class PauseOnRead(Feed):
        async def read(self):
            result = await super().read()
            if self.b.reads == 4:
                m._pause.set()
            return result

    m.feed_collector_factory = PauseOnRead
    await m.start("s", rid)
    r = await finish(m, rid)
    assert r["status"] == "paused" and r["reason"] == "user_paused"
    assert b.scrolls == 0


async def test_progressing_scroll_without_new_ids_is_not_stalled(tmp_path):
    s, b, m, rid = setup(tmp_path, max_scrolls=5)

    class TallPost(Feed):
        async def read(self):
            result = await super().read()
            result["items"] = [item(1)]
            result["scroll"]["top"] = self.b.scrolls * 400
            return result

        async def scroll(self, before):
            self.b.scrolls += 1
            return await self.read()

    m.feed_collector_factory = TallPost
    await m.start("s", rid)
    r = await finish(m, rid)
    assert r["reason"] == "scroll_budget" and b.scrolls == 5


async def test_resume_trace_correlates_to_current_turn_and_keeps_text_private(tmp_path):
    from jet_browser.tracing import TraceStore

    s, b, m, rid = setup(tmp_path)
    trace = TraceStore(tmp_path)
    m.trace = trace
    counters = s.get("s", rid)["counters"]
    counters["elapsed_ms"] = 60000
    s.update("s", rid, counters=counters)
    with trace.bind(session_id="s", turn_id="resume-turn"), trace.span("chat.turn"):
        await m.start("s", rid)
        await finish(m, rid)
    events = [row for row in trace.recent("s", "resume-turn", limit=1000) if row["event"].startswith("collection.")]
    assert sum(e["event"] == "collection.item" for e in events) == 4
    assert sum(e["event"] == "collection.scroll" for e in events) == 5
    assert all(e["attributes"].get("task_id") == rid for e in events)
    assert not any("Software article" in str(e) or "/status/" in str(e) for e in events)
    scroll = next(e for e in events if e["event"] == "collection.scroll")
    assert scroll["attributes"]["scroll_top"] == 400
    end = next(e for e in events if e["event"] == "collection.end")
    assert end["duration_ms"] < 60000 < end["attributes"]["elapsed_ms"]
