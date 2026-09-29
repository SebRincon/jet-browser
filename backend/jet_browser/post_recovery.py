"""Bounded X status recovery in one owned detail tab."""

from __future__ import annotations

import asyncio
import json
import re
import time
import urllib.parse
import uuid

_HOSTS = frozenset({"x.com", "www.x.com", "twitter.com", "www.twitter.com"})
_STATUS_PATH = re.compile(r"^/([A-Za-z0-9_]{1,15})/status/(\d+)/?$")
_BLOCKED = frozenset({"login", "restricted", "deleted", "missing_target"})
_POLL_S = 0.15
_LOAD_S = 12.0
_SETTLE_S = 0.2
_EXPAND_S = 2.0
_CAP = 20000

READ_POST = r"""(target) => {
  const hostOk = location.protocol === 'https:' && /^(www\.)?(x|twitter)\.com$/.test(location.hostname);
  const pm = (location.pathname || '').match(/^\/([A-Za-z0-9_]{1,15})\/status\/(\d+)\/?$/);
  const pathId = pm ? pm[2] : '';
  if (location.href === 'about:blank' || location.href === '') return {state:'loading'};
  if (!hostOk || !pm || pathId !== String(target.statusId)) {
    const path = location.pathname || '';
    if (/\/login|\/i\/flow\/login|\/i\/flow\/signup/.test(path)) return {state:'blocked', reason:'login'};
    return {state:'blocked', reason:'missing_target'};
  }
  let art = null, timeEl = null;
  for (const cand of document.querySelectorAll('main article, [role=main] article')) {
    for (const t of cand.querySelectorAll('time')) {
      if (t.closest('article') !== cand || t.closest('blockquote,[role=blockquote],[data-testid=quoteTweet]')) continue;
      const a = t.closest('a');
      const href = (a && a.getAttribute('href')) || '';
      const mm = href.match(/\/status\/(\d+)/);
      if (mm && mm[1] === String(target.statusId)) { art = cand; timeEl = t; break; }
    }
    if (art) break;
  }
  if (!art) {
    const root = document.querySelector('[data-testid="primaryColumn"]') || document.body;
    const sample = ((root && root.innerText) || '').slice(0, 1200);
    if (/log in to x|sign in to x/i.test(sample)) return {state:'blocked', reason:'login'};
    if (/this post was deleted|this post is unavailable|page doesn.?t exist|doesn.t exist/i.test(sample)) return {state:'blocked', reason:'deleted'};
    if (/unable to view|age-restricted|protected account|you.?re blocked|account is suspended/i.test(sample)) return {state:'blocked', reason:'restricted'};
    return {state:'loading'};
  }
  let full = '';
  for (const n of art.querySelectorAll('[data-testid="tweetText"]')) {
    const piece = n.innerText || '';
    if (!piece) continue;
    full = full ? full + '\n\n' + piece : piece;
  }
  let author = null;
  for (const n of art.querySelectorAll('[data-testid="User-Name"]')) {
    if (n.closest('article') !== art || n.closest('blockquote,[role=blockquote],[data-testid=quoteTweet]')) continue;
    const line = (n.innerText || '').split('\n').map(s => s.trim()).filter(Boolean)[0];
    if (line) { author = line; break; }
  }
  const mores = [];
  for (const l of art.querySelectorAll('[data-testid="tweet-text-show-more-link"],button,a,[role=button]')) {
    if (l.closest('article') !== art || l.closest('blockquote,[role=blockquote],[data-testid=quoteTweet]')) continue;
    const r=l.getBoundingClientRect();
    if (r.width>0 && r.height>0 && (l.getAttribute('data-testid')==='tweet-text-show-more-link' || (l.innerText||'').trim().toLowerCase()==='show more')) mores.push(l);
  }
  const capped = full.length > 20000;
  return {state:'ready', text: capped ? full.slice(0, 20000) : full, n: full.length, author,
    published_at: timeEl.getAttribute('datetime') || null, show_more_n: mores.length, capped,
    time_origin: String(performance.timeOrigin), location: location.href, status_id: pathId};
}"""

