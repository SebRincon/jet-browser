"""Reviewer repairs: exact-post recovery and local re-tagging on a stopped workflow."""

import threading
from types import SimpleNamespace

import pytest
from test_workflow_capabilities import ITEM, Bridge, definition
from test_workflow_templates import BranchWorker

from jet_browser import workflow_capabilities, workflow_tools
from jet_browser.workflow_store import WorkflowStore


def world(tmp_path, status="paused", source_kind="x_bookmarks"):
    store = WorkflowStore(tmp_path)
    raw = definition()
    raw["source_kind"] = source_kind
    wid = store.save("session", raw)["id"]
    store.update("session", wid, status="running")
    store.put_record("session", wid, {**ITEM, "id": workflow_capabilities._item_id(ITEM["url"]),
                                      "tags": [], "summary": ""})
    store.update("session", wid, status=status)
    events = []
    service = SimpleNamespace(
        store=SimpleNamespace(current_id="session"), bridge=Bridge(), workflow_store=store,
        workflows=SimpleNamespace(running=status == "running"), tasks=SimpleNamespace(running=False),
        collections=SimpleNamespace(running=False), recovery_active=False, chat_stopped=threading.Event(),
        turn_id="turn-1", share_review_samples=False, local_worker=BranchWorker(),
        trace=SimpleNamespace(emit=lambda event, **attrs: events.append((event, attrs))),
    )
    return store, wid, service, workflow_capabilities._item_id(ITEM["url"]), events


async def test_untagged_records_are_listed_without_text_and_retagged_locally(tmp_path):
    store, wid, service, iid, _ = world(tmp_path)
    listed = await workflow_tools.tool(service, "workflow_records", {"workflow_id": wid, "needs": "untagged"})
    assert listed["matching"] == 1 and listed["flagged"][0]["id"] == iid
    assert "An open source" not in str(listed) and "items" not in listed
    result = await workflow_tools.tool(service, "retag_workflow_records", {"workflow_id": wid, "item_ids": [iid]})
    assert result == {"records": [{"item_id": iid, "tags": ["web"], "changed": True}]}
    row = store.get_record("session", wid, iid)
    assert row["tags"] == ["web"] and row["audit"][-1]["actor"] == "local"
    with pytest.raises(ValueError):
        await workflow_tools.tool(service, "retag_workflow_records", {"workflow_id": wid, "item_ids": [iid] * 2})


async def test_recovery_replaces_evidence_once_per_turn_and_returns_metadata(tmp_path, monkeypatch):
    store, wid, service, iid, events = world(tmp_path)
    opened = []

    async def recover(bridge, item, tab, stopped):
        opened.append(item["url"])
        return dict(ITEM, text=ITEM["text"] + " with the full design notes.", truncated=False, captured_at=125.0)

    class Collector:
        def __init__(self, *args, **kwargs):
            pass

    monkeypatch.setattr(workflow_capabilities, "recover_post", recover)
    monkeypatch.setattr(workflow_capabilities, "FeedCollector", Collector)
    result = await workflow_tools.tool(service, "recover_workflow_record", {"workflow_id": wid, "item_id": iid})
    assert result["status"] == "recovered" and result["truncated"] is False and result["tags"] == ["web"]
    assert result["added_chars"] == len(" with the full design notes.") and "text" not in result
    row = store.get_record("session", wid, iid)
    assert row["text"].endswith("full design notes.") and row["original_capture"]["truncated"] is True
    recovery = next(a for a in row["audit"] if a.get("kind") == "source_recovery")
    assert recovery["requested_by"] == "grok"
    assert not service.recovery_active and not service.bridge.tab_owners  # Tab released.
    with pytest.raises(RuntimeError, match="already attempted"):
        await workflow_tools.tool(service, "recover_workflow_record", {"workflow_id": wid, "item_id": iid})
    assert opened == [ITEM["url"]]  # One browser recovery; the refused retry opened nothing.


async def test_repairs_refuse_running_or_non_x_workflows(tmp_path):
    store, wid, service, iid, _ = world(tmp_path, status="running")
    for name, args in (("recover_workflow_record", {"item_id": iid}), ("retag_workflow_records", {"item_ids": [iid]})):
        with pytest.raises(RuntimeError, match="pause the workflow"):
            await workflow_tools.tool(service, name, {"workflow_id": wid, **args})
    store2, wid2, service2, iid2, _ = world(tmp_path / "feed", source_kind="feed")
    with pytest.raises(ValueError, match="X Bookmarks"):
        await workflow_tools.tool(service2, "recover_workflow_record", {"workflow_id": wid2, "item_id": iid2})
