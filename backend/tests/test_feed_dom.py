"""Real Chromium DOM contract checks; all document requests are fulfilled locally."""

import asyncio
import base64
import os
import subprocess
import threading

import aiohttp
import pytest

from jet_browser.collection_plan import CollectionPlan
from jet_browser.feed_collection import FeedCollector
from jet_browser.site_collection import CollectionBlocked

HTML = """<!doctype html><style>body {margin:0} #feed {height:400px;overflow-y:scroll} article {height:310px} aside {height:500px}</style>
<nav>Never classify this navigation</nav><main><div role="tablist">
<a role="tab" aria-selected="true" href="/i/history">Bookmarks</a>
<a role="tab" aria-selected="false" href="/i/history/likes">Likes</a></div>
<section id="feed">
<article data-testid="tweet"><div data-testid="User-Name">Example Author</div>
<a href="/demo/status/101"><time>Today</time></a><div data-testid="tweetText">Software release notes</div>
<button>91 Likes</button></article>
<article data-testid="tweet"><a href="/demo/status/102"><time>Yesterday</time></a>
<div data-testid="tweetText">An article about science</div>
<div role="blockquote"><a href="/quote/status/999"><time>Quoted</time></a><div data-testid="tweetText">Quoted research</div></div></article>
</section></main><aside><article><a href="/ads/status/900"><time>Ad</time></a><div data-testid="tweetText">Sidebar spam</div></article></aside>
<script>let appended=false;feed.addEventListener('scroll',()=>{if(!appended){appended=true;setTimeout(()=>{let e=document.createElement('article');e.dataset.testid='tweet';e.innerHTML='<a href="/demo/status/103"><time>Older</time></a><div data-testid="tweetText">Newly loaded programming tutorial</div>';feed.append(e)},300)}})</script>"""


class Browser:
    active_tab_id = "tab"
    host_id = "fixture"

    def __init__(self, ws):
        self.ws, self.seq = ws, 0
        self.html = HTML
        self.calls = []

    def tab(self, value):
        return value

    async def call(self, tab, method, params=None):
        self.calls.append(method)
        self.seq += 1
        ident = self.seq
        await self.ws.send_json(dict(id=ident, method=method, params=params or {}))
        while True:
            msg = await self.ws.receive_json(timeout=10)
            if msg.get("method") == "Fetch.requestPaused":
                self.seq += 1
                await self.ws.send_json(
                    dict(
                        id=self.seq,
                        method="Fetch.fulfillRequest",
                        params=dict(
                            requestId=msg["params"]["requestId"],
                            responseCode=200,
                            responseHeaders=[dict(name="Content-Type", value="text/html")],
                            body=base64.b64encode(self.html.encode()).decode(),
                        ),
                    )
                )
            if msg.get("id") == ident:
                if "error" in msg:
                    raise RuntimeError(msg["error"])
                return msg.get("result", {})

    async def js(self, expression):
        r = await self.call("tab", "Runtime.evaluate", dict(expression=expression, returnByValue=True))
        assert not r.get("exceptionDetails"), r
        return r["result"].get("value")

    async def navigate(self, url):
        await self.call("tab", "Page.navigate", {"url": url})
        for _ in range(50):
            await asyncio.sleep(0.05)
            if await self.js('document.readyState === "complete" && !!document.querySelector("article")'):
                return
        raise AssertionError("Fixture failed to load")


