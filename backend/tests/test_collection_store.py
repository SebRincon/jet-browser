import math

import pytest

from jet_browser.collection_plan import CollectionPlan
from jet_browser.collection_store import CollectionStore


def plan():
    return CollectionPlan.from_request(
        {
            "request": "Organize this site",
            "title": "Site",
            "categories": [{"id": "docs", "name": "Docs", "description": "Technical documentation"}],
        },
        start_url="https://example.test/",
        tab_id="t",
        model="lfm_rlcd",
    )


def record(text="Technical guide"):
    return {
        "url": "https://example.test/guide",
        "title": "Guide",
        "text": text,
        "captured_at": 123.0,
        "truncated": False,
        "classification": {
            "label_id": "docs",
            "taxonomy_version": 1,
            "classifier_revision": "collection-choice-v1",
            "model": "actual-model@revision",
            "confidence": None,
            "inference_ms": 12.0,
            "reason": None,
            "excerpt_chars": len(text),
            "model_calls": 1,
        },
    }


COUNTS = {"pages": 1, "classified": 1, "needs_review": 0, "model_calls": 1, "elapsed_ms": 13.0}
CP = {"frontier": [], "visited": ["https://example.test/guide"], "pending_url": None}


def test_private_store_durable_dedup_versions_and_events(tmp_path):
    store = CollectionStore(tmp_path)
    r = store.create("s", "turn", plan())
    item = store.commit_item("s", r["id"], record(), CP, COUNTS)
    again = store.commit_item("s", r["id"], record(), CP, COUNTS)
    assert item["id"] == again["id"]
    store.commit_item("s", r["id"], record("Updated technical guide"), CP, COUNTS)
    assert store.items("s", r["id"])["total"] == 2
    assert store.items("s", r["id"], query="updated", category="docs")["total"] == 1
    assert store.items("s", r["id"], limit=1)["total"] == 2
    events = store.events("s", r["id"])
    seq = [e["seq"] for e in events]
    assert seq == sorted(set(seq)) and seq[0] == 1
    assert all(e["seq"] > seq[0] for e in store.events("s", r["id"], after=seq[0]))
    store.close()
    restored = CollectionStore(tmp_path)
    assert restored.items("s", r["id"])["total"] == 2
    assert restored.get("s", r["id"])["checkpoint"] == CP
    assert (tmp_path / ".runtime/collections.sqlite3").stat().st_mode & 0o077 == 0
    restored.close()


def test_session_isolation_and_recovery_never_dispatches(tmp_path):
    store = CollectionStore(tmp_path)
    r = store.create("one", "turn", plan())
    store.update("one", r["id"], status="running")
    for fn in [
        lambda: store.get("two", r["id"]),
        lambda: store.items("two", r["id"]),
        lambda: store.events("two", r["id"]),
        lambda: store.update("two", r["id"], status="cancelled"),
    ]:
        with pytest.raises(ValueError):
            fn()
    assert not store.list("two")
    store.recover_interrupted()
    r2 = store.get("one", r["id"])
    assert r2["status"] == "paused" and r2["reason"] == "service_restarted"
    assert r2["checkpoint"] == r["checkpoint"]
    store.close()


def test_invalid_record_does_not_advance_checkpoint(tmp_path):
    store = CollectionStore(tmp_path)
    r = store.create("s", "turn", plan())
    bad = record()
    bad["classification"]["confidence"] = math.nan
    with pytest.raises(ValueError):
        store.commit_item("s", r["id"], bad, CP, COUNTS)
    assert store.get("s", r["id"])["checkpoint"] == r["checkpoint"]
    assert store.items("s", r["id"])["total"] == 0
    bad = record()
    bad["url"] = "https://evil.test/"
    with pytest.raises(ValueError):
        store.commit_item("s", r["id"], bad, CP, COUNTS)
    with pytest.raises(ValueError):
        store.update("s", r["id"], checkpoint={**CP, "frontier": ["https://evil.test/"]})
    with pytest.raises(ValueError):
        store.items("s", r["id"], limit=True)
    store.close()


def test_symlink_runtime_rejected(tmp_path):
    actual = tmp_path / "other"
    actual.mkdir()
    (tmp_path / ".runtime").symlink_to(actual, target_is_directory=True)
    with pytest.raises(ValueError):
        CollectionStore(tmp_path)
