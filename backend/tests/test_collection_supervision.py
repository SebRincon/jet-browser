import copy

import pytest
from test_feed_loop import item, setup

from jet_browser.collection_supervision import CollectionSupervision


def supervision(store, rid, **changes):
    sup = CollectionSupervision(store)
    sup.configure("s", rid, {"share_samples": True, **changes})
    return sup


async def test_first_ten_stop_before_an_eleventh_item_or_scroll(tmp_path):
    s, b, m, rid = setup(tmp_path)
    b.frames = [[item(i) for i in range(1, 16)]]
    sup = supervision(s, rid)
    m.supervision = sup
    await m.start("s", rid)
    run = await m.wait("s", rid, 5)
    assert run["status"] == "paused"
    assert run["reason"] == "supervisor_review"
    assert run["counters"]["pages"] == 10
    assert b.scrolls == 0
    pending = run["supervision"]["pending"]
    assert pending["reason"] == "first_batch"
    assert pending["status"] == "queued"
    with pytest.raises(ValueError):
        await m.start("s", rid)
    sup.claim("s", rid, pending["id"])
    with pytest.raises(ValueError):
        sup.accept("s", rid, pending["id"])
    sup.finish_review("s", rid, pending["id"], "Ten posts collected.", "Does this look right?")
    with pytest.raises(ValueError):
        sup.approve("s", rid, "stale")
    sup.approve("s", rid, pending["id"], mode="continuous")
    await m.start("s", rid)
    run = await m.wait("s", rid, 5)
    assert run["counters"]["pages"] == 15
    assert len(s.seen_urls("s", rid)) == 15
    assert run["reason"] == "feed_stalled"
    s.close()


def test_policy_revision_is_atomic_and_preserves_evidence(tmp_path):
    s, _, _, rid = setup(tmp_path)
    sup = supervision(s, rid)
    before = s.get("s", rid)
    for changes in [
        {"fields": ["text"]},
        {"mode": "forever"},
        {"share_samples": 1},
        {"interval_seconds": True},
        {"script": "bad"},
    ]:
        with pytest.raises(ValueError):
            sup.configure("s", rid, changes)
        assert s.get("s", rid) == before
    category = {"id": "art", "name": "Art", "description": "Visual art"}
    after = sup.configure("s", rid, {"add_categories": [category], "fields": ["url", "text", "author"]})
    assert after["plan"]["taxonomy_version"] == 2
    assert after["plan"]["categories"][-1] == category
    for key in ("checkpoint", "counters", "id", "session_id"):
        assert after[key] == before[key]
    with pytest.raises(ValueError):
        sup.configure("wrong", rid, {"mode": "continuous"})
    with pytest.raises(ValueError):
        sup.configure("s", rid, {"add_categories": [category]})
    s.update("s", rid, status="running")
    with pytest.raises(ValueError):
        sup.configure("s", rid, {"mode": "continuous"})
    s.close()


async def test_bounded_samples_require_permission_and_recovery_never_resumes(tmp_path):
    s, b, m, rid = setup(tmp_path)
    b.frames = [
        [
            {**item(i), "text": "PRIVATE_POST_" + "x" * 500, "author": "Ada", "published_at": "2026-09-28T12:00:00Z"}
            for i in range(1, 16)
        ]
    ]
    sup = supervision(s, rid, share_samples=False)
    m.supervision = sup
    await m.start("s", rid)
    await m.wait("s", rid, 5)
    local = sup.packet("s", rid)
    remote = sup.packet("s", rid, remote=True)
    assert len(local["samples"]) <= 5
    assert all(len(row["text"]) <= 400 for row in local["samples"])
    assert "PRIVATE_POST" not in str(remote)
    assert remote["samples"] == []
    assert local["coverage"]["author"] == 10
    assert local["coverage"]["published_at"] == 10
    sup.configure("s", rid, {"share_samples": True})
    assert "PRIVATE_POST" in str(sup.packet("s", rid, remote=True))
    pending = s.get("s", rid)["supervision"]["pending"]
    sup.claim("s", rid, pending["id"])
    sup.recover()
    run = s.get("s", rid)
    assert run["status"] == "paused"
    assert run["supervision"]["pending"]["status"] == "awaiting_user"
    s.update("s", rid, status="cancelled")
    with pytest.raises(ValueError):
        sup.approve("s", rid, pending["id"])
    s.close()


def test_periodic_review_and_drift_remain_bounded(tmp_path):
    s, _, _, rid = setup(tmp_path)
    sup = supervision(s, rid)
    counters = copy.deepcopy(s.get("s", rid)["counters"])
    counters.update(pages=10, classified=10, elapsed_ms=1000)
    assert sup.due("s", rid, counters) == "first_batch"
    s.update("s", rid, status="paused", counters=counters)
    r = sup.checkpoint("s", rid, "first_batch")
    key = r["supervision"]["pending"]["id"]
    sup.finish_review("s", rid, key, "Ready")
    sup.approve("s", rid, key)
    counters.update(pages=20, classified=20, elapsed_ms=602000)
    assert sup.due("s", rid, counters) == "interval"
    s.update("s", rid, counters=counters)
    r = sup.checkpoint("s", rid, "interval")
    sup.accept("s", rid, r["supervision"]["pending"]["id"])
    sup.configure("s", rid, {"mode": "continuous"})
    counters.update(pages=30, classified=25, needs_review=5, elapsed_ms=603000)
    assert sup.due("s", rid, counters) == "category_drift"
    counters.update(needs_review=0, classified=30, elapsed_ms=9000000)
    assert sup.due("s", rid, counters) is None
    s.close()


async def test_automatic_reviews_do_not_renew_authorized_budgets(tmp_path):
    s, b, m, rid = setup(tmp_path, max_seconds=60, max_scrolls=20, max_items=30)
    sup = supervision(s, rid)
    s.update("s", rid, status="paused")
    key = sup.checkpoint("s", rid, "first_batch")["supervision"]["pending"]["id"]
    sup.finish_review("s", rid, key, "Approved format")
    sup.approve("s", rid, key)
    counters = dict(s.get("s", rid)["counters"], elapsed_ms=61000)
    s.update("s", rid, counters=counters)
    key = sup.checkpoint("s", rid, "interval")["supervision"]["pending"]["id"]
    sup.accept("s", rid, key)
    with pytest.raises(ValueError, match="Authorized run limit"):
        await m.start("s", rid)
    assert b.scrolls == 0 and s.get("s", rid)["reason"] == "time_budget"
    s.close()
