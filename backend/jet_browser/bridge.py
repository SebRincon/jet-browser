"""Deadline-bound requests to one authenticated native host and exact tab."""

import asyncio
import time
import uuid
from contextlib import nullcontext
from dataclasses import dataclass


class BridgeError(RuntimeError):
    pass


@dataclass
class Pending:
    request: dict
    future: asyncio.Future
    host_id: str
    expires: float
    dispatched: bool = False
    trace_context: object = None
    queued_at: float = 0
    preserve_on_stop: bool = False


class BrowserBridge:
    def __init__(self, trace=None):
        self.trace = trace
        self.host_id = None
        self.last_seen = 0.0
        self.active_tab_id = None
        self.tabs = []
        self.pending = {}
        self.supports_background = False
        self.tab_owners = {}
        self.queue = asyncio.Queue()

    def sync(self, body):
        host_id = body.get("host_id")
        tabs = body.get("tabs")
        if not isinstance(host_id, str) or not host_id or not isinstance(tabs, list) or len(tabs) > 50:
            raise ValueError("Invalid native browser registration")
        for tab in tabs:
            if not isinstance(tab, dict) or not isinstance(tab.get("id"), str):
                raise ValueError("Invalid native tab")
        changed = host_id != self.host_id or not self.online
        if self.host_id and host_id != self.host_id:
            if self.online:
                raise BridgeError("Another Jet Browser window owns this service")
            self.fail_pending("Browser host was replaced")
        if changed:
            self.tab_owners.clear()
        capabilities = body.get("capabilities") or {}
        if not isinstance(capabilities, dict):
            raise ValueError("Invalid native capabilities")
        self.supports_background = capabilities.get("background_tabs") is True
        self.host_id, self.last_seen = host_id, time.monotonic()
        self.tabs = [{k: str(t.get(k, "")) for k in ("id", "url", "title")} for t in tabs]
        self.tab_owners = {tab: owner for tab, owner in self.tab_owners.items() if tab in {t["id"] for t in self.tabs}}
        active = body.get("active_tab_id")
        self.active_tab_id = active if active in {t["id"] for t in self.tabs} else None
        if changed and self.trace:
            self.trace.emit("browser.connected", host_id=host_id, connected=True)

    @property
    def online(self):
        return bool(self.host_id and time.monotonic() - self.last_seen < 10)

    def tab(self, tab_id=None):
        if not self.online:
            raise BridgeError("Open Jet Browser to connect its native browser")
        selected = tab_id or self.active_tab_id
        if selected not in {t["id"] for t in self.tabs}:
            raise BridgeError("The selected browser tab is no longer available")
        return selected

    def claim_tab(self, tab_id, owner):
        self.tab(tab_id)
        if not self.supports_background or not isinstance(owner, str) or not owner or len(owner) > 150:
            raise BridgeError("Background tab ownership is unavailable")
        if tab_id in self.tab_owners and self.tab_owners[tab_id] != owner:
            raise BridgeError("Tab already belongs to another job")
        self.tab_owners[tab_id] = owner

    def release_tab(self, tab_id, owner):
        if self.tab_owners.get(tab_id) == owner:
            self.tab_owners.pop(tab_id, None)

    def tab_owner(self, tab_id):
        return self.tab_owners.get(tab_id) if self.supports_background else None

    async def call(self, tab_id, method, params=None, timeout=15, preserve_on_stop=False):
        attributes = {"tab_id": tab_id, "method": method}
        if method == "Input.insertText":
            attributes["input_chars"] = len((params or {}).get("text", ""))
        context = self.trace.span("browser.command", **attributes) if self.trace else nullcontext()
        with context:
            return await self._call(tab_id, method, params, timeout, preserve_on_stop)

    async def _call(self, tab_id, method, params, timeout, preserve_on_stop):
        if method == "Browser.openTab":
            if not self.online:
                raise BridgeError("Open Jet Browser first")
        else:
            tab_id = self.tab(tab_id)
        request_id = uuid.uuid4().hex
        future = asyncio.get_running_loop().create_future()
        request = {"command_id": request_id, "tab_id": tab_id, "method": method, "params": params or {}}
        if method in {"Runtime.evaluate", "Page.navigate"} and self.tab_owner(tab_id):
            request["background_owner"] = self.tab_owner(tab_id)
        self.pending[request_id] = Pending(
            request,
            future,
            self.host_id,
            time.monotonic() + timeout,
            trace_context=self.trace.capture() if self.trace else None,
            queued_at=time.monotonic(),
            preserve_on_stop=preserve_on_stop,
        )
        if self.trace:
            self.trace.emit("browser.command.queued", command_id=request_id, method=method, tab_id=tab_id)
        await self.queue.put(request_id)
        try:
            return await asyncio.wait_for(future, timeout)
        except TimeoutError:
            raise BridgeError("Native browser request timed out; its input was not retried") from None
        finally:
            self.pending.pop(request_id, None)

    async def next_command(self, host_id):
        if host_id != self.host_id:
            raise BridgeError("Unknown native browser host")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                request_id = await asyncio.wait_for(self.queue.get(), deadline - time.monotonic())
            except TimeoutError:
                return {"command": None}
            item = self.pending.get(request_id)
            if not item or item.future.done() or item.expires <= time.monotonic():
                continue
            if item.host_id != host_id:
                continue
            if item.request["method"] != "Browser.openTab":
                try:
                    self.tab(item.request["tab_id"])
                except BridgeError as error:
                    item.future.set_exception(error)
                    continue
            owner = item.request.get("background_owner")
            if owner and self.tab_owner(item.request["tab_id"]) != owner:
                item.future.set_exception(BridgeError("Tab ownership changed before dispatch"))
                continue
            item.dispatched = True
            if item.trace_context:
                item.trace_context.run(
                    self.trace.emit,
                    "browser.command.dispatched",
                    command_id=request_id,
                    method=item.request["method"],
                    tab_id=item.request["tab_id"],
                    queue_ms=round((time.monotonic() - item.queued_at) * 1000, 2),
                )
            return item.request
        return {"command": None}

    def resolve(self, body):
        if body.get("host_id") != self.host_id:
            raise BridgeError("Unknown native browser host")
        item = self.pending.get(body.get("command_id"))
        if item is None or item.future.done():
            return False  # A timed-out response never revives or repeats a request.
        if not item.dispatched:
            raise BridgeError("Browser result arrived before dispatch")
        if item.trace_context:
            item.trace_context.run(
                self.trace.emit,
                "browser.command.ack",
                command_id=body.get("command_id"),
                method=item.request["method"],
                status="error" if body.get("error") else "ok",
                error=str(body["error"])[:800] if body.get("error") else None,
                duration_ms=round((time.monotonic() - item.queued_at) * 1000, 2),
            )
        if body.get("error"):
            item.future.set_exception(BridgeError(str(body["error"])[:800]))
        else:
            item.future.set_result(body.get("result", {}))
        return True

    def fail_pending(self, message):
        for item in self.pending.values():
            if not item.future.done():
                item.future.set_exception(BridgeError(message))

    def cancel_queued(self):
        for item in self.pending.values():
            if not item.dispatched and not item.preserve_on_stop and not item.future.done():
                item.future.set_exception(BridgeError("Stopped before native dispatch"))


class ThreadBridge:
    """Synchronous CDP-shaped adapter used only by the serial model worker."""

    def __init__(self, bridge, loop, tab_id, stopped):
        self.bridge, self.loop, self.tab_id, self.stopped = bridge, loop, tab_id, stopped
        self.trace = getattr(bridge, "trace", None)
        self.action_active = False
        self.input_started = False
        self.input_diagnostics = []

    def call(self, method, **params):
        # Finish a dispatched action (including mouse release), then stop subsequent requests.
        if self.stopped.is_set() and not self.action_active:
            raise BridgeError("Stopped before the next browser input")
        future = asyncio.run_coroutine_threadsafe(
            self.bridge.call(self.tab_id, method, params, preserve_on_stop=self.action_active and self.input_started),
            self.loop,
        )
        try:
            result = future.result(timeout=20)
            if self.action_active and method.startswith("Input."):
                self.input_started = True
            return result
        except TimeoutError:
            future.cancel()
            raise BridgeError("Browser host did not respond; no retry was sent") from None