EXPAND_POST = r"""(guard) => {
  const hostOk = location.protocol === 'https:' && /^(www\.)?(x|twitter)\.com$/.test(location.hostname);
  const pm = (location.pathname || '').match(/^\/([A-Za-z0-9_]{1,15})\/status\/(\d+)\/?$/);
  if (!hostOk || !pm || pm[2] !== String(guard.statusId)) return {ok:false};
  if (String(performance.timeOrigin) !== String(guard.timeOrigin)) return {ok:false};
  const bare = location.href.split('#')[0];
  const want = String(guard.location || '').split('#')[0];
  if (bare !== want) return {ok:false};
  let art = null;
  for (const cand of document.querySelectorAll('main article, [role=main] article')) {
    for (const t of cand.querySelectorAll('time')) {
      if (t.closest('article') !== cand || t.closest('blockquote,[role=blockquote],[data-testid=quoteTweet]')) continue;
      const a = t.closest('a');
      const href = (a && a.getAttribute('href')) || '';
      const mm = href.match(/\/status\/(\d+)/);
      if (mm && mm[1] === String(guard.statusId)) { art = cand; break; }
    }
    if (art) break;
  }
  if (!art) return {ok:false};
  let full = '';
  for (const n of art.querySelectorAll('[data-testid="tweetText"]')) {
    const piece = n.innerText || '';
    if (!piece) continue;
    full = full ? full + '\n\n' + piece : piece;
  }
  const view = full.length > 20000 ? full.slice(0, 20000) : full;
  if (view !== guard.oldText || full.length !== guard.n) return {ok:false};
  const mores = [];
  for (const l of art.querySelectorAll('[data-testid="tweet-text-show-more-link"],button,a,[role=button]')) {
    if (l.closest('article') !== art || l.closest('blockquote,[role=blockquote],[data-testid=quoteTweet]')) continue;
    const r=l.getBoundingClientRect();
    if (r.width>0 && r.height>0 && (l.getAttribute('data-testid')==='tweet-text-show-more-link' || (l.innerText||'').trim().toLowerCase()==='show more')) mores.push(l);
  }
  if (mores.length !== 1) return {ok:false};
  const link = mores[0];
  if (link.closest('[data-testid="reply"],[data-testid="like"],[data-testid="bookmark"],[data-testid="retweet"]')) return {ok:false};
  link.click();
  return {ok:true};
}"""


class RecoveryBlocked(Exception):
    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)


def _js_call(fn: str, arg: object) -> str:
    return "(" + fn + ")(" + json.dumps(arg) + ")"


def _field(item: object, key: str):
    if isinstance(item, dict):
        return item.get(key)
    return getattr(item, key, None)


def _stopped(flag: object) -> bool:
    if flag is None:
        return False
    if callable(flag):
        return bool(flag())
    is_set = getattr(flag, "is_set", None)
    if callable(is_set):
        return bool(is_set())
    return bool(flag)


def _parse_status(url: object):
    if not isinstance(url, str) or not url:
        return None
    try:
        parts = urllib.parse.urlsplit(url)
        _ = parts.port
    except ValueError:
        return None
    if (
        parts.scheme != "https"
        or parts.username
        or parts.password
        or parts.port
        or parts.query
        or parts.fragment
        or parts.hostname not in _HOSTS
    ):
        return None
    match = _STATUS_PATH.match(parts.path)
    if not match:
        return None
    return match.group(2)


def _url_has_status(url: object, status_id: str) -> bool:
    if not isinstance(url, str):
        return False
    try:
        parts = urllib.parse.urlsplit(url)
        _ = parts.port
    except ValueError:
        return None
    if parts.scheme != "https" or parts.hostname not in _HOSTS:
        return False
    match = _STATUS_PATH.match(parts.path)
    return bool(match and match.group(2) == status_id)


def _tab(bridge: object, tab_id: object):
    try:
        tab = bridge.tab(tab_id)
    except Exception:
        return None
    return next((t for t in bridge.tabs if t.get("id") == tab_id), None) if tab else None