@pytest.fixture
async def browser(tmp_path):
    executable = os.getenv("JET_TEST_CHROMIUM")
    if not executable:
        pytest.skip("Set JET_TEST_CHROMIUM for isolated real-DOM checks")
    profile = tmp_path / "chromium"
    p = subprocess.Popen(
        [
            executable,
            "--headless",
            "--remote-debugging-port=0",
            "--user-data-dir=" + str(profile),
            "--no-first-run",
            "--disable-background-networking",
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        portfile = profile / "DevToolsActivePort"
        for _ in range(100):
            if portfile.exists():
                break
            await asyncio.sleep(0.05)
        port = portfile.read_text().splitlines()[0]
        async with aiohttp.ClientSession() as client:
            async with client.get(f"http://127.0.0.1:{port}/json") as response:
                pages = await response.json()
            async with client.ws_connect(pages[0]["webSocketDebuggerUrl"]) as ws:
                b = Browser(ws)
                await b.call("tab", "Fetch.enable", {"patterns": [{"urlPattern": "*"}]})
                await b.navigate("https://x.com/i/history")
                yield b
    finally:
        p.terminate()
        await asyncio.to_thread(p.wait, 10)


def plan(url="https://x.com/i/history", kind="x_bookmarks"):
    return CollectionPlan.from_request(
        dict(
            request="Categorize bookmarks",
            title="Bookmarks",
            source_kind=kind,
            categories=[dict(id="tech", name="Tech", description="Technology")],
        ),
        start_url=url,
        tab_id="tab",
        model="lfm_rlcd",
    )


async def test_real_dom_extracts_posts_not_navigation_or_sidebar(browser):
    c = FeedCollector(browser, plan(), threading.Event())
    snap = await c.read()
    assert snap["source_kind"] == "x_bookmarks"
    assert [i["url"] for i in snap["items"]] == ["https://x.com/demo/status/101", "https://x.com/demo/status/102"]
    assert "91 Likes" not in snap["items"][0]["text"]
    assert "Quoted research" in snap["items"][1]["text"]
    assert snap["scroll"]["viewport"] == 400
    after = await c.scroll(snap)
    assert after["scroll"]["top"] > 0
    assert any(i["url"].endswith("/103") for i in after["items"])
    assert not after["end_of_feed"]


async def test_likes_and_fake_bookmarks_heading_rejected(browser):
    await browser.js(
        'document.querySelectorAll("[role=tab]").forEach(t=>t.setAttribute("aria-selected",String(t.textContent==="Likes")));document.querySelector("main").insertAdjacentHTML("afterbegin","<h1>Bookmarks</h1>")'
    )
    with pytest.raises(CollectionBlocked):
        await FeedCollector(browser, plan(), threading.Event()).read()


async def test_missing_selection_rejected_for_history(browser):
    await browser.js('document.querySelectorAll("[role=tab]").forEach(t=>t.removeAttribute("aria-selected"))')
    with pytest.raises(CollectionBlocked):
        await FeedCollector(browser, plan(), threading.Event()).read()


async def test_user_scroll_between_observation_and_dispatch_fenced(browser):
    c = FeedCollector(browser, plan(), threading.Event())
    snap = await c.read()
    await browser.js('document.querySelector("#feed").scrollTop=50')
    with pytest.raises(CollectionBlocked):
        await c.scroll(snap)
    assert await browser.js('document.querySelector("#feed").scrollTop') == 50


async def test_same_url_new_document_fenced(browser):
    c = FeedCollector(browser, plan(), threading.Event())
    snap = await c.read()
    await browser.navigate("https://x.com/i/history")
    with pytest.raises(CollectionBlocked):
        await c.scroll(snap)


async def test_generic_articles_use_stable_links(browser):
    browser.html = HTML.replace('href="/demo/status/', 'rel="bookmark" href="/posts/').replace(
        'href="/quote/status/', 'href="/quoted/'
    )
    await browser.navigate("https://example.test/feed")
    c = FeedCollector(browser, plan("https://example.test/feed", "feed"), threading.Event())
    snap = await c.read()
    assert len(snap["items"]) == 2
    assert all(i["url"].startswith("https://example.test/posts/") for i in snap["items"])


async def test_login_gate_and_stop(browser):
    await browser.js('document.body.insertAdjacentHTML("afterbegin", "<input type=password>")')
    with pytest.raises(CollectionBlocked, match="login_required"):
        await FeedCollector(browser, plan(), threading.Event()).read()
    event = threading.Event()
    event.set()
    n = len(browser.calls)
    with pytest.raises(asyncio.CancelledError):
        await FeedCollector(browser, plan(), event).read()
    assert len(browser.calls) == n


async def test_collapsed_long_post_and_generic_media_alt_are_not_full_evidence(browser):
    await browser.js(
        "document.querySelector('[data-testid=tweetText]').textContent='';document.querySelector('article').insertAdjacentHTML('beforeend', '<button data-testid=tweet-text-show-more-link>Show more</button><img alt=Image width=40 height=40>')"
    )
    c = FeedCollector(browser, plan(), threading.Event())
    snap = await c.read()
    assert snap["items"][0]["truncated"] is True
    assert snap["items"][0]["text"] == ""


async def test_large_nonvirtualized_feed_does_not_keep_reading_first_100_posts(browser):
    await browser.js(
        "document.querySelector('#feed').innerHTML=Array.from({length:180},(_,i)=>'<article><a href=/demo/status/'+(1000+i)+'><time>Today</time></a><div data-testid=tweetText>Post '+i+'</div></article>').join('');document.querySelector('#feed').scrollTop=40000"
    )
    c = FeedCollector(browser, plan(), threading.Event())
    snap = await c.read()
    assert any(int(i["url"].rsplit("/", 1)[1]) > 1100 for i in snap["items"])
    assert len(snap["items"]) < 20


async def test_long_job_uses_real_dom_for_more_than_six_scrolls(browser, tmp_path):
    from dataclasses import replace

    from test_feed_loop import classify

    from jet_browser.collection_runner import CollectionManager
    from jet_browser.collection_store import CollectionStore

    await browser.js(
        "document.querySelector('#feed').innerHTML=Array.from({length:40},(_,i)=>'<article><a href=/demo/status/'+(2000+i)+'><time>Today</time></a><div data-testid=tweetText>Software release '+i+'</div></article>').join('')"
    )
    store = CollectionStore(tmp_path)
    checks = []

    def reviewer(p, snapshot, *, stopped):
        checks.append(snapshot["scrolls"])
        assert "items" not in snapshot
        return {"action": "continue_scroll", "model": "fixture@review", "reason": None}

    manager = CollectionManager(store, browser, classifier=classify, reviewer=reviewer)
    record = store.create("s", "t", replace(plan(), max_scrolls=14, max_seconds=30))
    await manager.start("s", record["id"])
    result = await manager.wait("s", record["id"], 10)
    assert result["status"] == "paused" and result["reason"] == "scroll_budget"
    assert result["progress"]["scrolls"] == 14
    assert result["counters"]["pages"] >= 13
    assert 0 in checks and 10 in checks
    assert len(store.seen_urls("s", record["id"])) == result["counters"]["pages"]
    store.close()


async def test_status_extraction_is_bounded_and_does_not_capture_posts(browser):
    await browser.js(
        "document.querySelector('main').insertAdjacentHTML('beforeend','<div role=alert>Rate limit exceeded</div><div data-testid=emptyState>Try later</div>');document.body.insertAdjacentHTML('beforeend','<div id=cookie-banner role=alert>Cookie consent</div>')"
    )
    result = await FeedCollector(browser, plan(), threading.Event()).read()
    assert "Rate limit exceeded" in result["status_text"]
    assert "Try later" in result["status_text"]
    assert "Software release" not in result["status_text"]
    assert "Cookie" not in result["status_text"]
    assert len(result["status_text"]) <= 600


async def test_observed_author_date_and_quotes_stay_separate(browser):
    await browser.js(
        "document.querySelector('article time').setAttribute('datetime','2026-09-28T12:00:00Z');document.querySelector('[role=blockquote] time').setAttribute('datetime','2020-01-01T00:00:00Z')"
    )
    result = await FeedCollector(browser, plan(), threading.Event()).read()
    first, second = result["items"]
    assert first["author"] == "Example Author"
    assert first["published_at"] == "2026-09-28T12:00:00Z"
    assert second["author"] is None and second["published_at"] is None
    await browser.js("document.querySelector('article time').setAttribute('datetime','invented')")
    result = await FeedCollector(browser, plan(), threading.Event()).read()
    assert result["items"][0]["published_at"] is None


async def test_real_dom_supervision_stops_after_ten_and_preserves_metadata(browser, tmp_path):
    from test_feed_loop import classify

    from jet_browser.collection_runner import CollectionManager
    from jet_browser.collection_store import CollectionStore

    await browser.js(
        "document.querySelector('#feed').innerHTML=Array.from({length:30},(_,i)=>'<article><span data-testid=User-Name>Fixture Author</span><a href=/demo/status/'+(4000+i)+'><time datetime=2026-09-28T12:00:00Z>Today</time></a><div data-testid=tweetText>Software release '+i+'</div></article>').join('')"
    )
    store = CollectionStore(tmp_path)
    manager = CollectionManager(
        store,
        browser,
        classifier=classify,
        reviewer=lambda *a, **k: {"action": "continue_scroll", "model": "fixture", "reason": None},
    )
    run = store.create("s", "t", plan())
    rid = run["id"]
    manager.supervision.configure("s", rid, {"share_samples": True})
    await manager.start("s", rid)
    result = await manager.wait("s", rid, 10)
    assert result["reason"] == "supervisor_review" and result["counters"]["pages"] == 10
    assert result["review"]["coverage"]["author"] == 10
    assert result["review"]["coverage"]["published_at"] == 10
    assert len(result["review"]["samples"]) == 5
    store.close()


async def test_owned_feed_continues_when_another_tab_is_active(browser):
    browser.supports_background = True
    owners = {"tab": "collection-test"}
    browser.tab_owner = lambda tab: owners.get(tab)
    await browser.call("tab", "Target.createTarget", {"url":"about:blank"})
    browser.active_tab_id = "user-tab"
    collector = FeedCollector(browser, plan(), threading.Event())
    snapshot = await collector.read()
    assert len(snapshot["items"]) == 2
    after = await collector.scroll(snapshot)
    assert after["scroll"]["top"] > 0
    assert browser.active_tab_id == "user-tab"
    owners.clear()
    with pytest.raises(CollectionBlocked):
        await collector.read()
