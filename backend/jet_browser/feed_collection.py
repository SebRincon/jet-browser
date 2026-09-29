import asyncio
import json
import math
import time
from urllib.parse import urlsplit

from .collection_plan import canonical_url
from .site_collection import CollectionBlocked, SiteCollector

_TEXT_CAP = 20000
_TITLE_CAP = 500
_ITEM_CAP = 100
_TOP_TOLERANCE = 4.0
_POLL_SECONDS = 0.15
_POLL_BUDGET = 1.5
_X_HOSTS = {"x.com", "www.x.com", "twitter.com", "www.twitter.com"}

FEED_SNAPSHOT = r"""(() => {
  const textCap = 20000, titleCap = 500, itemCap = 100;
  const visible = (el) => {
    try {
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    } catch (e) { return false; }
  };
  const clip = (value, cap) => {
    const text = String(value || "");
    return text.length > cap ? [text.slice(0, cap), true] : [text, false];
  };
  const clean = (value) => String(value || "").replace(/\s+/g, " ").trim();
  const main = document.querySelector("main") || document.querySelector("[role='main']");
  let selected = "";
  if (main) {
    for (const tab of main.querySelectorAll("[role='tab'][aria-selected='true']")) {
      if (!visible(tab)) continue;
      selected = clean(tab.getAttribute("aria-label") || tab.innerText || tab.textContent || "").slice(0, 80);
      break;
    }
  }
  const host = location.hostname.toLowerCase().replace(/^www\./, "");
  const xHost = host === "x.com" || host === "twitter.com";
  const path = location.pathname.replace(/\/+$/, "") || "/";
  const word = (selected.toLowerCase().split(/\s+/)[0]) || "";
  let sourceKind = "feed";
  if (!main) sourceKind = "unsupported";
  else if (xHost) {
    if (path === "/i/bookmarks") sourceKind = word && word !== "bookmarks" ? "unsupported" : "x_bookmarks";
    else if (path === "/i/history" && word === "bookmarks") sourceKind = "x_bookmarks";
    else sourceKind = "unsupported";
  }
  const outer = (el, sel) => {
    const parent = el.parentElement && el.parentElement.closest(sel);
    return !(parent && main.contains(parent));
  };
  const xUrl = (article) => {
    for (const time of article.querySelectorAll("time")) {
      if (time.closest("article") !== article || time.closest("blockquote, [role=blockquote], [data-testid=quoteTweet]")) continue;
      const link = time.closest("a");
      if (!link || link.closest("article") !== article) continue;
      let u;
      try { u = new URL(link.getAttribute("href") || "", location.href); } catch (e) { continue; }
      if (u.origin !== location.origin) continue;
      const m = u.pathname.match(/^\/([^/]+)\/status\/(\d+)\/?$/);
      if (!m) continue;
      return u.origin + "/" + m[1] + "/status/" + m[2];
    }
    return "";
  };
  const xText = (article) => {
    const parts = [];
    for (const node of article.querySelectorAll("[data-testid='tweetText']")) {
      const t = (node.innerText || "").trim();
      if (t) parts.push(t);
    }
    for (const img of article.querySelectorAll("img[alt]")) {
      if (!visible(img) || img.closest("button, [role='button'], nav, aside")) continue;
      let avatar = false, n = img;
      while (n && n !== article) {
        const id = (n.getAttribute && n.getAttribute("data-testid")) || "";
        if (id.toLowerCase().indexOf("avatar") >= 0) { avatar = true; break; }
        n = n.parentElement;
      }
      if (avatar) continue;
      const alt = (img.getAttribute("alt") || "").trim();
      if (alt && !/^(image|gif|video|embedded video)$/i.test(alt)) parts.push(alt);
    }
    return parts.join("\n");
  };
  const stable = (link) => {
    if (!link || !visible(link)) return "";
    let u;
    try { u = new URL(link.getAttribute("href") || "", location.href); } catch (e) { return ""; }
    if (u.origin !== location.origin || (u.protocol !== "https:" && u.protocol !== "http:")) return "";
    const bare = u.pathname.replace(/\/+$/, "") || "/";
    if (bare === "/") return "";
    return u.origin + bare + u.search;
  };
  const genericUrl = (article) => {
    for (const time of article.querySelectorAll("time")) {
      const owner = time.closest("article, [role='article']");
      if (owner !== article) continue;
      const href = stable(time.closest("a") || time.querySelector("a"));
      if (href) return href;
    }
    return stable(article.querySelector("a[rel~='bookmark']"));
  };
  // Bound text extraction around the active viewport; a 100-item prefix would
  // permanently hide later posts on feeds that retain their old DOM nodes.
  const nearViewport = (el) => {
    let ancestor = el.parentElement;
    let top = 0, bottom = innerHeight, height = innerHeight;
    while (ancestor && ancestor !== document.body && ancestor !== document.documentElement) {
      const y = getComputedStyle(ancestor).overflowY;
      if ((y === "auto" || y === "scroll") && ancestor.scrollHeight > ancestor.clientHeight) {
        const bounds = ancestor.getBoundingClientRect();
        top = bounds.top; bottom = bounds.bottom; height = ancestor.clientHeight;
        break;
      }
      ancestor = ancestor.parentElement;
    }
    const bounds = el.getBoundingClientRect();
    return bounds.bottom > top - height / 2 && bounds.top < bottom + height / 2;
  };
  const items = [], sourceCards = [], seen = new Set();
  const push = (el, url, title, text, partial = false) => {
    if (!url || seen.has(url) || items.length >= itemCap) return;
    seen.add(url);
    const [body, cut] = clip(text, textCap);
    const [heading, headCut] = clip(title, titleCap);
    const authorNodes = [...el.querySelectorAll('[data-testid="User-Name"], [rel="author"], [itemprop="author"]')];
    const authorNode = authorNodes.find(n => !n.closest('[role="blockquote"], blockquote') && n.closest('article, [role="article"]') === el);
    const timeNode = [...el.querySelectorAll('time[datetime]')].find(n => {
      if (n.closest('[role="blockquote"], blockquote')) return false;
      const a = n.closest('a[href]');
      if (sourceKind === 'x_bookmarks') {
        try { return !!a && new URL(a.getAttribute('href'), location.href).href === url; } catch (_) { return false; }
      }
      return n.closest('article, [role="article"]') === el;
    });
    const authorName = authorNode ? clean(authorNode.innerText || authorNode.textContent || '').slice(0,160) : null;
    const published = timeNode ? (timeNode.getAttribute('datetime') || '').slice(0,80) : null;
    items.push({url: url, title: heading, text: body, truncated: cut || headCut || partial, author: authorName, published_at: published});
  };
  if (main && sourceKind === "x_bookmarks") {
    for (const article of main.querySelectorAll("article")) {
      if (!visible(article) || !outer(article, "article")) continue;
      if (article.closest("nav, aside, [role='navigation'], [role='complementary']")) continue;
      const url = xUrl(article);
      if (!url) continue;
      sourceCards.push(article);
      if (!nearViewport(article)) continue;
      const text = xText(article);
      const author = article.querySelector("[data-testid=User-Name]");
      const more = article.querySelector("[data-testid=tweet-text-show-more-link]");
      push(article, url, author ? clean(author.innerText) : text.slice(0, 160), text, !!more && visible(more));
    }
  } else if (main && sourceKind === "feed") {
    const sel = "article, [role='article']";
    for (const article of main.querySelectorAll(sel)) {
      if (!visible(article) || !outer(article, sel)) continue;
      if (article.closest("nav, aside, [role='navigation'], [role='complementary']")) continue;
      const url = genericUrl(article);
      if (!url) continue;
      sourceCards.push(article);
      if (!nearViewport(article)) continue;
      const heading = article.querySelector("h1, h2");
      push(article, url, heading ? (heading.innerText || "") : "", article.innerText || "");
    }
  }
  if (!xHost && sourceCards.length === 0) sourceKind = "unsupported";
  const canScroll = (el) => {
    if (!el || el.nodeType !== 1) return false;
    const y = getComputedStyle(el).overflowY;
    return (y === "auto" || y === "scroll") && el.scrollHeight > el.clientHeight;
  };
  const se = document.scrollingElement || document.documentElement;
  let scroller = se;
  if (sourceCards.length) {
    let node = sourceCards[0];
    while (node) {
      node = node.parentElement;
      if (!node) break;
      let shared = true;
      for (const card of sourceCards) if (!node.contains(card)) { shared = false; break; }
      if (shared && canScroll(node)) { scroller = node; break; }
      if (node === document.body || node === document.documentElement) break;
    }
  }
  const rootSym = Symbol.for("jet.feed.root");
  let rootId = "document", measured = se;
  if (scroller && scroller !== se && scroller !== document.documentElement && scroller !== document.body) {
    const bagKey = Symbol.for("jet.feed.ids");
    const bag = window[bagKey] || (window[bagKey] = new WeakMap());
    rootId = bag.get(scroller);
    if (!rootId) {
      rootId = "r" + Math.random().toString(36).slice(2, 12);
      bag.set(scroller, rootId);
    }
    measured = scroller;
    window[rootSym] = scroller;
  } else window[rootSym] = se;
  let login = false;
  for (const input of document.querySelectorAll('input[type="password"]')) {
    if (visible(input)) { login = true; break; }
  }
  let loading = false;
  const scope = main || document;
  for (const node of scope.querySelectorAll('[aria-busy="true"], [role="progressbar"]')) {
    if (visible(node)) { loading = true; break; }
  }
  const banned = (el) => {
    let node = el;
    while (node && node.nodeType === 1) {
      const id = ((node.id || "") + " " + ((node.getAttribute && node.getAttribute("data-testid")) || "") + " " + ((node.getAttribute && node.getAttribute("class")) || "")).toLowerCase();
      if (id.indexOf("cookie") >= 0 || id.indexOf("consent") >= 0 || id.indexOf("gdpr") >= 0) return true;
      node = node.parentElement;
    }
    return false;
  };
  const statusBits = [];
  const pushStatus = (el) => {
    if (!el || !visible(el) || banned(el)) return;
    const text = clean(el.innerText || el.textContent || "");
    if (!text || /cookie/i.test(text)) return;
    statusBits.push(text.slice(0, 600));
  };
  for (const el of document.querySelectorAll("[role='alert']")) pushStatus(el);
  if (main) {
    for (const el of main.querySelectorAll("[data-testid='emptyState'], [role='status']")) pushStatus(el);
  }
  let statusText = "";
  for (const bit of statusBits) {
    if (statusText.length >= 600) break;
    statusText = statusText ? statusText + " " + bit : bit;
  }
  statusText = statusText.slice(0, 600);
  const [title] = clip(document.title || "", titleCap);
  const navigation = [];
  if (xHost && main) {
    for (const tab of main.querySelectorAll("[role='tab'][href]")) {
      if (!visible(tab) || navigation.length >= 3) continue;
      let u;
      try { u = new URL(tab.getAttribute("href") || "", location.href); } catch (e) { continue; }
      if (u.origin !== location.origin || (u.protocol !== "https:" && u.protocol !== "http:")) continue;
      const bare = u.pathname.replace(/\/+$/, "") || "/";
      if (bare !== "/i/history" && bare !== "/i/history/likes" && bare !== "/i/bookmarks") continue;
      navigation.push({
        label: clean(tab.getAttribute("aria-label") || tab.innerText || tab.textContent || "").slice(0, 80),
        url: u.origin + bare
      });
    }
  }
  return {
    url: location.href,
    title: title,
    document_id: String(performance.timeOrigin),
    ready_state: document.readyState,
    source_kind: sourceKind,
    selected_tab: selected,
    navigation: navigation,
    items: items,
    scroll: {top: measured.scrollTop || 0, height: measured.scrollHeight || 0, viewport: measured.clientHeight || 0, root: rootId},
    login_required: login,
    loading: loading,
    status_text: statusText,
    end_of_feed: false
  };
})()"""

