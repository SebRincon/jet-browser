import pytest
from test_feed_loop import item, setup


@pytest.mark.asyncio
async def test_repair_preserves_identity_history_and_adjusts_counts(tmp_path):
    store, bridge, manager, rid = setup(tmp_path)
    bridge.frames = [[item(1)]]
    await manager.start("s", rid)
    await manager.wait("s", rid, 5)
    before = store.items("s", rid)["items"][0]
    counters = store.get("s", rid)["counters"].copy()
    replacement = {**before, "text": "Full expanded source text", "truncated": False}
    fixed = store.repair_item(
        "s", rid, before["id"], replacement, before["classification"], expected_hash=before["content_hash"]
    )
    assert fixed["id"] == before["id"] and fixed["captured_at"] == before["captured_at"]
    assert fixed["text"] == "Full expanded source text"
    assert fixed["original_capture"]["text"] == before["text"]
    assert store.get("s", rid)["counters"]["pages"] == counters["pages"]
    assert store.items("s", rid)["total"] == 1
    with pytest.raises(ValueError):
        store.repair_item(
            "s", rid, before["id"], replacement, before["classification"], expected_hash=before["content_hash"]
        )
    with pytest.raises(ValueError):
        store.item("other", rid, before["id"])
    store.close()
