"""Built-in workflow templates: validation, tool contract and real JavaScriptCore runs."""

import asyncio
from pathlib import Path
from types import SimpleNamespace

import pytest
from test_workflow_capabilities import URL, Bridge, Worker, definition

from jet_browser import workflow_templates, workflow_tools
from jet_browser.post_recovery import RecoveryBlocked
from jet_browser.workflow_capabilities import WorkflowCapabilities
from jet_browser.workflow_manager import WorkflowManager
from jet_browser.workflow_runtime import run_script
from jet_browser.workflow_store import WorkflowStore

EXECUTABLE = Path(__file__).resolve().parents[2] / ".runtime/bin/jet-workflow"
LIMITS = {"max_seconds": 600, "max_calls": 2000, "max_items": 25}


def template_definition(options=None, max_items=25, source_kind="x_bookmarks"):
    raw = definition()
    raw.pop("source")
    raw.pop("capabilities")
    raw["source_kind"] = source_kind
    raw["limits"] = dict(LIMITS, max_items=max_items)
    raw["template"] = {"name": "tagged_feed", "options": options or {}}
    return raw


def test_render_validates_options_and_limits_recovery_to_bookmarks():
    source, caps = workflow_templates.render({"name": "tagged_feed"}, "x_bookmarks", LIMITS)
    assert '"max_items": 25' in source and '"first_review": 10' in source
    assert "post.recover" in caps and "records.patch" not in caps
    source, caps = workflow_templates.render(
        {"name": "tagged_feed", "options": {"recover_truncated": True}}, "feed", LIMITS)
    assert '"recover_truncated": false' in source and "post.recover" not in caps
    for bad, message in (
        ({"name": "invented"}, "unknown template"),
        ({"name": "tagged_feed", "options": {"review_every": -1}}, "review_every"),
        ({"name": "tagged_feed", "options": {"summarize": 1}}, "summarize"),
        ({"name": "tagged_feed", "options": {"source": "x"}}, "unknown template option"),
        ({"name": "tagged_feed", "extra": 1}, "unknown field"),
    ):
        with pytest.raises(ValueError, match=message):
            workflow_templates.render(bad, "x_bookmarks", LIMITS)
    assert len(source.encode()) < 16000
    catalog = workflow_templates.catalog()
    assert catalog[0]["name"] == "tagged_feed" and "body" not in catalog[0]


async def test_save_workflow_accepts_a_small_template_call(tmp_path):
    store = WorkflowStore(tmp_path)
    service = SimpleNamespace(store=SimpleNamespace(current_id="session"), workflow_store=store,
                              workflows=SimpleNamespace(running=False))
    saved = await workflow_tools.tool(service, "save_workflow", {"definition": template_definition({"review_every": 10})})
    assert saved["template"] == "tagged_feed" and "post.recover" in saved["capabilities"]
    assert saved["options"]["review_every"] == 10 and saved["options"]["max_items"] == 25 and "note" not in saved
    feed = await workflow_tools.tool(service, "save_workflow",
                                     {"definition": template_definition({"recover_truncated": True}, source_kind="feed")})
    assert feed["options"]["recover_truncated"] is False and "x_bookmarks" in feed["note"]
    row = store.get("session", saved["id"])
    assert row["definition"]["source"].startswith("// Jet built-in template tagged_feed v2")
    with pytest.raises(ValueError, match="either source or template"):
        await workflow_tools.tool(service, "save_workflow",
                                  {"definition": {**template_definition(), "source": "return 1;"}})
    custom = definition()
    custom.pop("capabilities")
    with pytest.raises(ValueError, match="capabilities is required"):
        await workflow_tools.tool(service, "save_workflow", {"definition": custom})
    sdk = await workflow_tools.tool(service, "workflow_sdk", {})
    assert sdk["templates"][0]["options"]["review_every"]["default"] == 0
    schema = next(t for t in workflow_tools.schemas(None) if t["name"] == "save_workflow")["inputSchema"]
    assert "source" not in schema["properties"]["definition"]["required"]
    store.close()


class Feed:
    """A synthetic bookmark list: five items per screen, some truncated."""

    def __init__(self, total, blocked=(), stall_after=None):
        self.items = [
            {"url": f"https://x.com/author{n}/status/{1000 + n}", "text": f"Mobile app post {n}",
             "author": f"Author {n}", "published_at": "2026-09-28T10:00:00Z", "captured_at": 1.0,
             "truncated": n % 4 == 0}
            for n in range(total)
        ]
        self.blocked = {self.items[n]["url"] for n in blocked}
        self.stall_after = stall_after
        self.position = 0
        self.recovered = []

    def factory(self, bridge, plan, stopped, **kwargs):
        feed = self

        class Collector:
            async def read(self):
                return feed.screen()

            async def scroll(self, snapshot):
                feed.position += 5
                if feed.stall_after is not None:
                    feed.position = min(feed.position, feed.stall_after)
                return feed.screen()

        return Collector()

    def screen(self):
        shown = [dict(item) for item in self.items[self.position:self.position + 5]]
        end = self.stall_after is None and self.position + 5 >= len(self.items)
        return {"items": shown, "loading": False, "end_of_feed": end, "status_text": ""}

    async def recover(self, bridge, item, tab, stopped):
        self.recovered.append(item["url"])
        if item["url"] in self.blocked:
            raise RecoveryBlocked("detail_unavailable")
        return dict(item, text=item["text"] + " (full text)", truncated=False)