def _feed_url(bridge: object, feed_tab_id: object) -> str:
    tab = _tab(bridge, feed_tab_id)
    if tab is None:
        raise RecoveryBlocked("feed_missing")
    return tab.get("url") or ""


def _owned_state(bridge: object, owned: object, feed_tab_id: object, opened_at: float, background=False) -> str:
    if background:
        return "ok"
    active = bridge.active_tab_id
    if active == owned:
        return "ok"
    if (time.monotonic() - opened_at) <= _SETTLE_S and active == feed_tab_id:
        return "settle"
    raise RecoveryBlocked("user_takeover")


async def _eval(bridge: object, tab_id: object, expression: str):
    raw = await bridge.call(tab_id, "Runtime.evaluate", {"expression": expression, "returnByValue": True})
    if not isinstance(raw, dict):
        return None
    result = raw.get("result")
    if not isinstance(result, dict) or "value" not in result:
        return None
    return result.get("value")


def _payload(item_url: str, data: dict, title: object, expanded: bool, status_id: str) -> dict:
    text = data.get("text") if isinstance(data.get("text"), str) else ""
    author = data.get("author") if isinstance(data.get("author"), str) and data.get("author") else None
    published = (
        data.get("published_at") if isinstance(data.get("published_at"), str) and data.get("published_at") else None
    )
    show_n = int(data.get("show_more_n") or 0)
    return {
        "url": item_url,
        "text": text,
        "title": title if isinstance(title, str) and title.strip() else None,
        "author": author,
        "published_at": published,
        "truncated": bool(data.get("capped") or show_n > 0),
        "captured_at": time.time(),
        "recovery": {"method": "detail_tab", "status_id": status_id, "expanded": expanded},
    }


async def _cleanup(bridge, owned, status_id, feed_tab_id, feed_url, stopped, loaded, background=False) -> None:
    if background:
        tab = _tab(bridge, owned) if owned is not None else None
        if (
            tab
            and not _stopped(stopped)
            and bridge.active_tab_id != owned
            and _url_has_status(tab.get("url"), status_id)
        ):
            await bridge.call(owned, "Browser.closeTab", {})
        return
    if owned is None or _stopped(stopped) or bridge.active_tab_id != owned:
        return
    tab = _tab(bridge, owned)
    if tab is None:
        return
    url = tab.get("url") or ""
    blank = url in ("", "about:blank")
    if not (_url_has_status(url, status_id) or (blank and not loaded)):
        return
    feed = _tab(bridge, feed_tab_id)
    if feed is not None and (feed.get("url") or "") == feed_url and bridge.active_tab_id == owned:
        await bridge.call(feed_tab_id, "Browser.selectTab", {})
        for _ in range(10):
            if _stopped(stopped) or bridge.active_tab_id not in {feed_tab_id, owned}:
                return
            if bridge.active_tab_id == feed_tab_id:
                break
            await asyncio.sleep(_POLL_S)
        if not _stopped(stopped) and bridge.active_tab_id == feed_tab_id and _tab(bridge, owned) is not None:
            await bridge.call(owned, "Browser.closeTab", {})


