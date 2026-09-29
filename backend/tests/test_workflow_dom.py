from pathlib import Path
from types import SimpleNamespace

from test_feed_dom import browser as browser  # Re-export the real isolated Chromium fixture for pytest.
from test_workflow_capabilities import Worker, definition

from jet_browser.workflow_capabilities import WorkflowCapabilities
from jet_browser.workflow_manager import WorkflowManager
from jet_browser.workflow_store import WorkflowStore


async def test_javascript_collects_and_scrolls_actual_dom(browser, tmp_path):
    browser.tabs = [{"id": "tab", "url": "https://x.com/i/history"}]
    service = SimpleNamespace(
        store=SimpleNamespace(current_id="session"),
        bridge=browser,
        collections=SimpleNamespace(running=False),
        tasks=SimpleNamespace(running=False),
        recovery_active=False,
    )
    store = WorkflowStore(tmp_path)
    source = """const first = jet.call('feed.observe',{});
    for(const item of first.items) {
      jet.call('records.put',{item_id:item.id,tags:['mobile'],summary:'Fixture'});
    }
    const next = jet.call('feed.scroll',{observation_id:first.observation_id});
    jet.call('run.checkpoint',{state:{next:next.items.length},status:'complete',summary:'Saved fixture'});"""
    d = definition(source)
    d["start_url"] = "https://x.com/i/history"
    wid = store.save("session", d)["id"]

    def factory(s, st, sid, wid, stop, progress):
        return WorkflowCapabilities(s, st, sid, wid, stop, progress, worker=Worker())

    manager = WorkflowManager(
        service,
        store,
        capability_factory=factory,
        executable=Path(__file__).resolve().parents[2] / ".runtime/bin/jet-workflow",
    )
    await manager.start("session", wid)
    await manager.job
    row = store.get("session", wid)
    assert row["status"] == "completed", row["error"]
    assert row["counters"]["saved"] == 2 and row["counters"]["scrolls"] == 1
    assert store.records("session", wid)["items"][0]["author"] == "Example Author"
    store.close()