def template_world(tmp_path, feed, options, max_items, budget_calls=None):
    if not EXECUTABLE.exists():
        pytest.skip("Build workflow runtime")
    store = WorkflowStore(tmp_path)
    raw = template_definition(options, max_items)
    source, caps = workflow_templates.render(raw["template"], raw["source_kind"], raw["limits"])
    body = {k: v for k, v in raw.items() if k != "template"}
    wid = store.save("session", {**body, "source": source, "capabilities": caps})["id"]
    service = SimpleNamespace(
        store=SimpleNamespace(current_id="session"), bridge=Bridge(),
        collections=SimpleNamespace(running=False), tasks=SimpleNamespace(running=False),
        recovery_active=False, activity=lambda _: None,
    )
    service.bridge.tabs = [{"id": "tab", "url": URL}]

    def factory(s, st, sid, wid, stop, progress):
        return WorkflowCapabilities(s, st, sid, wid, stop, progress, worker=Worker(),
                                    collector_factory=feed.factory, recover=feed.recover)

    async def execute(executable, source, payload, handlers, stopped, **limits):
        if budget_calls is not None:
            # Simulate a nearly spent slice without waiting minutes for the time budget.
            payload = {**payload, "budget": {**payload["budget"], "calls": budget_calls}}
        return await run_script(executable, source, payload, handlers, stopped, **limits)

    manager = WorkflowManager(service, store, execute=execute, capability_factory=factory, executable=EXECUTABLE)
    reviews = []
    manager.on_checkpoint = lambda sid, wid: reviews.append(wid)
    return store, wid, manager, reviews


async def settle(manager):
    """Wait for the current slice and any local continuation it scheduled."""
    for _ in range(200):
        if manager.job is not None:
            await manager.job
        elif manager._continuation is not None:
            await manager._continuation
        else:
            return
    raise AssertionError("workflow did not settle")


async def test_template_reviews_first_ten_then_finishes_requested_items(tmp_path):
    feed = Feed(40, blocked=(4,))
    store, wid, manager, reviews = template_world(tmp_path, feed, {"review_every": 10}, max_items=25)
    await manager.start("session", wid)
    await settle(manager)
    row = store.get("session", wid)
    assert (row["status"], row["error"]) == ("paused", "checkpoint_review") and reviews == [wid]
    assert store.records("session", wid)["total"] == 10
    blocked = store.get_record("session", wid, next(
        r["id"] for r in store.records("session", wid, limit=20)["items"] if r["url"] == feed.items[4]["url"]))
    assert blocked["truncated"] is True and blocked["tags"] == ["mobile"]  # Partial evidence, still tagged.
    await manager.start("session", wid)  # What run_workflow does after Grok approves.
    await settle(manager)
    row = store.get("session", wid)
    assert (row["status"], row["error"]) == ("paused", "checkpoint_review") and len(reviews) == 2
    await manager.start("session", wid)
    await settle(manager)
    row = store.get("session", wid)
    assert row["status"] == "completed" and "25 items" in row["last_result"]
    records = store.records("session", wid, limit=100)["items"]
    assert len(records) == 25 and len({r["url"] for r in records}) == 25
    assert all(r["summary"] and r["author"] and r["published_at"] for r in records)
    assert all(r["text"].endswith("(full text)") for r in records
               if r["url"] in feed.recovered and r["url"] not in feed.blocked)


async def test_template_continues_slices_locally_without_review(tmp_path):
    feed = Feed(30)
    store, wid, manager, reviews = template_world(
        tmp_path, feed, {"first_review": 0, "summarize": False}, max_items=12, budget_calls=24)
    await manager.start("session", wid)
    await settle(manager)
    row = store.get("session", wid)
    assert row["status"] == "completed" and reviews == []
    assert row["checkpoint"]["slices"] >= 2
    assert store.records("session", wid)["total"] == 12


async def test_template_pauses_when_scrolling_reveals_nothing_new(tmp_path):
    feed = Feed(30, stall_after=5)
    store, wid, manager, reviews = template_world(tmp_path, feed, {"first_review": 0}, max_items=25)
    await manager.start("session", wid)
    await settle(manager)
    row = store.get("session", wid)
    assert (row["status"], row["error"]) == ("paused", "checkpoint_pause") and reviews == []
    assert "No new items" in row["last_result"] and store.records("session", wid)["total"] == 10