_SCROLL = r"""(guard) => {
  try {
    if (location.href !== guard.url) return {ok: false};
    if (String(performance.timeOrigin) !== String(guard.document_id)) return {ok: false};
    const main = document.querySelector("main") || document.querySelector("[role='main']");
    if (!main) return {ok: false};
    let label = "";
    for (const tab of main.querySelectorAll("[role='tab'][aria-selected='true']")) {
      const r = tab.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      label = String(tab.getAttribute("aria-label") || tab.innerText || tab.textContent || "").replace(/\s+/g, " ").trim().slice(0, 300);
      break;
    }
    if (label !== guard.selected_tab) return {ok: false};
    const fraction = Number(guard.fraction), minDelta = Number(guard.min_delta);
    const maxDelta = Number(guard.max_delta), tolerance = Number(guard.tolerance);
    if (![fraction, minDelta, maxDelta, tolerance].every(Number.isFinite)) return {ok: false};
    const se = document.scrollingElement || document.documentElement;
    const rootEl = window[Symbol.for("jet.feed.root")];
    let scroller = se;
    if (guard.root === "document") {
      if (rootEl !== se) return {ok: false};
    } else {
      const bag = window[Symbol.for("jet.feed.ids")];
      if (!rootEl || !rootEl.isConnected || !bag || bag.get(rootEl) !== guard.root) return {ok: false};
      scroller = rootEl;
    }
    const before = scroller.scrollTop;
    if (!Number.isFinite(before) || Math.abs(before - Number(guard.top)) > tolerance) return {ok: false};
    let delta = Math.floor(scroller.clientHeight * fraction);
    if (delta < minDelta) delta = minDelta;
    if (delta > maxDelta) delta = maxDelta;
    const maxTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
    scroller.scrollTop = Math.min(maxTop, before + delta);
    const top = scroller.scrollTop;
    if (!Number.isFinite(top)) return {ok: false};
    return {ok: true, top: top};
  } catch (e) {
    return {ok: false};
  }
}"""


