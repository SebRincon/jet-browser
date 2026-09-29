import hashlib
import sys
import tempfile
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jet_browser.workflow_store import CAPABILITIES, LOCAL_MODELS, WorkflowStore

SID = "session"
OTHER = "other-session"
ITEM = "ab" * 32
ITEM_B = "cd" * 32


def definition(**overrides):
    base = {
        "title": "Feed",
        "source": "function run(){ return 1 }",
        "tab_id": "tab-1",
        "start_url": "https://example.com/feed",
        "source_kind": "feed",
        "model": "laya_mlx",
        "categories": [
            {"id": "news", "name": "News", "description": "News items"},
            {"id": "skip", "name": "Skip", "description": "Ignore"},
        ],
        "capabilities": ["feed.observe", "records.put", "records.patch"],
        "limits": {"max_seconds": 60, "max_calls": 20, "max_items": 5},
    }
    base.update(overrides)
    return base


def sample_record(item_id=ITEM, text="hello", **overrides):
    body = {
        "id": item_id,
        "url": "https://example.com/p/1",
        "text": text,
        "author": "ada",
        "published_at": "2026-01-01",
        "captured_at": 1_700_000_000,
        "truncated": False,
        "tags": ["news"],
        "summary": "first",
    }
    body.update(overrides)
    return body


def counters(**overrides):
    body = {"calls": 0, "saved": 0, "classified": 0, "scrolls": 0, "elapsed_ms": 0}
    body.update(overrides)
    return body


@pytest.fixture
def root():
    with tempfile.TemporaryDirectory() as tmp:
        yield Path(tmp)


def test_contract_constants():
    assert "records.put" in CAPABILITIES
    assert "shell.exec" not in CAPABILITIES
    assert LOCAL_MODELS == ("lfm_rlcd", "qwen4b_semif_shared", "laya_mlx", "laya_typed")


def test_permissions_and_session_isolation(root):
    store = WorkflowStore(root)
    runtime = root / ".runtime"
    assert (runtime.stat().st_mode & 0o777) == 0o700
    assert ((runtime / "workflows.sqlite3").stat().st_mode & 0o777) == 0o600
    made = store.save(SID, definition())
    wid = made["id"]
    assert len(wid) == 32
    assert made["status"] == "prepared" and made["revision"] == 1
    assert made["counters"] == counters()
    assert made["checkpoint"] == {} and made["error"] is None
    assert made["authorized_revision"] is None and made["run_id"] is None
    assert store.get(SID, wid)["definition"]["source"] == definition()["source"]
    with pytest.raises(ValueError):
        store.get(OTHER, wid)
    assert store.list(OTHER) == []
    assert len(store.list(SID)) == 1
    store.put_record(SID, wid, sample_record())
    with pytest.raises(ValueError):
        store.get_record(OTHER, wid, ITEM)
    with pytest.raises(ValueError):
        store.save("bad session", definition())
    store.close()