async def test_pause_between_local_slices_cancels_the_continuation(tmp_path):
    feed = Feed(30)
    store, wid, manager, _ = template_world(
        tmp_path, feed, {"first_review": 0, "summarize": False}, max_items=20, budget_calls=24)
    await manager.start("session", wid)
    await manager.job
    assert store.get("session", wid)["error"] == "checkpoint_continue" and manager._continuation is not None
    summary = await manager.control("session", wid, "pause")
    assert summary["status"] == "paused" and summary["error"] is None
    await asyncio.sleep(0.05)
    assert not manager.running and manager._continuation is None
    assert store.records("session", wid)["total"] < 20


async def test_template_endurance_many_local_slices_to_the_item_limit(tmp_path):
    """300 items across dozens of slices: one review, no duplicates, counters consistent."""
    feed = Feed(400, blocked=tuple(range(0, 400, 40)))
    store, wid, manager, reviews = template_world(
        tmp_path, feed, {"first_review": 10, "summarize": False}, max_items=300, budget_calls=40)
    await manager.start("session", wid)
    await settle(manager)
    assert store.get("session", wid)["error"] == "checkpoint_review" and reviews == [wid]
    await manager.start("session", wid)
    await settle(manager)
    row = store.get("session", wid)
    assert row["status"] == "completed", row["error"]
    assert row["checkpoint"]["slices"] >= 20 and reviews == [wid]
    records = store.records("session", wid, limit=0)["total"]
    urls = {r["url"] for offset in range(0, records, 100)
            for r in store.records("session", wid, limit=100, offset=offset)["items"]}
    assert records == 300 == len(urls) == row["counters"]["saved"]
    assert row["checkpoint"]["partial"] == len([n for n in range(0, 300, 40)])  # Blocked recoveries kept partial.
    assert row["counters"]["calls"] <= row["definition"]["limits"]["max_calls"]


class BranchWorker(Worker):
    """Tags nothing in the yes/no pass; picks 'web' as the best tag; expands cut-off posts."""

    def __init__(self):
        super().__init__()
        self.questions = []

    def predict(self, mode, req):
        answers = {}
        for qid, question in req["questions"].items():
            criteria = question["criteria"]
            self.questions.append(qid if qid != "q" else "decide:" + ",".join(sorted(criteria)))
            if "expand" in criteria:
                label = "expand"
            elif qid == "best":
                label = "web" if "web" in criteria else "none"
            else:
                label = "no"
            answers[qid] = dict(valid=True, label=label, probabilities=None, confidence=None)
        return {"model": "pinned-qwen-id", "answers": answers}


async def test_template_v2_opens_cut_off_posts_and_second_passes_untagged(tmp_path):
    feed = Feed(6)
    feed.items[1]["text"] = "Five lessons from shipping our browser extension…"
    feed.items[1]["truncated"] = False
    worker = BranchWorker()
    store, wid, manager, _ = template_world(tmp_path, feed, {"first_review": 0}, max_items=6)
    manager.capability_factory = lambda s, st, sid, wid, stop, progress: WorkflowCapabilities(
        s, st, sid, wid, stop, progress, worker=worker, collector_factory=feed.factory, recover=feed.recover)
    await manager.start("session", wid)
    await settle(manager)
    row = store.get("session", wid)
    assert row["status"] == "completed", row["error"]
    # The unflagged "…" post was opened because the local model chose to expand it.
    assert feed.items[1]["url"] in feed.recovered
    assert row["checkpoint"]["expanded_by_decision"] == 1
    records = store.records("session", wid, limit=20)["items"]
    assert all(r["tags"] == ["web"] for r in records)  # Every post got the second-pass tag.
    assert row["checkpoint"]["fallback_tags"] == 6 and row["checkpoint"]["untagged"] == 0
    assert "decide:expand,keep" in worker.questions and worker.questions.count("best") == 6


async def test_template_v2_branches_can_be_turned_off(tmp_path):
    feed = Feed(3)
    feed.items[1]["text"] = "Cut off here..."
    feed.items[1]["truncated"] = False
    worker = BranchWorker()
    store, wid, manager, _ = template_world(
        tmp_path, feed, {"first_review": 0, "expand_cut_off": False, "fallback_tag": False}, max_items=3)
    manager.capability_factory = lambda s, st, sid, wid, stop, progress: WorkflowCapabilities(
        s, st, sid, wid, stop, progress, worker=worker, collector_factory=feed.factory, recover=feed.recover)
    await manager.start("session", wid)
    await settle(manager)
    row = store.get("session", wid)
    assert row["status"] == "completed" and row["checkpoint"]["untagged"] == 3
    assert feed.items[1]["url"] not in feed.recovered and "best" not in worker.questions
