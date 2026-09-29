import asyncio

import pytest
from test_workflow_capabilities import definition

from jet_browser.service import Service


@pytest.mark.parametrize("reason", ["checkpoint_review", "script_error"])
async def test_workflow_review_is_scoped_once_and_preserves_samples(tmp_path, reason):
    service = Service(tmp_path)
    sid = service.store.current_id
    wid = service.workflow_store.save(sid, definition())["id"]
    service.workflow_store.update(sid, wid, status="paused", error=reason, run_id="run-a")
    calls = []

    async def review(prompt):
        calls.append(prompt)
        assert service.workflow_review == (sid, wid)
        with pytest.raises(ValueError):
            await service.tool("open_url", {"url": "https://x.com"})
        with pytest.raises(ValueError):
            await service.tool("workflow_status", {"workflow_id": "f" * 32})
        with pytest.raises(ValueError):
            await service.tool("save_workflow", {"definition": definition()})
        assert (await service.tool("workflow_records", {"workflow_id": wid})) == {"total": 0}
        assert (await service.tool("read_workflow", {"workflow_id": wid}))["revision"] == 1

    service.grok_turn = review
    service.workflow_supervisor.queue(sid, wid)
    service.workflow_supervisor.queue(sid, wid)
    for _ in range(100):
        if not service.workflow_supervisor.pending:
            break
        await asyncio.sleep(0.01)
    service.workflow_supervisor.queue(sid, wid)
    assert len(calls) == 1 and not service.workflow_supervisor.pending
    assert service.workflow_review is None and not service.chat_busy
    await service.stop()
    service.workflow_store.close()
    service.store.close()
    service.collection_store.close()
    service.workspace.close()
    service.trace.close()