def _published(value):
    from datetime import datetime
    if not isinstance(value, str) or len(value) > 80:
        return None
    try:
        datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None
    return value


def _finite(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def _origin(url):
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}".lower()


def _path(url):
    path = urlsplit(url).path or "/"
    return path[:-1] if len(path) > 1 and path.endswith("/") else path


def _tab_word(label):
    parts = label.casefold().split()
    return parts[0] if parts else ""


class FeedCollector(SiteCollector):
    """Read and scroll a local X bookmarks or generic permalink feed. Never navigates."""

    def __init__(self, bridge, plan, stopped, *, expected_url=None):
        super().__init__(bridge, plan, stopped, expected_url=expected_url)
        self._seen = None

    async def _eval(self, expression):
        self._raise_if_stopped()
        payload = await self._call(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True},
        )
        if payload.get("exceptionDetails"):
            raise CollectionBlocked("browser_unavailable")
        inner = payload.get("result")
        if not isinstance(inner, dict) or "value" not in inner:
            raise CollectionBlocked("browser_unavailable")
        return inner["value"]

    def _expected_origin(self):
        origin = getattr(self.plan, "origin", "")
        if isinstance(origin, str) and "://" in origin:
            return _origin(origin)
        return _origin(self.expected_url)

    def _items(self, raw_items):
        if not isinstance(raw_items, list):
            raise CollectionBlocked("browser_unavailable")
        origin, items, now = self._expected_origin(), [], time.time()
        for raw in raw_items[:_ITEM_CAP]:
            if not isinstance(raw, dict):
                raise CollectionBlocked("browser_unavailable")
            href, title, text, flag = raw.get("url"), raw.get("title"), raw.get("text"), raw.get("truncated")
            if (
                not isinstance(href, str)
                or not isinstance(title, str)
                or not isinstance(text, str)
                or not isinstance(flag, bool)
            ):
                raise CollectionBlocked("browser_unavailable")
            try:
                canon = canonical_url(href)
            except Exception:
                continue
            if _origin(canon) != origin:
                continue
            try:
                allowed = self.plan.item_in_scope(canon)
            except Exception as exc:
                raise CollectionBlocked("browser_unavailable") from exc
            if not allowed:
                continue
            if len(title) > _TITLE_CAP:
                title, flag = title[:_TITLE_CAP], True
            if len(text) > _TEXT_CAP:
                text, flag = text[:_TEXT_CAP], True
            items.append(
                {
                    "url": canon,
                    "title": title,
                    "text": text,
                    "truncated": flag,
                    "captured_at": now,
                    "author": raw.get('author')[:160] if isinstance(raw.get('author'), str) else None,
                    "published_at": _published(raw.get('published_at')),
                }
            )
        return items

    def _accept(self, value, expected_top):
        if not isinstance(value, dict):
            raise CollectionBlocked("browser_unavailable")
        href, title = value.get("url"), value.get("title")
        ready, document_id = value.get("ready_state"), value.get("document_id")
        kind, tab = value.get("source_kind"), value.get("selected_tab")
        login, loading = value.get("login_required"), value.get("loading")
        scroll, raw_items = value.get("scroll"), value.get("items")
        if not all(isinstance(part, str) for part in (href, title, ready, document_id, kind, tab)):
            raise CollectionBlocked("browser_unavailable")
        if not all(isinstance(part, bool) for part in (login, loading)):
            raise CollectionBlocked("browser_unavailable")
        status_text = value.get("status_text", "")
        if not isinstance(status_text, str):
            raise CollectionBlocked("browser_unavailable")
        status_text = " ".join(status_text.split())[:600]
        if not isinstance(scroll, dict) or value.get("end_of_feed") is not False:
            raise (
                CollectionBlocked("unsupported_feed")
                if value.get("end_of_feed") is True
                else CollectionBlocked("browser_unavailable")
            )
        if login:
            raise CollectionBlocked("login_required")
        try:
            canon = canonical_url(href)
            start = canonical_url(self.plan.start_url)
        except Exception as exc:
            raise CollectionBlocked("browser_unavailable") from exc
        if canon != start or canon != self.expected_url:
            raise CollectionBlocked("source_changed")
        host = (urlsplit(canon).hostname or "").lower()
        if kind == "unsupported":
            raise CollectionBlocked("unsupported_feed")
        if kind not in ("x_bookmarks", "feed") or kind != self.plan.source_kind:
            raise CollectionBlocked("source_mismatch")
        if kind != "x_bookmarks" and host in _X_HOSTS:
            raise CollectionBlocked("unsupported_feed")
        if kind == "x_bookmarks":
            if host not in _X_HOSTS:
                raise CollectionBlocked("source_mismatch")
            word, path = _tab_word(tab), _path(canon)
            if path == "/i/bookmarks":
                if word and word != "bookmarks":
                    raise CollectionBlocked("source_mismatch")
            elif path == "/i/history":
                if word != "bookmarks":
                    raise CollectionBlocked("unsupported_feed")
            else:
                raise CollectionBlocked("unsupported_feed")
        top, height, viewport = (
            _finite(scroll.get("top")),
            _finite(scroll.get("height")),
            _finite(scroll.get("viewport")),
        )
        root = scroll.get("root")
        if top is None or height is None or viewport is None or top < 0 or height < 0 or viewport <= 0:
            raise CollectionBlocked("browser_unavailable")
        if not isinstance(root, str) or (root != "document" and not root.startswith("r")):
            raise CollectionBlocked("browser_unavailable")
        items = self._items(raw_items)
        if self._seen is not None:
            seen_doc, seen_root, seen_top = self._seen
            if document_id != seen_doc or root != seen_root:
                raise CollectionBlocked("source_changed")
            anchor = seen_top if expected_top is None else expected_top
            if abs(top - anchor) > _TOP_TOLERANCE:
                raise CollectionBlocked("source_changed")
        snapshot = {
            "url": canon,
            "href": href,
            "title": title[:_TITLE_CAP],
            "document_id": document_id,
            "ready_state": ready,
            "source_kind": kind,
            "selected_tab": tab,
            "items": items,
            "scroll": {"top": top, "height": height, "viewport": viewport, "root": root},
            "login_required": False,
            "loading": loading,
            "status_text": status_text,
            "end_of_feed": False,
        }
        self._seen = (document_id, root, top)
        return snapshot

    async def _read(self, expected_top):
        return self._accept(await self._eval(FEED_SNAPSHOT), expected_top)

    async def read(self):
        self._raise_if_stopped()
        return await self._read(None)

    def _guard(self, snapshot):
        if self._seen is None or not isinstance(snapshot, dict):
            raise CollectionBlocked("scroll_uncertain")
        scroll = snapshot.get("scroll")
        href, document_id, tab = snapshot.get("href"), snapshot.get("document_id"), snapshot.get("selected_tab")
        if not isinstance(scroll, dict) or not all(isinstance(part, str) for part in (href, document_id, tab)):
            raise CollectionBlocked("scroll_uncertain")
        top = _finite(scroll.get("top"))
        root = scroll.get("root")
        if top is None or not isinstance(root, str):
            raise CollectionBlocked("scroll_uncertain")
        seen_doc, seen_root, seen_top = self._seen
        if document_id != seen_doc or root != seen_root or abs(top - seen_top) > _TOP_TOLERANCE:
            raise CollectionBlocked("source_changed")
        try:
            if canonical_url(snapshot.get("url")) != self.expected_url:
                raise CollectionBlocked("source_changed")
        except CollectionBlocked:
            raise
        except Exception as exc:
            raise CollectionBlocked("scroll_uncertain") from exc
        return {
            "url": href,
            "document_id": document_id,
            "root": root,
            "top": top,
            "selected_tab": tab,
            "tolerance": _TOP_TOLERANCE,
            "fraction": 0.7,
            "min_delta": 1,
            "max_delta": 800,
        }

    async def scroll(self, snapshot):
        self._raise_if_stopped()
        guard = self._guard(snapshot)
        expression = "(" + _SCROLL + ")(" + json.dumps(guard, ensure_ascii=True, separators=(",", ":")) + ")"
        try:
            raw = await self._eval(expression)
        except CollectionBlocked as exc:
            raise CollectionBlocked("scroll_uncertain") from exc
        if not isinstance(raw, dict) or raw.get("ok") is not True:
            raise CollectionBlocked("scroll_uncertain")
        new_top = _finite(raw.get("top"))
        if new_top is None or new_top < guard["top"] - _TOP_TOLERANCE or new_top > guard["top"] + 800 + _TOP_TOLERANCE:
            raise CollectionBlocked("scroll_uncertain")
        before = (
            tuple(item["url"] for item in snapshot.get("items", [])),
            snapshot.get("loading"),
            snapshot.get("scroll", {}).get("height"),
        )
        deadline, observed = time.monotonic() + _POLL_BUDGET, None
        while time.monotonic() < deadline:
            self._raise_if_stopped()
            await asyncio.sleep(_POLL_SECONDS)
            observed = await self._read(new_top)
            activity = (
                tuple(item["url"] for item in observed["items"]),
                observed["loading"],
                observed["scroll"]["height"],
            )
            if activity != before and not observed["loading"]:
                return observed
        if observed is None:
            raise CollectionBlocked("scroll_uncertain")
        return observed
