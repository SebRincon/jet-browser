import copy

import pytest
from test_feed_loop import item, plan, setup

from jet_browser.collection_plan import CollectionPlan
from jet_browser.collection_store import CollectionStore
from jet_browser.feed_review import review_feed


def review(p, snapshot, *, stopped):
    assert not stopped.is_set()
    return {"action": "continue_scroll", "model": "fake-review@1", "inference_ms": 2, "reason": None}


def test_long_defaults_legacy_limits_and_atomic_reconfiguration(tmp_path):
    p = plan()
    assert (p.max_seconds, p.max_items, p.max_scrolls) == (1800, 5000, 2000)
    assert CollectionPlan.from_dict(p.to_dict()) == p
    for k, v in [("max_seconds", 14401), ("max_items", 5001), ("max_scrolls", 10001), ("max_seconds", True)]:
        with pytest.raises(ValueError):
            plan(**{k: v})
    s = CollectionStore(tmp_path)
    r = s.create("s", "t", plan(max_seconds=60, max_items=20, max_scrolls=6))
    rid = r["id"]
    before = copy.deepcopy(r)
    s.configure_limits("s", rid, {"max_seconds": 1800, "max_scrolls": 2000, "max_items": 5000})
    current = s.get("s", rid)
    assert current["plan"]["max_scrolls"] == 2000
    for k in ["checkpoint", "counters", "id", "session_id", "turn_id"]:
        assert current[k] == before[k]
    for bad in [{}, {"max_seconds": True}, {"source_kind": "website"}, {"max_items": 5001}]:
        with pytest.raises(ValueError):
            s.configure_limits("s", rid, bad)
        assert s.get("s", rid) == current
    s.update("s", rid, status="running")
    with pytest.raises(ValueError):
        s.configure_limits("s", rid, {"max_scrolls": 100})
    with pytest.raises(ValueError):
        s.configure_limits("other", rid, {"max_scrolls": 100})
    s.close()


async def test_one_invocation_continues_beyond_old_six_scroll_budget(tmp_path):
    s, b, m, rid = setup(tmp_path, max_scrolls=14)
    b.frames = [[item(i)] for i in range(1, 30)]
    seen = []

    def reviewer(p, snapshot, *, stopped):
        seen.append(b.scrolls)
        return review(p, snapshot, stopped=stopped)

    m.reviewer = reviewer
    await m.start("s", rid)
    r = await m.wait("s", rid, 5)
    assert r["status"] == "paused" and r["reason"] == "scroll_budget"
    assert b.scrolls == 14 and r["counters"]["pages"] == 15
    assert 0 in seen and 10 in seen
    assert r["counters"]["model_calls"] == 15  # Separate classification calls from review.
    assert len(s.seen_urls("s", rid)) == 15
    s.close()


async def test_attention_and_stop_during_review_fence_scroll(tmp_path):
    for stop in [False, True]:
        s, b, m, rid = setup(tmp_path / str(stop), max_scrolls=30)

        def reviewer(p, snapshot, *, stopped):
            if stop:
                stopped.set()
            return {"action": "needs_attention", "model": "fake", "inference_ms": 1, "reason": "ambiguous"}

        m.reviewer = reviewer
        await m.start("s", rid)
        r = await m.wait("s", rid, 5)
        assert b.scrolls == 0
        assert r["reason"] == ("user_stopped" if stop else "needs_attention")
        s.close()


async def test_review_never_authorizes_stale_source_or_bypasses_pause(tmp_path):
    s, b, m, rid = setup(tmp_path)

    def reviewer(p, snapshot, *, stopped):
        b.blocked = "source_changed"
        return review(p, snapshot, stopped=stopped)

    m.reviewer = reviewer
    await m.start("s", rid)
    r = await m.wait("s", rid, 5)
    assert b.scrolls == 0 and r["reason"] == "source_changed"
    s.close()


async def test_wait_is_bounded_and_does_not_scroll(tmp_path):
    s, b, m, rid = setup(tmp_path, max_seconds=10)
    m.reviewer = lambda *a, **k: {"action": "wait", "model": "fake", "inference_ms": 1, "reason": None}
    await m.start("s", rid)
    r = await m.wait("s", rid, 10)
    assert r["status"] == "paused" and r["reason"] == "feed_waiting"
    assert b.scrolls == 0
    s.close()


def test_review_preserves_pinned_model_and_does_not_include_post_content(monkeypatch):
    from test_classification import Worker

    from jet_browser import feed_review

    w = Worker({"valid": True, "label": "scroll", "probabilities": None, "confidence": None})
    w.result["answers"]["decision"] = w.result["answers"].pop("category")
    monkeypatch.setattr(feed_review, "WORKER", w)
    result = review_feed(
        plan(),
        {
            "items": [{"text": "PRIVATE_POST"}],
            "loading": False,
            "status_text": "",
            "scroll": {"top": 0, "height": 2000, "viewport": 800},
        },
    )
    assert result["action"] == "continue_scroll" and result["model"] == "fixture@1"
    assert "PRIVATE_POST" not in str(w.calls)
    w.result["answers"]["decision"]["label"] = "invented"
    assert review_feed(plan(), {})["action"] == "needs_attention"


async def test_items_arriving_during_review_are_saved_before_scroll(tmp_path):
    s, b, m, rid = setup(tmp_path, max_scrolls=1)

    def reviewer(p, snapshot, *, stopped):
        b.frames[0].append(item(99))
        return review(p, snapshot, stopped=stopped)

    m.reviewer = reviewer
    await m.start("s", rid)
    r = await m.wait("s", rid, 5)
    assert item(99)["url"] in s.seen_urls("s", rid)
    assert r["reason"] == "scroll_budget"
    s.close()


async def test_loading_that_finishes_during_review_is_rechecked_not_paused(tmp_path):
    from test_feed_loop import Feed

    class LoadingFeed(Feed):
        async def read(self):
            result = await super().read()
            result["loading"] = getattr(self.b, "loading", True)
            return result

    s, b, m, rid = setup(tmp_path, factory=LoadingFeed, max_scrolls=1)
    actions = []

    def reviewer(p, snapshot, *, stopped):
        if snapshot["loading"]:
            b.loading = False
            actions.append("wait")
            return {"action": "wait", "model": "fixture", "reason": None}
        actions.append("scroll")
        return review(p, snapshot, stopped=stopped)

    m.reviewer = reviewer
    await m.start("s", rid)
    result = await m.wait("s", rid, 5)
    assert actions == ["wait", "scroll"]
    assert b.scrolls == 1 and result["reason"] == "scroll_budget"
    s.close()
