import asyncio
import time

from .collection_plan import canonical_url

_TEXT_CAP = 20000
_LINK_CAP = 500
_SETTLE_SECONDS = 10.0
_POLL_SECONDS = 0.1

SNAPSHOT = r"""(() => {
  const textCap = 20000, linkCap = 500;
  const visible = (el) => { try { return el.getClientRects().length > 0; } catch (e) { return false; } };
  const blocked = (href, label) => {
    const blob = ((label || "") + " " + (href || "")).toLowerCase();
    if (/logout|signout|sign-out|log-out|unsubscribe|\bdelete\b/.test(blob)) return true;
    try {
      const u = new URL(href, location.href);
      if (/logout|signout|sign-out|log-out|unsubscribe|\/delete\b/.test(u.pathname.toLowerCase())) return true;
      const action = (u.searchParams.get("action") || "").toLowerCase();
      if (action === "delete" || action === "remove" || action === "logout") return true;
    } catch (e) {}
    return false;
  };
  const root = document.querySelector("main") || document.body;
  let text = "", textTruncated = false;
  if (root && typeof root.innerText === "string") {
    text = root.innerText;
    if (text.length > textCap) { text = text.slice(0, textCap); textTruncated = true; }
  }
  const links = [];
  let linksTruncated = false;
  for (const a of document.querySelectorAll("a[href]")) {
    if (!visible(a)) continue;
    let href = "";
    try { href = new URL(a.getAttribute("href"), location.href).href; } catch (e) { continue; }
    if (blocked(href, a.innerText || a.textContent || "")) continue;
    if (links.length >= linkCap) { linksTruncated = true; break; }
    links.push(href);
  }
  let loginRequired = false;
  for (const input of document.querySelectorAll('input[type="password"]')) {
    if (visible(input)) { loginRequired = true; break; }
  }
  return {
    url: location.href,
    title: document.title || "",
    text: text,
    text_truncated: textTruncated,
    ready_state: document.readyState,
    document_id: String(performance.timeOrigin),
    links: links,
    links_truncated: linksTruncated,
    login_required: loginRequired
  };
})()"""


class CollectionBlocked(Exception):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


class SiteCollector:
    def __init__(self, bridge, plan, stopped, *, expected_url=None):
        self.bridge = bridge
        self.plan = plan
        self.stopped = stopped
        self._host_id = bridge.host_id
        self._background_owner = getattr(bridge,"tab_owner",lambda _:None)(plan.tab_id)
        self.expected_url = canonical_url(expected_url or plan.start_url)
        self._require_tab()

    def _raise_if_stopped(self):
        if self.stopped.is_set():
            raise asyncio.CancelledError()

    def _require_tab(self):
        self._raise_if_stopped()
        owned = self._background_owner and getattr(self.bridge,"tab_owner",lambda _:None)(self.plan.tab_id) == self._background_owner
        if self.bridge.host_id != self._host_id or (self._background_owner and not owned) or (not owned and self.bridge.active_tab_id != self.plan.tab_id):
            raise CollectionBlocked("browser_unavailable")
        try:
            tab = self.bridge.tab(self.plan.tab_id)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise CollectionBlocked("browser_unavailable") from exc
        if tab != self.plan.tab_id:
            raise CollectionBlocked("browser_unavailable")

    async def _call(self, method, params):
        self._require_tab()
        try:
            result = await self.bridge.call(self.plan.tab_id, method, params)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise CollectionBlocked("browser_unavailable") from exc
        self._require_tab()
        if not isinstance(result, dict):
            raise CollectionBlocked("browser_unavailable")
        return result

    def _accept(self, value, *, lock_expected):
        if not isinstance(value, dict):
            raise CollectionBlocked("browser_unavailable")
        raw_url = value.get("url")
        if not isinstance(raw_url, str):
            raise CollectionBlocked("browser_unavailable")
        try:
            url = canonical_url(raw_url)
        except Exception as exc:
            raise CollectionBlocked("browser_unavailable") from exc
        if lock_expected and url != self.expected_url:
            raise CollectionBlocked("source_changed")
        if not self.plan.in_scope(url):
            raise CollectionBlocked("out_of_scope")
        title, text = value.get("title"), value.get("text")
        text_flag, link_flag = value.get("text_truncated"), value.get("links_truncated")
        ready, document_id = value.get("ready_state"), value.get("document_id")
        login, raw_links = value.get("login_required"), value.get("links")
        if not all(isinstance(item, str) for item in (title, text, ready, document_id)):
            raise CollectionBlocked("browser_unavailable")
        if not all(isinstance(item, bool) for item in (text_flag, link_flag, login)):
            raise CollectionBlocked("browser_unavailable")
        if not isinstance(raw_links, list):
            raise CollectionBlocked("browser_unavailable")
        if login:
            raise CollectionBlocked("login_required")
        if len(text) > _TEXT_CAP:
            text, text_flag = text[:_TEXT_CAP], True
        links, overflow = [], False
        for item in raw_links[:_LINK_CAP]:
            if not isinstance(item, str):
                continue
            try:
                canon = canonical_url(item)
            except Exception:
                continue
            if not self.plan.in_scope(canon):
                continue
            if len(links) >= _LINK_CAP:
                overflow = True
                break
            links.append(canon)
        link_flag = link_flag or overflow or len(raw_links) > _LINK_CAP
        return {
            "url": url,
            "title": title[:500],
            "text": text,
            "truncated": bool(text_flag or link_flag or len(title) > 500),
            "links": links,
            "document_id": document_id,
            "ready_state": ready,
            "captured_at": time.time(),
        }

    async def _snapshot(self, *, lock_expected):
        payload = await self._call(
            "Runtime.evaluate",
            {"expression": SNAPSHOT, "returnByValue": True},
        )
        inner = payload.get("result")
        if not isinstance(inner, dict) or "value" not in inner or payload.get("exceptionDetails"):
            raise CollectionBlocked("browser_unavailable")
        return self._accept(inner["value"], lock_expected=lock_expected)

    async def _wait(self, before, *, require_change):
        current, deadline = before, time.monotonic() + _SETTLE_SECONDS
        while True:
            changed = current["url"] != before["url"] or current["document_id"] != before["document_id"]
            if current["ready_state"] in ("interactive", "complete") and (changed or not require_change):
                return current
            if time.monotonic() >= deadline:
                raise CollectionBlocked("navigation_unsettled")
            await asyncio.sleep(_POLL_SECONDS)
            current = await self._snapshot(lock_expected=False)

    async def read(self, url, *, navigate=True):
        try:
            desired = canonical_url(url)
        except Exception as exc:
            raise CollectionBlocked("browser_unavailable") from exc
        if not self.plan.in_scope(desired):
            raise CollectionBlocked("out_of_scope")
        before = await self._snapshot(lock_expected=True)
        if before["url"] != desired:
            if not navigate:
                raise CollectionBlocked("navigation_unsettled")
            nav = await self._call("Page.navigate", {"url": url})
            if nav.get("errorText"):
                raise CollectionBlocked("navigation_unsettled")
            snap = await self._wait(before, require_change=True)
        else:
            snap = await self._wait(before, require_change=False)
        self.expected_url = snap["url"]
        return snap
