import asyncio
import threading

import pytest

from jet_browser.collection_plan import CollectionPlan
from jet_browser.site_collection import SNAPSHOT, CollectionBlocked, SiteCollector


def plan():
    return CollectionPlan.from_request(
        {
            "request": "Collect site",
            "title": "Site",
            "categories": [{"id": "docs", "name": "Docs", "description": "Technical documentation"}],
        },
        start_url="https://example.test/",
        tab_id="tab",
        model="lfm_rlcd",
    )


def page(url="https://example.test/", doc="1", **extra):
    return {
        "url": url,
        "title": "Title",
        "text": "Text",
        "text_truncated": False,
        "links_truncated": False,
        "login_required": False,
        "ready_state": "complete",
        "document_id": doc,
        "links": ["https://example.test/a?q=A#x", "https://evil.test/"],
        **extra,
    }


class Bridge:
    host_id = "host"
    active_tab_id = "tab"

    def __init__(self):
        self.current = page()
        self.calls = []
        self.redirect = None

    def tab(self, tab_id):
        return tab_id

    async def call(self, tab, method, params):
        self.calls.append((tab, method, params))
        if method == "Page.navigate":
            self.current = page(self.redirect or params["url"], "2")
            return {}
        return {"result": {"value": self.current}}


@pytest.mark.asyncio
async def test_reads_real_bridge_contract_and_navigates_exactly_once():
    b = Bridge()
    c = SiteCollector(b, plan(), threading.Event())
    one = await c.read("https://example.test/")
    assert one["links"] == ["https://example.test/a?q=A"]
    two = await c.read("https://example.test/a?q=A")
    assert two["url"] == "https://example.test/a?q=A"
    assert [v[1] for v in b.calls].count("Page.navigate") == 1
    assert all(v[2]["expression"] == SNAPSHOT for v in b.calls if v[1] == "Runtime.evaluate")


@pytest.mark.asyncio
async def test_scope_change_takeover_and_pending_resume_do_not_dispatch():
    b = Bridge()
    c = SiteCollector(b, plan(), threading.Event())
    with pytest.raises(CollectionBlocked):
        await c.read("https://evil.test/")
    assert not b.calls
    with pytest.raises(CollectionBlocked):
        await c.read("https://example.test/a", navigate=False)
    assert not any(m == "Page.navigate" for _, m, _ in b.calls)
    b.active_tab_id = "other"
    with pytest.raises(CollectionBlocked):
        await c.read("https://example.test/")


@pytest.mark.asyncio
async def test_stop_redirect_and_capture_limits():
    b = Bridge()
    stop = threading.Event()
    c = SiteCollector(b, plan(), stop)
    stop.set()
    with pytest.raises(asyncio.CancelledError):
        await c.read("https://example.test/")
    assert not b.calls
    stop.clear()
    b.redirect = "https://evil.test/"
    with pytest.raises(CollectionBlocked):
        await c.read("https://example.test/a")
    assert [m for _, m, _ in b.calls].count("Page.navigate") == 1
    b.current = page(title="t" * 501, text="x" * 20001)
    b.redirect = None
    c = SiteCollector(b, plan(), stop)
    r = await c.read("https://example.test/")
    assert r["truncated"] and len(r["title"]) <= 500 and len(r["text"]) == 20000
