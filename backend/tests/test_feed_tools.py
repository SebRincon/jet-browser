import json

import pytest
from test_collection_tools import ARGS, service_at
from test_feed_loop import CATS, URL

from jet_browser import collection_tools


def snapshot(**extra):
    return dict(
        url=URL,
        title="Private title",
        document_id="d",
        ready_state="complete",
        source_kind="x_bookmarks",
        selected_tab="Bookmarks",
        items=[dict(text="PRIVATE_POST", url="https://x.com/private/status/1")],
        navigation=[
            dict(label="Bookmarks", url=URL),
            dict(label="Likes", url=URL + "/likes"),
            dict(label="Private", url="https://x.com/private/status/1"),
        ],
        scroll=dict(top=0, height=2000, viewport=800, root="document"),
        loading=False,
        login_required=False,
        end_of_feed=False,
        **extra,
    )


async def test_inspector_exposes_only_capability_metadata_and_archive_links(tmp_path):
    s = service_at(tmp_path)
    s.bridge.tabs[0]["url"] = URL

    async def call(*args, **kw):
        return {"result": {"value": snapshot()}}

    s.bridge.call = call
    out = await s.tool("inspect_collection_source", {})
    assert out["visible_items"] == 1 and out["supported_modes"] == ["x_bookmarks"]
    assert len(out["navigation"]) == 2
    assert "PRIVATE_POST" not in json.dumps(out) and "/private/" not in json.dumps(out)


async def test_mismatch_never_creates_a_collection(tmp_path):
    s = service_at(tmp_path)
    s.bridge.tabs[0]["url"] = URL

    async def call(*args, **kw):
        data = snapshot()
        data.update(source_kind="unsupported", selected_tab="Likes")
        return {"result": {"value": data}}

    s.bridge.call = call
    with pytest.raises(ValueError, match="Feed unavailable"):
        await s.tool("prepare_collection", {**ARGS, "source_kind": "x_bookmarks", "categories": CATS})
    assert s.collections.summaries(s.store.current_id) == []


async def test_inspector_fences_host_change_and_browser_ownership(tmp_path):
    s = service_at(tmp_path)
    s.bridge.tabs[0]["url"] = URL

    async def call(*args, **kw):
        s.bridge.host_id = "replacement"
        return {"result": {"value": snapshot()}}

    s.bridge.call = call
    with pytest.raises(ValueError, match="host changed"):
        await s.tool("inspect_collection_source", {})


async def test_provider_collection_history_is_scoped_and_has_no_item_data(tmp_path):
    s = service_at(tmp_path)
    out = await s.tool("prepare_collection", ARGS)
    await s.tool("start_collection", {"collection_id": out["id"], "wait_seconds": 5})
    rows = collection_tools.provider_collections(s)
    assert rows[0]["id"] == out["id"] and rows[0]["counters"]["pages"] == 2
    assert "Documentation" not in json.dumps(rows) and "last_url" not in json.dumps(rows)
    assert (await s.tool("conversation_history", {}))["collections"] == rows
    s.store.create()
    assert collection_tools.provider_collections(s) == []


async def test_new_feed_default_is_semif_and_explicit_model_is_preserved(tmp_path, monkeypatch):
    from jet_browser.feed_collection import FeedCollector

    s = service_at(tmp_path)
    s.bridge.tabs[0]["url"] = URL
    s.settings["local_model"] = "lfm_rlcd"

    async def read(self):
        return {"source_kind": "x_bookmarks"}

    monkeypatch.setattr(FeedCollector, "read", read)
    args = {k: v for k, v in ARGS.items() if k != "model"} | {"source_kind": "x_bookmarks", "categories": CATS}
    first = await s.tool("prepare_collection", args)
    second = await s.tool("prepare_collection", args | {"model": "lfm_rlcd"})
    assert s.collection_store.get(s.store.current_id, first["id"])["plan"]["model"] == "qwen4b_semif_shared"
    assert s.collection_store.get(s.store.current_id, second["id"])["plan"]["model"] == "lfm_rlcd"
