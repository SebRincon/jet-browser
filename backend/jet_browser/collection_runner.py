import asyncio
import contextlib
import math
import threading
import time
from dataclasses import replace

from .classification import classify_page
from .collection_plan import CollectionPlan, canonical_url
from .collection_supervision import CollectionSupervision
from .feed_collection import FeedCollector
from .feed_review import review_feed
from .feed_runner import run_feed
from .site_collection import CollectionBlocked, SiteCollector

_ACTIONS = frozenset({"pause", "resume", "start", "stop"})
_TERMINAL = frozenset({"completed", "partial", "failed", "cancelled"})


def _seconds(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("seconds")
    if value != value or value in (float("inf"), float("-inf")) or value < 0 or value > 10:
        raise ValueError("seconds")
    return float(value)


def _checkpoint(raw):
    raw = raw or {}

    def keep(key, limit):
        out = []
        for url in list(raw.get(key) or [])[:limit]:
            if isinstance(url, str) and _canon(url):
                out.append(url)
        return out

    pending = raw.get("pending_url")
    return {
        "frontier": keep("frontier", 500),
        "visited": keep("visited", 50),
        "pending_url": pending if isinstance(pending, str) and _canon(pending) else None,
    }


def _counters(raw):
    raw = raw or {}

    def num(name, cast):
        try:
            return cast(raw.get(name) or 0)
        except (TypeError, ValueError):
            return cast(0)

    return {
        "pages": num("pages", int),
        "classified": num("classified", int),
        "needs_review": num("needs_review", int),
        "model_calls": num("model_calls", int),
        "elapsed_ms": num("elapsed_ms", float),
    }


def _canon(url):
    try:
        value = canonical_url(url)
    except Exception:
        return None
    if not isinstance(value, str) or not value:
        return None
    return value


class CollectionManager:
    def __init__(
        self,
        store,
        bridge,
        *,
        classifier=classify_page,
        collector_factory=SiteCollector,
        feed_collector_factory=FeedCollector,
        reviewer=None,
        trace=None,
    ):
        self.store = store
        self.supervision = CollectionSupervision(store)
        self.on_checkpoint = None
        self.supervision.recover()
        self.bridge = bridge
        self.classifier = classifier
        self.collector_factory = collector_factory
        self.feed_collector_factory = feed_collector_factory
        self.reviewer = review_feed if reviewer is None else reviewer
        self.trace = trace
        self.job = None
        self.active_id = None
        self.active_session = None
        self.stopped = threading.Event()
        self._pause = threading.Event()
        self.pause_requested = False
        store.recover_interrupted()

    @property
    def running(self):
        job = self.job
        return job is not None and not job.done()

    def _view(self, run):
        out = {key: value for key, value in run.items() if key != "checkpoint"}
        out["resumable"] = run.get("status") == "paused"
        plan = run.get("plan")
        if isinstance(plan, dict) and plan.get("source_kind") in {"feed", "x_bookmarks"}:
            checkpoint = run.get("checkpoint")
            feed = checkpoint.get("feed") if isinstance(checkpoint, dict) else None
            if not isinstance(feed, dict):
                feed = {}
            out["progress"] = {
                "last_url": feed.get("last_url"),
                "scroll_top": feed.get("scroll_top"),
                "scrolls": feed.get("scrolls"),
                "stalls": feed.get("stalls"),
            }
        if isinstance(plan, dict):
            if plan.get("source_kind") in {"feed", "x_bookmarks"}:
                keys = ("max_seconds", "max_items", "max_scrolls")
            else:
                keys = ("max_seconds", "max_pages")
            out["budgets"] = {key: plan[key] for key in keys if key in plan}
        if isinstance(run.get('supervision'), dict):
            if run['supervision'].get('pending') and run.get('status') == 'paused':
                out['review'] = self.supervision.packet(run['session_id'], run['id'])
            if run.get('status') == 'running':
                out['counters'] = dict(run['counters'])
                out['counters']['elapsed_ms'] += max(0, time.time() - run['updated_at']) * 1000
        return out

    def summary(self, sid, rid):
        return self._view(self.store.get(sid, rid))

    def summaries(self, sid):
        runs = list(self.store.list(sid) or [])
        runs.sort(key=lambda run: (run.get("created_at") or 0, run.get("updated_at") or 0), reverse=True)
        return [self._view(run) for run in runs[:20]]

    def _emit(self, name, **fields):
        tracer = self.trace
        if tracer is None:
            return
        try:
            emit = getattr(tracer, "emit", None)
            if emit is None:
                tracer(name, **fields)
            else:
                try:
                    emit(name, **fields)
                except TypeError:
                    emit(name, fields)
        except Exception:
            return

    def review_due(self, sid, rid, counters):
        return self.supervision.due(sid, rid, counters)

    def queue_review(self, sid, rid, reason):
        self.supervision.checkpoint(sid, rid, reason)
        self._emit('collection.supervisor_checkpoint', session_id=sid, task_id=rid, reason=reason)
        if self.on_checkpoint is not None:
            asyncio.get_running_loop().call_soon(self.on_checkpoint, sid, rid)

    async def start(self, sid, rid):
        if self.running:
            raise ValueError("invalid transition")
        run = self.store.get(sid, rid)
        if run.get("status") not in ("prepared", "paused"):
            raise ValueError("invalid transition")
        if (run.get("supervision") or {}).get("pending"):
            raise ValueError("Review this checkpoint before resuming")
        plan = CollectionPlan.from_dict(run["plan"])
        if self.bridge.tab(plan.tab_id) != getattr(self.bridge, "active_tab_id", None) and not getattr(self.bridge, "supports_background", False):
            raise ValueError("inactive tab")
        policy = run.get('supervision') or {}
        if policy:
            spent = max(0, run['counters']['elapsed_ms'] - policy.get('authorized_elapsed_ms', 0))
            remaining = plan.max_seconds - spent / 1000
            items_left = plan.max_items - (run['counters']['pages'] - policy.get('authorized_items', 0))
            scrolls_left = plan.max_scrolls - (run['checkpoint']['feed']['scrolls'] - policy.get('authorized_scrolls', 0))
            reason = 'time_budget' if remaining <= 0 else 'item_budget' if items_left <= 0 else 'scroll_budget' if scrolls_left <= 0 else None
            if reason:
                self.store.update(sid, rid, status='paused', reason=reason)
                raise ValueError('Authorized run limit reached; choose a new bounded run')
            plan = replace(plan, max_seconds=max(1, math.ceil(remaining)), max_items=items_left, max_scrolls=scrolls_left)
        lease_owner = f"collection:{rid}:{time.time_ns()}" if getattr(self.bridge,"supports_background",False) else None
        if lease_owner:
            self.bridge.claim_tab(plan.tab_id, lease_owner)
        try:
            event = threading.Event()
            pause = threading.Event()
            if plan.source_kind != "website":
                checkpoint = run.get("checkpoint")
                expected = plan.start_url
                collector = self.feed_collector_factory(self.bridge, plan, event, expected_url=expected)
            else:
                checkpoint = _checkpoint(run.get("checkpoint"))
                visited = checkpoint["visited"]
                expected = checkpoint["pending_url"] or (visited[-1] if visited else plan.start_url)
                collector = self.collector_factory(self.bridge, plan, event, expected_url=expected)
            saved = self.store.items(sid, rid, limit=100)
            items = saved.get("items") if isinstance(saved, dict) else ()
            limited = run.get("reason") == "capture_limited" or any(
                isinstance(item, dict) and bool(item.get("truncated")) for item in (items or ())
            )
            kept = "capture_limited" if limited else None
            self.store.update(sid, rid, status="running", reason=kept)
            self.stopped = event
            self._pause = pause
            self.pause_requested = False
            trace_turn = run.get("turn_id")
            if self.trace is not None and hasattr(self.trace, "current_context"):
                trace_turn = self.trace.current_context().get("turn_id") or trace_turn
        except BaseException:
            if lease_owner:
                self.bridge.release_tab(plan.tab_id, lease_owner)
            raise
        try:
            task = asyncio.create_task(
                self._run(
                    sid,
                    rid,
                    plan,
                    collector,
                    event,
                    pause,
                    trace_turn,
                    checkpoint,
                    _counters(run.get("counters")),
                    kept == "capture_limited",
                )
            )
        except BaseException:
            if lease_owner:
                self.bridge.release_tab(plan.tab_id, lease_owner)
            self.store.update(sid, rid, status=run.get("status"), reason=run.get("reason"))
            raise
        if lease_owner:
            task.add_done_callback(lambda _: self.bridge.release_tab(plan.tab_id, lease_owner))
        self.job = task
        self.active_session = sid
        self.active_id = rid
        return self.summary(sid, rid)

    async def wait(self, sid, rid, seconds=0):
        seconds = _seconds(seconds)
        self.store.get(sid, rid)
        job = self.job
        if job is not None and not job.done() and self.active_session == sid and self.active_id == rid:
            try:
                await asyncio.wait_for(asyncio.shield(job), seconds)
            except asyncio.TimeoutError:
                pass
            except asyncio.CancelledError:
                raise
        return self.summary(sid, rid)

    async def control(self, sid, rid, action, limits=None):
        if not isinstance(action, str) or action not in _ACTIONS:
            raise ValueError("invalid action")
        if limits is not None and action != "resume":
            raise ValueError("invalid action")
        run = self.store.get(sid, rid)
        status = run.get("status")
        active = self.running and self.active_session == sid and self.active_id == rid
        if action == "pause":
            if status == "paused":
                return self.summary(sid, rid)
            if not active or status not in ("running", "pausing"):
                raise ValueError("invalid transition")
            self.pause_requested = True
            self._pause.set()
            if status == "running":
                self.store.update(sid, rid, status="pausing")
            return self.summary(sid, rid)
        if action in ("resume", "start"):
            if action == "resume" and limits is not None:
                self.store.configure_limits(sid, rid, limits)
            return await self.start(sid, rid)
        if status in _TERMINAL:
            return self.summary(sid, rid)
        if status in ("prepared", "paused"):
            self.store.update(sid, rid, status="cancelled", reason="user_stopped")
            return self.summary(sid, rid)
        if not active:
            raise ValueError("invalid transition")
        self.stopped.set()
        job = self.job
        job.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await job
        current = self.store.get(sid, rid)
        if current.get("status") not in _TERMINAL:
            self.store.update(sid, rid, status="cancelled", reason="user_stopped")
        if self.job is job:
            self.job = None
            self.active_id = None
            self.active_session = None
        return self.summary(sid, rid)

    async def stop_active(self):
        sid, rid = self.active_session, self.active_id
        if sid is None or rid is None:
            return None
        return await self.control(sid, rid, "stop")

    async def _run(self, sid, rid, plan, collector, event, pause, turn_id, checkpoint, counters, limited):
        if plan.source_kind != "website":
            return await run_feed(
                self, sid, rid, plan, collector, event, pause, turn_id, checkpoint, counters, self.reviewer
            )
        task = asyncio.current_task()
        started = time.monotonic()
        base_elapsed = counters["elapsed_ms"]
        attempts = 0
        attempt_limit = max(0, plan.max_pages - counters["pages"])
        passive = checkpoint["pending_url"] is not None
        seen = set()
        for url in checkpoint["visited"] + checkpoint["frontier"]:
            canon = _canon(url)
            if canon is not None:
                seen.add(canon)
        terminal = None
        if checkpoint["pending_url"] is None and not checkpoint["frontier"] and not checkpoint["visited"]:
            start = _canon(plan.start_url)
            if start is None:
                terminal = ("paused", "invalid_source")
            else:
                checkpoint["frontier"].append(start)
                seen.add(start)

        def elapsed():
            return base_elapsed + (time.monotonic() - started) * 1000.0

        def remaining():
            return plan.max_seconds - elapsed() / 1000.0

        def trace(name, status, reason, step, duration):
            self._emit(
                name,
                session_id=sid,
                turn_id=turn_id,
                task_id=rid,
                status=status,
                model=plan.model,
                steps=step,
                duration_ms=duration,
                reason=reason,
            )

        def drop(*urls):
            ban = {_canon(url) for url in urls if url}
            checkpoint["frontier"] = [url for url in checkpoint["frontier"] if _canon(url) not in ban]

        try:
            trace("collection.start", "running", None, counters["pages"], 0)
            while terminal is None:
                if event.is_set():
                    terminal = ("cancelled", "user_stopped")
                    break
                if pause.is_set():
                    terminal = ("paused", "user_paused")
                    break
                if remaining() <= 0:
                    terminal = ("partial", "time_budget")
                    break
                if checkpoint["pending_url"] is None and not checkpoint["frontier"]:
                    terminal = (
                        ("partial", "capture_limited") if limited else ("completed", "observed_frontier_exhausted")
                    )
                    break
                if attempts >= attempt_limit:
                    terminal = ("partial", "page_budget")
                    break
                if passive:
                    target, navigate, passive = checkpoint["pending_url"], False, False
                else:
                    target, navigate = checkpoint["frontier"][0], True
                if _canon(target) is None:
                    terminal = ("paused", "invalid_source")
                    break
                checkpoint["pending_url"] = target
                counters["elapsed_ms"] = elapsed()
                self.store.update(sid, rid, checkpoint=checkpoint, counters=counters)
                try:
                    page = await asyncio.wait_for(collector.read(target, navigate=navigate), max(0.0, remaining()))
                except asyncio.TimeoutError:
                    event.set()
                    terminal = ("partial", "time_budget")
                    break
                except CollectionBlocked as blocked:
                    terminal = ("paused", blocked.reason if isinstance(blocked.reason, str) else "blocked")
                    break
                attempts += 1
                actual = page.get("url") if isinstance(page, dict) else None
                if not isinstance(actual, str):
                    raise RuntimeError("unreadable page")
                actual_canon = _canon(actual)
                if actual_canon is None:
                    terminal = ("paused", "invalid_source")
                    break
                if not plan.in_scope(actual_canon):
                    terminal = ("paused", "out_of_scope")
                    break
                target_canon = _canon(target)
                if target_canon is not None:
                    seen.add(target_canon)
                seen.add(actual_canon)
                checkpoint["pending_url"] = actual_canon
                drop(target, actual)
                counters["elapsed_ms"] = elapsed()
                self.store.update(sid, rid, checkpoint=checkpoint, counters=counters)
                visited = {_canon(url) for url in checkpoint["visited"] if _canon(url)}
                if actual_canon in visited:
                    checkpoint["pending_url"] = None
                    counters["elapsed_ms"] = elapsed()
                    self.store.update(sid, rid, checkpoint=checkpoint, counters=counters)
                    continue
                if len(checkpoint["visited"]) < 50:
                    checkpoint["visited"].append(actual_canon)
                else:
                    limited = True
                overflow = False
                for link in page.get("links") or []:
                    canon = _canon(link)
                    if not canon or canon in seen or not plan.in_scope(canon):
                        continue
                    if len(checkpoint["frontier"]) >= 500:
                        overflow = True
                        break
                    checkpoint["frontier"].append(canon)
                    seen.add(canon)
                if overflow or page.get("truncated"):
                    limited = True
                try:
                    classification = await asyncio.wait_for(
                        asyncio.to_thread(self.classifier, plan, page.get("text") or "", stopped=event),
                        max(0.0, remaining()),
                    )
                except asyncio.TimeoutError:
                    event.set()
                    terminal = ("partial", "time_budget")
                    break
                except asyncio.CancelledError:
                    event.set()
                    raise
                except Exception:
                    terminal = ("paused", "model_unavailable")
                    break
                if not isinstance(classification, dict):
                    raise RuntimeError("classification")
                item = {
                    "url": actual,
                    "title": page.get("title"),
                    "text": page.get("text"),
                    "captured_at": page.get("captured_at"),
                    "truncated": bool(page.get("truncated") or overflow),
                    "classification": classification,
                }
                calls = classification.get("model_calls", 0)
                if isinstance(calls, bool) or not isinstance(calls, int) or calls < 0:
                    raise RuntimeError("classification")
                counters["pages"] += 1
                if classification.get("label_id") != "needs_review":
                    counters["classified"] += 1
                else:
                    counters["needs_review"] += 1
                counters["model_calls"] += calls
                counters["elapsed_ms"] = elapsed()
                checkpoint["pending_url"] = None
                self.store.commit_item(sid, rid, item, checkpoint, counters)
                if limited:
                    self.store.update(sid, rid, reason="capture_limited")
                trace(
                    "collection.item",
                    "running",
                    "capture_limited" if limited else None,
                    counters["pages"],
                    counters["elapsed_ms"],
                )
        except asyncio.CancelledError:
            event.set()
            terminal = ("cancelled", "user_stopped")
        except Exception:
            terminal = ("cancelled", "user_stopped") if event.is_set() else ("failed", "internal_error")
        status, reason = terminal or ("failed", "internal_error")
        if event.is_set() and not (status == "partial" and reason == "time_budget") and status != "failed":
            status, reason = "cancelled", "user_stopped"
        try:
            current = self.store.get(sid, rid)
            if current.get("status") == "cancelled":
                status, reason = "cancelled", current.get("reason") or "user_stopped"
            checkpoint = _checkpoint(current.get("checkpoint"))
            counters = _counters(current.get("counters"))
            counters["elapsed_ms"] = elapsed()
            self.store.update(sid, rid, status=status, reason=reason, checkpoint=checkpoint, counters=counters)
        except Exception:
            status, reason = "failed", "internal_error"
        trace("collection.end", status, reason, counters["pages"], counters["elapsed_ms"])
        if self.job is task:
            self.job = None
            self.active_id = None
            self.active_session = None
            self.pause_requested = False
