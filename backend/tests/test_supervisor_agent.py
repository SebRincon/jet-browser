import asyncio

import pytest
from test_feed_loop import plan

from jet_browser.service import Service


def fixture(tmp_path, reason="first_batch", approved=False):
    tmp_path.mkdir(parents=True, exist_ok=True)
    s = Service(tmp_path)
    sid = s.store.current_id
    rid = s.collection_store.create(sid, "original", plan())["id"]
    sup = s.collections.supervision
    sup.configure(sid, rid, {"share_samples": True})
    s.collection_store.update(sid, rid, status="paused", reason="supervisor_review")
    first = sup.checkpoint(sid, rid, "first_batch")["supervision"]["pending"]["id"]
    if approved:
        sup.finish_review(sid, rid, first, "Initial review")
        sup.approve(sid, rid, first)
        first = sup.checkpoint(sid, rid, reason)["supervision"]["pending"]["id"]
    return s, sid, rid, first


async def wait_done(s):
    for _ in range(100):
        if not s.supervisor._tasks:
            return
        await asyncio.sleep(0.01)
    raise AssertionError("Supervisor did not settle")


async def test_checkpoint_invokes_one_agent_turn_and_blocks_unrelated_tools(tmp_path):
    s, sid, rid, key = fixture(tmp_path)
    calls = []

    async def grok(prompt):
        calls.append(prompt)
        assert s.auto_review == (sid, rid, key)
        for name, args in [
            ("open_url", {"url": "https://evil.test"}),
            ("workspace_write", {"name": "x.md", "content": "bad"}),
            ("configure_collection", {"collection_id": rid, "changes": {"mode": "continuous"}}),
        ]:
            with pytest.raises(ValueError, match="Checkpoint review"):
                await s.tool(name, args)
        with pytest.raises(ValueError):
            await s.tool("review_collection", {"collection_id": rid, "review_id": key, "action": "continue"})
        await s.tool(
            "review_collection",
            {
                "collection_id": rid,
                "review_id": key,
                "action": "ask_user",
                "summary": "Ten saved.",
                "question": "Keep this format?",
            },
        )
        s.message("assistant", "Your first sample is ready.", source="grok")

    s.grok_turn = grok
    s.supervisor.queue(sid, rid)
    s.supervisor.queue(sid, rid)
    await wait_done(s)
    assert len(calls) == 1
    assert rid in calls[0] and key in calls[0]
    assert s.auto_review is None and not s.chat_busy
    r = s.collection_store.get(sid, rid)
    assert r["status"] == "paused" and r["supervision"]["pending"]["status"] == "awaiting_user"
    assert not any(m["role"] == "user" for m in s.messages)
    await s.stop()


async def test_scheduler_waits_for_chat_and_does_not_post_into_another_session(tmp_path):
    s, sid, rid, key = fixture(tmp_path)
    gate = asyncio.Event()
    s.chat_job = asyncio.create_task(gate.wait())
    calls = []

    async def grok(prompt):
        calls.append(prompt)

    s.grok_turn = grok
    before = list(s.messages)
    s.supervisor.queue(sid, rid)
    await asyncio.sleep(0.03)
    assert not calls
    # Session can change before the queued agent obtains the chat slot.
    s.store.create()
    gate.set()
    await wait_done(s)
    assert not calls and s.messages == before
    assert s.collection_store.get(sid, rid)["supervision"]["pending"]["status"] == "awaiting_user"
    await s.stop()


async def test_stop_cancels_review_and_no_background_resume(tmp_path):
    s, sid, rid, key = fixture(tmp_path, reason="interval", approved=True)
    entered = asyncio.Event()
    resumes = []

    async def grok(prompt):
        entered.set()
        await asyncio.Event().wait()

    async def start(*args):
        resumes.append(args)

    s.grok_turn = grok
    s.collections.start = start
    s.supervisor.queue(sid, rid)
    await asyncio.wait_for(entered.wait(), 1)
    await s.stop()
    await wait_done(s)
    assert resumes == [] and s.auto_review is None
    assert s.collection_store.get(sid, rid)["supervision"]["pending"]["status"] == "awaiting_user"


async def test_approved_interval_can_resume_once_and_no_decision_falls_back(tmp_path):
    for decision in (False, True):
        s, sid, rid, key = fixture(tmp_path / str(decision), reason="interval", approved=True)
        resumed = []

        async def grok(prompt):
            if decision:
                await s.tool("review_collection", {"collection_id": rid, "review_id": key, "action": "continue"})

        async def start(*args):
            resumed.append(args)

        s.grok_turn = grok
        s.collections.start = start
        s.supervisor.queue(sid, rid)
        await wait_done(s)
        assert resumed == ([(sid, rid)] if decision else [])
        pending = s.collection_store.get(sid, rid)["supervision"]["pending"]
        assert (pending is None) if decision else pending["status"] == "awaiting_user"
        await s.stop()


async def test_invalid_mcp_review_and_stale_user_approval_cannot_change_plan(tmp_path):
    s, sid, rid, key = fixture(tmp_path)
    sup = s.collections.supervision
    sup.finish_review(sid, rid, key, "Looks good")
    original = s.collection_store.get(sid, rid)
    for args in [
        {"collection_id": rid, "review_id": "old", "action": "approve"},
        {"collection_id": rid, "review_id": key, "action": "approve", "script": "anything"},
    ]:
        with pytest.raises(ValueError):
            await s.tool("review_collection", args)
        assert s.collection_store.get(sid, rid) == original
    await s.stop()


async def test_user_reply_to_a_paused_checkpoint_bypasses_navigation_router(tmp_path, monkeypatch):
    from jet_browser import conversation

    s, sid, rid, key = fixture(tmp_path)
    s.collections.supervision.finish_review(sid, rid, key, "Sample ready")
    calls = []

    async def grok(text):
        calls.append(text)

    async def navigation(*args):
        raise AssertionError("Review reply was misrouted to navigation")

    s.grok_turn = grok
    monkeypatch.setattr(conversation, "run_turn", navigation)
    await s.chat("Yes, keep going with this format")
    await s.chat_job
    assert calls == ["Yes, keep going with this format"]
    await s.stop()
