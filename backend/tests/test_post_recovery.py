import json

import pytest
from test_feed_dom import browser as browser_fixture

from jet_browser.post_recovery import EXPAND_POST, READ_POST


@pytest.fixture
async def browser(tmp_path):
    async for opened in browser_fixture.__wrapped__(tmp_path):
        yield opened


async def test_recovers_exact_post_not_reply_or_quote(browser):
    browser.html = """<main><article><div data-testid="User-Name">Main author</div>
<a href="/demo/status/101"><time datetime="2026-09-28T12:00:00Z">now</time></a>
<div data-testid="tweetText">Full main post</div>
<div role="blockquote"><div data-testid="User-Name">Wrong quote author</div><a href="/quote/status/999"><time datetime="2020-01-01">quote</time></a><div data-testid="tweetText">Quoted evidence</div></div>
</article><article><a href="/reply/status/222"><time>reply</time></a><div data-testid="tweetText">Wrong reply</div></article></main>"""
    await browser.navigate("https://x.com/demo/status/101")
    data = await browser.js(f"({READ_POST})({json.dumps({'statusId': '101'})})")
    assert data["text"].startswith("Full main post")
    assert "Wrong reply" not in data["text"]
    assert data["author"] == "Main author"
    assert data["published_at"] == "2026-09-28T12:00:00Z"


async def test_expansion_is_exact_and_stale_text_does_not_click(browser):
    browser.html = """<main><article><a href="/demo/status/101"><time>now</time></a><div data-testid="tweetText">Short text</div>
<button data-testid="tweet-text-show-more-link" onclick="window.clicks=(window.clicks||0)+1;this.previousElementSibling.textContent='Complete text now visible';this.remove()">Show more</button>
</article></main>"""
    await browser.navigate("https://x.com/demo/status/101")
    data = await browser.js(f"({READ_POST})({json.dumps({'statusId': '101'})})")
    guard = {
        "statusId": "101",
        "timeOrigin": data["time_origin"],
        "location": data["location"],
        "oldText": "stale",
        "n": data["n"],
    }
    value = await browser.js(f"({EXPAND_POST})({json.dumps(guard)})")
    assert not value["ok"]
    assert not await browser.js("window.clicks || 0")
    guard = {
        "statusId": "101",
        "timeOrigin": data["time_origin"],
        "location": data["location"],
        "oldText": data["text"],
        "n": data["n"],
    }
    value = await browser.js(f"({EXPAND_POST})({json.dumps(guard)})")
    assert value["ok"]
    assert await browser.js("window.clicks") == 1
    again = await browser.js(f"({EXPAND_POST})({json.dumps(guard)})")
    assert not again["ok"]
    assert await browser.js("window.clicks") == 1


async def test_temporary_tab_is_closed_and_feed_restored():
    import threading

    from jet_browser.post_recovery import recover_post

    class Bridge:
        active_tab_id = "feed"
        tabs = [{"id": "feed", "url": "https://x.com/i/history"}]

        def tab(self, tid):
            if any(t["id"] == tid for t in self.tabs):
                return tid
            raise ValueError("gone")

        async def call(self, tid, method, params=None):
            if method == "Browser.openTab":
                self.tabs.append({"id": "owned", "url": params["url"], "title": "Post"})
                self.active_tab_id = "owned"
                return {"tab_id": "owned"}
            if method == "Runtime.evaluate":
                return {
                    "result": {
                        "value": {
                            "state": "ready",
                            "status_id": "101",
                            "text": "Full post body recovered",
                            "n": 24,
                            "author": "Author",
                            "published_at": None,
                            "show_more_n": 0,
                            "capped": False,
                        }
                    }
                }
            if method == "Browser.selectTab":
                self.active_tab_id = tid
                return {}
            if method == "Browser.closeTab":
                self.tabs = [t for t in self.tabs if t["id"] != tid]
                return {}
            raise AssertionError(method)

    b = Bridge()
    got = await recover_post(
        b, {"url": "https://x.com/demo/status/101", "text": "Short", "truncated": True}, "feed", threading.Event()
    )
    assert got["text"] == "Full post body recovered"
    assert b.active_tab_id == "feed" and len(b.tabs) == 1


async def test_stop_during_read_prevents_cleanup_mutations():
    import threading

    import pytest

    from jet_browser.post_recovery import RecoveryBlocked, recover_post

    flag = threading.Event()

    class Bridge:
        active_tab_id = "feed"
        tabs = [{"id": "feed", "url": "https://x.com/i/history"}]
        calls = []

        def tab(self, tid):
            return tid

        async def call(self, tid, method, params=None):
            self.calls.append(method)
            if method == "Browser.openTab":
                self.tabs.append({"id": "owned", "url": params["url"]})
                self.active_tab_id = "owned"
                return {"tab_id": "owned"}
            if method == "Runtime.evaluate":
                flag.set()
                return {"result": {"value": {"state": "loading"}}}
            raise AssertionError("Mutation after stop")

    b = Bridge()
    with pytest.raises(RecoveryBlocked, match="stopped"):
        await recover_post(
            b, {"url": "https://x.com/demo/status/101", "text": "Short", "truncated": True}, "feed", flag
        )
    assert b.calls == ["Browser.openTab", "Runtime.evaluate"]


@pytest.mark.parametrize("selected_detail", [False, True])
async def test_background_recovery_preserves_foreground_and_releases_lease(selected_detail):
    import threading

    from jet_browser.post_recovery import recover_post

    class Bridge:
        supports_background = True
        active_tab_id = "user"

        def __init__(self):
            self.tabs = [{"id": "feed", "url": "https://x.com/i/history"},
                         {"id": "user", "url": "https://example.com/"}]
            self.owners = {}
            self.calls = []

        def tab(self, tid):
            return tid if any(t["id"] == tid for t in self.tabs) else None

        def claim_tab(self, tid, owner):
            self.owners[tid] = owner

        def tab_owner(self, tid):
            return self.owners.get(tid)

        def release_tab(self, tid, owner):
            if self.owners.get(tid) == owner:
                del self.owners[tid]

        async def call(self, tid, method, params=None):
            self.calls.append((tid, method))
            if method == "Browser.openTab":
                assert params["background"] is True
                self.tabs.append({"id": "detail", "url": params["url"]})
                return {"tab_id": "detail"}
            if method == "Runtime.evaluate":
                assert tid == "detail" and self.tab_owner(tid)
                if selected_detail:
                    self.active_tab_id = "detail"
                return {"result": {"value": {"state": "ready", "status_id": "101",
                    "text": "Complete post evidence", "n": 22, "show_more_n": 0}}}
            if method == "Browser.closeTab":
                assert tid == "detail" and self.active_tab_id != tid
                self.tabs = [t for t in self.tabs if t["id"] != tid]
                return {}
            raise AssertionError(method)

    bridge = Bridge()
    result = await recover_post(bridge, {"url": "https://x.com/demo/status/101",
        "text": "Short", "truncated": True}, "feed", threading.Event())
    assert result["text"] == "Complete post evidence"
    assert bridge.active_tab_id == ("detail" if selected_detail else "user")
    assert not bridge.owners
    assert bool(bridge.tab("detail")) == selected_detail
    assert not any(method == "Browser.selectTab" for _, method in bridge.calls)
