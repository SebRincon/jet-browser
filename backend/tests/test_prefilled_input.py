"""B11 prefilled-form input: Jet's action executor against isolated real Chromium.

The retained native failure (docs/VERIFICATION.md) had acknowledged mouse input while
document.activeElement stayed BODY: the press never reached the checkbox. These checks
run the same executor over CDP and simulate that native fault by dropping or shifting
mouse input, proving the executor stops without typing elsewhere or repeating a click.
"""

import asyncio
import base64
import json
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import aiohttp
import pytest

from jev_ultrafast.browser import Browser, InputNotDelivered

FIXTURE = (Path(__file__).resolve().parents[1] / "jet_browser/fixture.html").read_text()
URL = "http://127.0.0.1:9148/fixture?team=Home&email=old%40example.test"


class Transport:
    """Synchronous CDP session with the attributes Jet's native transport exposes."""

    def __init__(self, loop, ws):
        self.loop, self.ws, self.seq = loop, ws, 0
        self.tab_id = "tab"
        self.stopped = threading.Event()
        self.input_diagnostics = []
        self.action_active = self.input_started = False
        self.pending = {}
        self.fault = None  # None, "drop" or a y offset in CSS pixels

    async def _call(self, method, params):
        self.seq += 1
        ident = self.seq
        future = self.loop.create_future()
        self.pending[ident] = future
        await self.ws.send_json(dict(id=ident, method=method, params=params))
        return await asyncio.wait_for(future, 15)

    def call(self, method, **params):
        if method == "Input.dispatchMouseEvent" and self.fault == "drop":
            return {}  # Acknowledged, never delivered: the retained native symptom.
        if method == "Input.dispatchMouseEvent" and isinstance(self.fault, (int, float)):
            params = {**params, "y": params["y"] + self.fault}
        message = asyncio.run_coroutine_threadsafe(self._call(method, params), self.loop).result()
        if "error" in message:
            raise RuntimeError(message["error"])
        return message.get("result", {})

    async def reader(self):
        async for raw in self.ws:
            message = json.loads(raw.data)
            if message.get("method") == "Fetch.requestPaused":
                self.seq += 1
                await self.ws.send_json(dict(id=self.seq, method="Fetch.fulfillRequest", params=dict(
                    requestId=message["params"]["requestId"], responseCode=200,
                    responseHeaders=[dict(name="Content-Type", value="text/html")],
                    body=base64.b64encode(FIXTURE.encode()).decode())))
            elif message.get("id") in self.pending:
                self.pending.pop(message["id"]).set_result(message)


@pytest.fixture
def transport():
    executable = os.getenv("JET_TEST_CHROMIUM")
    if not executable:
        pytest.skip("Set JET_TEST_CHROMIUM for isolated real-DOM checks")
    profile = tempfile.mkdtemp(prefix="jet-prefilled-")
    process = subprocess.Popen(
        [executable, "--headless", "--remote-debugging-port=0", "--user-data-dir=" + profile,
         "--no-first-run", "--window-size=1000,900", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    loop = asyncio.new_event_loop()
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()
    client = None
    try:
        portfile = Path(profile) / "DevToolsActivePort"
        for _ in range(200):
            if portfile.exists() and portfile.read_text().strip():
                break
            time.sleep(0.05)
        port = portfile.read_text().splitlines()[0]

        async def connect():
            session = aiohttp.ClientSession()
            async with session.get(f"http://127.0.0.1:{port}/json") as response:
                page = next(p for p in await response.json() if p["type"] == "page")
            return session, await session.ws_connect(page["webSocketDebuggerUrl"], max_msg_size=0)

        client, ws = asyncio.run_coroutine_threadsafe(connect(), loop).result()
        session = Transport(loop, ws)
        asyncio.run_coroutine_threadsafe(session.reader(), loop)
        session.call("Fetch.enable", patterns=[{"urlPattern": "*"}])
        session.call("Page.navigate", url=URL)
        for _ in range(100):
            if session.call("Runtime.evaluate", expression="document.readyState",
                            returnByValue=True)["result"].get("value") == "complete":
                break
            time.sleep(0.05)
        yield session
    finally:
        if client is not None:
            asyncio.run_coroutine_threadsafe(client.close(), loop).result()
        loop.call_soon_threadsafe(loop.stop)
        process.terminate()
        process.wait(10)


def form(session):
    return session.call("Runtime.evaluate", returnByValue=True, expression=(
        "({team: team.value, email: email.value, session: document.getElementById('session').value,"
        " updates: updates.checked})"))["result"]["value"]


def action(page, label, kind, value=None):
    return next(a for a in page["actions"] if a["label"] == label and a["kind"] == kind
                and (value is None or a.get("value") == value))


def test_prefilled_select_checkbox_and_replacement_after_navigation(transport):
    browser = Browser(transport=transport)
    page = browser.observe(screenshot=False)
    assert form(transport) == {"team": "Home", "email": "old@example.test", "session": "Morning", "updates": False}
    browser.act(action(page, "Session → Afternoon", "select", "Afternoon"), page)
    page = browser.observe(screenshot=False)
    browser.act(action(page, "Updates", "click"), page)
    page = browser.observe(screenshot=False)
    browser.act(action(page, "Team name", "fill"), page, text="Solstice")
    page = browser.observe(screenshot=False)
    browser.act(action(page, "Contact email", "fill"), page, text="ash@example.test")
    assert form(transport) == {"team": "Solstice", "email": "ash@example.test", "session": "Afternoon", "updates": True}
    probes = [d["probe"] for d in transport.input_diagnostics if d["method"] == "input.probe"]
    assert len(probes) == 3 and all(p["move_on_target"] and p["pressed"] and p["on_target"] for p in probes)
    assert "Home" not in json.dumps(transport.input_diagnostics)  # Diagnostics hold no field text.


@pytest.mark.parametrize("fault,reason", [("drop", "received none"), (60, "instead of the target"),
                                          (-60, "instead of the target")])
def test_undelivered_native_click_stops_without_toggling_or_typing(transport, fault, reason):
    browser = Browser(transport=transport)
    page = browser.observe(screenshot=False)
    transport.fault = fault
    with pytest.raises(InputNotDelivered, match=reason):
        browser.act(action(page, "Updates", "click"), page)
    page = browser.observe(screenshot=False)
    with pytest.raises(InputNotDelivered):
        browser.act(action(page, "Team name", "fill"), page, text="Solstice")
    # Nothing toggled and no text went to the target or any other field.
    assert form(transport) == {"team": "Home", "email": "old@example.test", "session": "Morning", "updates": False}
    methods = [d["method"] for d in transport.input_diagnostics]
    assert "Input.insertText" not in methods and "Input.dispatchKeyEvent" not in methods
    # The pre-flight move failed, so no press was ever sent: a shifted click cannot submit.
    assert not any(d.get("stage") == "press" for d in transport.input_diagnostics)
    assert page["title"] != "Registration preview · Juniper workshop"