async def recover_post(bridge, item, feed_tab_id, stopped):
    if _stopped(stopped):
        raise RecoveryBlocked("stopped")
    item_url = _field(item, "url")
    status_id = _parse_status(item_url)
    if status_id is None:
        raise RecoveryBlocked("invalid_url")
    original = _field(item, "text")
    original_text = original if isinstance(original, str) else ""
    original_truncated = bool(_field(item, "truncated"))
    feed_url = _feed_url(bridge, feed_tab_id)
    background = getattr(bridge, "supports_background", False)
    lease_owner = "recovery:" + uuid.uuid4().hex
    if not background and bridge.active_tab_id != feed_tab_id:
        raise RecoveryBlocked("inactive_feed")
    if _stopped(stopped):
        raise RecoveryBlocked("stopped")
    owned = None
    loaded = False
    expanded = False
    opened_at = 0.0
    try:
        if _feed_url(bridge, feed_tab_id) != feed_url:
            raise RecoveryBlocked("feed_changed")
        opened = await bridge.call(feed_tab_id, "Browser.openTab", {"url": item_url, "background": background})
        owned = opened.get("tab_id") if isinstance(opened, dict) else None
        if owned is None:
            raise RecoveryBlocked("tab_lost")
        if background:
            bridge.claim_tab(owned, lease_owner)
        opened_at = time.monotonic()
        deadline = opened_at + _LOAD_S
        expand_until = None
        clicked = False
        last = None
        while True:
            now = time.monotonic()
            limit = deadline if expand_until is None else max(deadline, expand_until)
            if now >= limit:
                break
            if _stopped(stopped):
                raise RecoveryBlocked("stopped")
            if _feed_url(bridge, feed_tab_id) != feed_url:
                raise RecoveryBlocked("feed_changed")
            if background and bridge.tab_owner(owned) != lease_owner:
                raise RecoveryBlocked("ownership_changed")
            if _owned_state(bridge, owned, feed_tab_id, opened_at, background) == "settle":
                await asyncio.sleep(_POLL_S)
                continue
            meta = _tab(bridge, owned)
            if meta is None:
                raise RecoveryBlocked("tab_lost")
            if (meta.get("url") or "") not in ("", "about:blank"):
                loaded = True
            data = await _eval(bridge, owned, _js_call(READ_POST, {"url": item_url, "statusId": status_id}))
            if not isinstance(data, dict):
                await asyncio.sleep(_POLL_S)
                continue
            state = data.get("state")
            if state == "blocked":
                reason = data.get("reason")
                raise RecoveryBlocked(reason if reason in _BLOCKED else "missing_target")
            if state != "ready" or data.get("status_id") != status_id or not isinstance(data.get("text"), str):
                await asyncio.sleep(_POLL_S)
                continue
            last = data
            grew = int(data.get("n") or 0) > len(original_text)
            show_n = int(data.get("show_more_n") or 0)
            if show_n == 1 and not clicked:
                if _stopped(stopped):
                    raise RecoveryBlocked("stopped")
                if _feed_url(bridge, feed_tab_id) != feed_url:
                    raise RecoveryBlocked("feed_changed")
                if _owned_state(bridge, owned, feed_tab_id, opened_at, background) != "ok":
                    await asyncio.sleep(_POLL_S)
                    continue
                guard = {
                    "statusId": status_id,
                    "timeOrigin": data.get("time_origin"),
                    "location": data.get("location"),
                    "oldText": data.get("text"),
                    "n": data.get("n"),
                }
                clicked = True
                result = await _eval(bridge, owned, _js_call(EXPAND_POST, guard))
                if isinstance(result, dict) and result.get("ok") is True:
                    expanded = True
                    expand_until = time.monotonic() + _EXPAND_S
                await asyncio.sleep(_POLL_S)
                continue
            show = show_n > 0
            mature = (not original_truncated) or grew
            if show and expand_until is not None and time.monotonic() < expand_until:
                await asyncio.sleep(_POLL_S)
                continue
            if mature and not show and data["text"].strip():
                meta = _tab(bridge, owned)
                title = meta.get("title") if meta else None
                return _payload(item_url, data, title, expanded, status_id)
            await asyncio.sleep(_POLL_S)
        if last is not None:
            grew = int(last.get("n") or 0) > len(original_text)
            show_n = int(last.get("show_more_n") or 0)
            if last.get("status_id") == status_id and ((not original_truncated) or grew):
                if not (show_n > 0 and not clicked and show_n == 1):
                    meta = _tab(bridge, owned)
                    title = meta.get("title") if meta else None
                    return _payload(item_url, last, title, expanded, status_id)
        raise RecoveryBlocked("timeout")
    finally:
        try:
            if not background or (owned and bridge.tab_owner(owned) == lease_owner):
                await _cleanup(bridge, owned, status_id, feed_tab_id, feed_url, stopped, loaded, background)
        finally:
            if background and owned:
                bridge.release_tab(owned, lease_owner)
