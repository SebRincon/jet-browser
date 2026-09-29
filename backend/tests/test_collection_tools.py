import asyncio
import csv
import io

import pytest
from aiohttp import ClientSession
from aiohttp.test_utils import TestServer
from test_collection_runner import ROOT, Collector, classify

from jet_browser import collection_tools
from jet_browser.routing import LocalRouter
from jet_browser.service import PORT, Service, create_app

ARGS = {
    "request": "Collect this site",
    "title": "Site collection",
    "categories": [{"id": "docs", "name": "Docs", "description": "Technical guides"}],
    "model": "qwen4b_semif_shared",
}


def service_at(tmp_path):
    s = Service(tmp_path)
    s.bridge.sync({"host_id": "host", "active_tab_id": "tab", "tabs": [{"id": "tab", "url": ROOT, "title": "Example"}]})
    s.bridge.current = ROOT
    s.bridge.reads = []
    s.bridge.navigations = []
    s.bridge.graph = {ROOT: ["a"], ROOT + "a": []}
    s.collections.classifier = classify
    s.collections.collector_factory = Collector
    s.turn_id = "test-turn"
    return s


async def test_prepare_uses_observed_seed_and_fixed_schema(tmp_path):
    s = service_at(tmp_path)
    for extra in [
        {"start_url": "https://evil.test"},
        {"tab_id": "invented"},
        {"max_pages": 51},
        {"max_seconds": 121},
        {"model": "made_up"},
    ]:
        with pytest.raises(ValueError):
            await s.tool("prepare_collection", {**ARGS, **extra})
    assert not s.bridge.pending and s.collections.summaries(s.store.current_id) == []
    out = await s.tool("prepare_collection", ARGS)
    run = s.collection_store.get(s.store.current_id, out["id"])
    assert run["plan"]["start_url"] == ROOT and run["plan"]["model"] == "qwen4b_semif_shared"
    assert run["turn_id"] == "test-turn" and out["status"] == "prepared"
    assert "checkpoint" not in out and "plan" not in out


async def test_mcp_full_loop_summary_only_and_ownership(tmp_path):
    s = service_at(tmp_path)
    out = await s.tool("prepare_collection", ARGS)
    rid = out["id"]
    started = await s.tool("start_collection", {"collection_id": rid, "wait_seconds": 0})
    assert started["status"] == "running" and s.busy
    for name, args in [("read_page", {}), ("open_url", {"url": ROOT}), ("run_task", {"goal": "Click something"})]:
        with pytest.raises(ValueError, match="collection owns"):
            await s.tool(name, args)
    out = await s.tool("collection_status", {"collection_id": rid, "wait_seconds": 5})
    assert out["status"] == "completed" and out["counters"]["pages"] == 2
    assert "Documentation" not in str(out) and "checkpoint" not in out and "items" not in out
    assert not s.busy


async def test_http_auth_scope_export_and_no_cross_session_leak(tmp_path):
    s = service_at(tmp_path)
    r = await s.tool("prepare_collection", ARGS)
    rid = r["id"]
    await s.tool("start_collection", {"collection_id": rid, "wait_seconds": 5})
    async with TestServer(create_app(s)) as server, ClientSession() as client:
        host = {"Host": f"127.0.0.1:{PORT}"}
        auth = {**host, "Authorization": "Bearer " + s.token}
        url = server.make_url("/collections/" + rid)
        assert (await client.get(url, headers=host)).status == 401
        response = await client.get(url, headers=auth)
        payload = await response.json()
        assert (
            response.status == 200
            and payload["total"] == 2
            and payload["items"][0]["classification"]["label_id"] == "docs"
        )
        assert payload["collection"]["plan"]["model"] == "qwen4b_semif_shared"
        assert s.token not in str(payload)
        for fmt in ["csv", "markdown"]:
            response = await client.get(server.make_url(f"/collections/{rid}/export?format={fmt}"), headers=auth)
            export = await response.json()
            assert response.status == 200 and "Docs" in export["content"] and "Documentation" in export["content"]
        assert (await client.get(server.make_url(f"/collections/{rid}?limit=51"), headers=auth)).status == 400
        await client.post(server.make_url("/sessions"), headers=auth, json={})
        assert (await client.get(url, headers=auth)).status == 400
        assert (await client.get(server.make_url(f"/collections/{rid}/export?format=csv"), headers=auth)).status == 400
        assert (
            await client.post(server.make_url(f"/collections/{rid}/control"), headers=auth, json={"action": "stop"})
        ).status == 400


async def test_manual_start_during_chat_is_rejected_stop_remains_available(tmp_path):
    s = service_at(tmp_path)
    r = await s.tool("prepare_collection", ARGS)
    rid = r["id"]
    async with TestServer(create_app(s)) as server, ClientSession() as client:
        auth = {"Host": f"127.0.0.1:{PORT}", "Authorization": "Bearer " + s.token}
        s.chat_job = asyncio.create_task(asyncio.sleep(30))
        response = await client.post(
            server.make_url(f"/collections/{rid}/control"), headers=auth, json={"action": "start"}
        )
        assert response.status == 400
        response = await client.post(
            server.make_url(f"/collections/{rid}/control"), headers=auth, json={"action": "stop"}
        )
        assert response.status == 200 and (await response.json())["collection"]["status"] == "cancelled"
        s.chat_job.cancel()
        with pytest.raises(asyncio.CancelledError):
            await s.chat_job


def test_export_untrusted_text_keeps_real_category_and_escapes_formula_and_html():
    record = {"plan": {"categories": ARGS["categories"]}, "status": "partial", "reason": "page_budget"}
    item = {
        "url": ROOT,
        "text": '=HYPERLINK("evil")\n<script>alert(1)</script>',
        "classification": {"label_id": "docs"},
    }
    csv_text = collection_tools._csv_document(record, [item])
    rows = list(csv.reader(io.StringIO(csv_text)))
    assert rows[-1][0] == "Docs" and rows[-1][2].startswith("'=")
    assert collection_tools.neutralize_cell("") == ""
    md = collection_tools._markdown_document(record, [item])
    assert "<script>" not in md and "&lt;script&gt;" in md
    assert "page_budget" in csv_text


def test_collection_route_uses_planner_but_homepage_still_local():
    class Router(LocalRouter):
        def choose(self, *args, **kwargs):
            return "collect", {"answer": "collect"}

    r = Router()
    assert r.route("Categorize this website", "qwen4b_semif_shared", {})["decision"] == "grok"
    assert r.route("Open YouTube", "qwen4b_semif_shared", {})["decision"] == "local"