def test_revision_cas_scope_running_and_restart(root):
    store = WorkflowStore(root)
    made = store.save(SID, definition())
    wid = made["id"]
    store.update(SID, wid, counters=counters(calls=3, saved=1), checkpoint={"cursor": "a"}, run_id="run-1")
    with pytest.raises(ValueError):
        store.save(SID, definition(source="changed"), wid, expected_revision=made["revision"] + 9)
    running = store.update(SID, wid, status="running")
    with pytest.raises(ValueError):
        store.save(SID, definition(source="while-running"), wid, expected_revision=running["revision"])
    assert store.get(SID, wid)["status"] == "running"
    assert store.get(SID, wid)["definition"]["source"] == definition()["source"]
    paused = store.update(SID, wid, status="paused")
    with pytest.raises(ValueError):
        store.save(SID, definition(tab_id="tab-2"), wid, expected_revision=paused["revision"])
    with pytest.raises(ValueError):
        store.save(SID, definition(start_url="https://evil.example/feed"), wid, expected_revision=paused["revision"])
    with pytest.raises(ValueError):
        store.save(SID, definition(model="laya_typed"), wid, expected_revision=paused["revision"])
    with pytest.raises(ValueError):
        bumped = definition()
        bumped["limits"] = {"max_seconds": 61, "max_calls": 20, "max_items": 5}
        store.save(SID, bumped, wid, expected_revision=paused["revision"])
    with pytest.raises(ValueError):
        store.update(SID, wid, definition=definition(source="nope"))
    revised_def = definition(source="function run(){ return 2 }", capabilities=["feed.observe", "records.put"])
    revised_def["limits"] = {"max_seconds": 30, "max_calls": 10, "max_items": 4}
    revised_def["categories"] = [{"id": "news", "name": "News", "description": "Still news"}]
    revised = store.save(SID, revised_def, wid, expected_revision=paused["revision"])
    assert revised["revision"] == 2 and revised["status"] == "paused"
    assert revised["counters"]["calls"] == 3 and revised["checkpoint"] == {"cursor": "a"}
    assert revised["run_id"] == "run-1"
    assert store.version(SID, wid, 1)["source"] == definition()["source"]
    assert store.version(SID, wid, 2)["limits"]["max_seconds"] == 30
    with pytest.raises(ValueError):
        store.version(OTHER, wid, 1)
    store.update(SID, wid, status="running", checkpoint={"step": 1})
    rev_before = store.get(SID, wid)["revision"]
    store.close()
    restarted = WorkflowStore(root)
    woke = restarted.get(SID, wid)
    assert woke["status"] == "paused"
    assert woke["error"] == "Service restarted; resume explicitly"
    assert woke["revision"] == rev_before and woke["checkpoint"] == {"step": 1}
    neighbor = restarted.save(SID, definition(title="Other"))
    assert neighbor["status"] == "prepared" and neighbor["error"] is None
    restarted.close()


def test_record_dedup_original_and_manual_patch(root):
    store = WorkflowStore(root)
    made = store.save(SID, definition())
    wid = made["id"]
    first = store.put_record(SID, wid, sample_record())
    assert first["revision"] == 1 and first["audit"] == []
    assert first["content_hash"] == hashlib.sha256(b"hello").hexdigest()
    again = store.put_record(SID, wid, sample_record())
    assert again["revision"] == 1
    saved = store.put_record(SID, wid, sample_record(summary="second", tags=["skip", "news"]))
    assert saved["revision"] == 2
    assert saved["original_capture"]["summary"] == "first"
    assert saved["original_capture"]["tags"] == ["news"]
    assert saved["audit"][-1]["kind"] == "local_save"
    assert saved["audit"][-1]["previous_summary"] == "first"
    assert saved["url"] == "https://example.com/p/1"
    with pytest.raises(ValueError):
        store.put_record(SID, wid, sample_record(url="https://example.com/other"))
    with pytest.raises(ValueError):
        store.put_record(SID, wid, sample_record(text="different body"))
    assert store.get_record(SID, wid, ITEM)["text"] == "hello"
    store.put_record(SID, wid, sample_record(item_id=ITEM_B, text="second item", url="https://example.com/p/2"))
    page = store.records(SID, wid, limit=1, offset=0)
    assert page["total"] == 2 and page["items"][0]["id"] == ITEM
    assert store.records(SID, wid, limit=10, offset=1)["items"][0]["id"] == ITEM_B
    with pytest.raises(ValueError):
        store.patch_record(SID, wid, ITEM, {"summary": "x"}, 2)
    store.update(SID, wid, status="running")
    store.put_record(SID, wid, sample_record(summary="while-running"))
    with pytest.raises(ValueError):
        store.patch_record(SID, wid, ITEM, {"summary": "nope"}, 3)
    store.update(SID, wid, status="paused")
    with pytest.raises(ValueError):
        store.patch_record(SID, wid, ITEM, {"summary": "stale"}, 1)
    with pytest.raises(ValueError):
        store.patch_record(SID, wid, ITEM, {"text": "rewritten"}, 3)
    with pytest.raises(ValueError):
        store.patch_record(SID, wid, ITEM, {"tags": ["missing"]}, 3)
    with pytest.raises(ValueError):
        store.patch_record(SID, wid, ITEM, {"tags": ["news", "news"]}, 3, actor="local")
    with pytest.raises(ValueError):
        store.patch_record(SID, wid, ITEM, {"summary": "z"}, 3, actor="model")
    current = store.get_record(SID, wid, ITEM)
    patched = store.patch_record(SID, wid, ITEM, {"summary": "third", "tags": ["news"]}, current["revision"], actor="grok")
    assert patched["revision"] == current["revision"] + 1
    assert patched["text"] == "hello" and patched["author"] == "ada"
    assert patched["original_capture"]["summary"] == "first"
    assert patched["audit"][-1]["actor"] == "grok"
    assert patched["audit"][-1]["previous_revision"] == current["revision"]
    assert patched["audit"][-1]["previous_tags"] == current["tags"]
    store.close()


