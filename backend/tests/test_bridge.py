import asyncio
import time

import pytest

from jet_browser.bridge import BridgeError, BrowserBridge


def connected():
    bridge = BrowserBridge()
    bridge.sync({"host_id": "host-a", "active_tab_id": "tab-a", "tabs": [{"id": "tab-a"}]})
    return bridge


async def test_exact_tab_and_response_consumed_once():
    bridge = connected()
    task = asyncio.create_task(bridge.call("tab-a", "Input.insertText", {"text": "hello"}))
    request = await bridge.next_command("host-a")
    assert request["tab_id"] == "tab-a"
    assert bridge.resolve({"host_id": "host-a", "command_id": request["command_id"], "result": {"ok": True}})
    assert await task == {"ok": True}
    assert not bridge.resolve({"host_id": "host-a", "command_id": request["command_id"], "result": {}})


async def test_closed_tab_cannot_receive_queued_input():
    bridge = connected()
    task = asyncio.create_task(bridge.call("tab-a", "Input.insertText"))
    await asyncio.sleep(0)
    bridge.sync({"host_id": "host-a", "active_tab_id": None, "tabs": []})
    dispatch = asyncio.create_task(bridge.next_command("host-a"))
    with pytest.raises(BridgeError, match="no longer"):
        await task
    dispatch.cancel()


async def test_timeout_never_redispatches_and_foreign_host_rejected():
    bridge = connected()
    with pytest.raises(BridgeError, match="Unknown"):
        await bridge.next_command("host-b")
    with pytest.raises(BridgeError, match="timed out"):
        await bridge.call("tab-a", "Input.insertText", timeout=0.01)
    assert not bridge.pending


async def test_host_replacement_invalidates_requests():
    bridge = connected()
    task = asyncio.create_task(bridge.call("tab-a", "Input.insertText"))
    await asyncio.sleep(0)
    with pytest.raises(BridgeError, match="Another"):
        bridge.sync({"host_id": "host-b", "tabs": []})
    bridge.last_seen = time.monotonic() - 11
    bridge.sync({"host_id": "host-b", "tabs": []})
    with pytest.raises(BridgeError, match="replaced"):
        await task


async def test_stop_cancels_pending_without_replaying_input():
    bridge = connected()
    task = asyncio.create_task(bridge.call("tab-a", "Input.insertText"))
    await asyncio.sleep(0)
    bridge.cancel_queued()
    with pytest.raises(BridgeError, match="Stopped"):
        await task


async def test_background_tab_lease_is_exact_and_revocation_fences_queue():
    bridge = connected()
    bridge.sync(
        {
            "host_id": "host-a",
            "active_tab_id": "other",
            "tabs": [{"id": "tab-a"}, {"id": "other"}],
            "capabilities": {"background_tabs": True},
        }
    )
    bridge.claim_tab("tab-a", "job-1")
    task = asyncio.create_task(bridge.call("tab-a", "Runtime.evaluate", {"expression": "1"}))
    request = await bridge.next_command("host-a")
    assert request["background_owner"] == "job-1" and request["tab_id"] == "tab-a"
    bridge.resolve({"host_id": "host-a", "command_id": request["command_id"], "result": {}})
    await task
    task = asyncio.create_task(bridge.call("tab-a", "Runtime.evaluate", {"expression": "1"}))
    await asyncio.sleep(0)
    bridge.release_tab("tab-a", "job-1")
    dispatch = asyncio.create_task(bridge.next_command("host-a"))
    with pytest.raises(BridgeError, match="ownership"):
        await task
    dispatch.cancel()


async def test_background_lease_does_not_allow_global_input():
    bridge = connected()
    bridge.sync(
        {
            "host_id": "host-a",
            "active_tab_id": "other",
            "tabs": [{"id": "tab-a"}, {"id": "other"}],
            "capabilities": {"background_tabs": True},
        }
    )
    bridge.claim_tab("tab-a", "job-1")
    task = asyncio.create_task(bridge.call("tab-a", "Input.insertText", {"text": "must not reach foreground"}))
    request = await bridge.next_command("host-a")
    assert "background_owner" not in request
    bridge.resolve({"host_id": "host-a", "command_id": request["command_id"], "error": "Not active"})
    with pytest.raises(BridgeError):
        await task