def test_caps_and_unsafe_values(root):
    store = WorkflowStore(root)
    tight = definition()
    tight["limits"] = {"max_seconds": 60, "max_calls": 20, "max_items": 1}
    made = store.save(SID, tight)
    wid = made["id"]
    store.put_record(SID, wid, sample_record())
    store.put_record(SID, wid, sample_record(summary="still one row"))
    with pytest.raises(ValueError):
        store.put_record(SID, wid, sample_record(item_id=ITEM_B, text="overflow", url="http://example.com/b"))
    assert store.records(SID, wid)["total"] == 1
    bad_limits = definition()
    bad_limits["limits"] = {"max_seconds": True, "max_calls": 20, "max_items": 5}
    with pytest.raises(ValueError):
        store.save(SID, bad_limits)
    bad_limits["limits"] = {"max_seconds": 1.5, "max_calls": 20, "max_items": 5}
    with pytest.raises(ValueError):
        store.save(SID, bad_limits)
    bad_limits["limits"] = {"max_seconds": 0, "max_calls": 20, "max_items": 5}
    with pytest.raises(ValueError):
        store.save(SID, bad_limits)
    with pytest.raises(ValueError):
        store.save(SID, definition(start_url="https://user:pass@example.com/feed"))
    with pytest.raises(ValueError):
        store.save(SID, definition(start_url="javascript:alert(1)"))
    with pytest.raises(ValueError):
        store.save(SID, definition(source_kind="bookmarks"))
    with pytest.raises(ValueError):
        extra = definition()
        extra["path"] = "/tmp/owned-by-model"
        store.save(SID, extra)
    with pytest.raises(ValueError):
        store.update(SID, wid, counters=counters(calls=True))
    with pytest.raises(ValueError):
        store.update(SID, wid, counters=counters(elapsed_ms=float("inf")))
    with pytest.raises(ValueError):
        store.update(SID, wid, checkpoint=["not", "object"])
    with pytest.raises(ValueError):
        store.update(SID, wid, checkpoint={"blob": "x" * 40000})
    with pytest.raises(ValueError):
        store.update(SID, wid, last_result="y" * 40000)
    with pytest.raises(ValueError):
        store.put_record(SID, wid, sample_record(url="https://user:secret@example.com/p"))
    with pytest.raises(ValueError):
        store.put_record(SID, wid, sample_record(item_id=ITEM_B, captured_at=True, text="n", url="http://ok.example/n"))
    with pytest.raises(ValueError):
        store.put_record(SID, wid, sample_record(item_id=ITEM_B, truncated=1, text="n", url="http://ok.example/n"))
    with pytest.raises(ValueError):
        poisoned = sample_record(item_id=ITEM_B, text="n", url="http://ok.example/n")
        poisoned["path"] = "../secrets"
        store.put_record(SID, wid, poisoned)
    assert store.records(SID, wid, limit=0) == {"items": [], "total": 1}
    with pytest.raises(ValueError):
        store.records(SID, wid, offset=5001)
    assert store.get(SID, wid)["definition"]["limits"]["max_items"] == 1
    assert time.time() >= store.get(SID, wid)["created_at"]
    store.close()
