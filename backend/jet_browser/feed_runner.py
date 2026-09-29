import asyncio
import time

from .feed_review import review_feed
from .site_collection import CollectionBlocked


class _ModelUnavailable(Exception):
    pass


class _Hold(Exception):
    def __init__(self, status, reason):
        self.status = status
        self.reason = reason


def _limit(plan):
    return 500 if plan.model == "laya_typed" else 1200


def _abstains(record):
    label = record.get("label_id")
    return label in (None, "", "abstain") or bool(record.get("reason"))


def classify_feed_item(classifier, plan, text, event):
    """Chunk a feed item and keep a label only when every chunk agrees."""
    raw = text or ""
    size = _limit(plan)
    if raw == "":
        parts, tail = [""], False
    else:
        cap = size * 6
        body = raw[:cap]
        parts = [body[i : i + size] for i in range(0, len(body), size)] or [""]
        tail = len(raw) > cap
    rows = []
    for part in parts:
        if event.is_set():
            raise asyncio.CancelledError
        rows.append(classifier(plan, part, stopped=event))
    models = [row.get("model") for row in rows]
    if len(set(models)) != 1:
        raise RuntimeError("mixed model identity")
    labels = [row.get("label_id") for row in rows]
    reasons = [row.get("reason") for row in rows if row.get("reason")]
    agreed = len(set(labels)) == 1 and not any(_abstains(row) for row in rows)
    confs = [row.get("confidence") for row in rows]
    confidence = min(confs) if confs and all(c is not None for c in confs) else None
    if tail or not agreed:
        label = "needs_review"
        reason = "capture_limited" if tail else (reasons[0] if reasons else "needs_review")
    else:
        label, reason = labels[0], None
    return {
        "label_id": label,
        "taxonomy_version": plan.taxonomy_version,
        "classifier_revision": plan.classifier_revision,
        "model": models[0],
        "confidence": confidence,
        "inference_ms": sum(float(row.get("inference_ms") or 0) for row in rows),
        "reason": reason,
        "excerpt_chars": sum(int(row.get("excerpt_chars") or 0) for row in rows),
        "model_calls": sum(row["model_calls"] for row in rows),
    }


def _plain_checkpoint(checkpoint):
    feed = checkpoint.get("feed") or {}
    return {
        "frontier": list(checkpoint.get("frontier") or []),
        "visited": list(checkpoint.get("visited") or []),
        "pending_url": checkpoint.get("pending_url"),
        "feed": {
            "last_url": feed.get("last_url"),
            "document_id": feed.get("document_id"),
            "scroll_top": float(feed.get("scroll_top") or 0),
            "scrolls": int(feed.get("scrolls") or 0),
            "stalls": int(feed.get("stalls") or 0),
            "pending_scroll": bool(feed.get("pending_scroll")),
        },
    }


def _plain_counters(counters):
    return {
        "pages": int(counters.get("pages") or 0),
        "classified": int(counters.get("classified") or 0),
        "needs_review": int(counters.get("needs_review") or 0),
        "model_calls": int(counters.get("model_calls") or 0),
        "elapsed_ms": float(counters.get("elapsed_ms") or 0),
    }


def _replace(dest, src):
    dest.clear()
    dest.update(src)


def _view(snapshot):
    scroll = snapshot.get("scroll") or {}
    return (snapshot.get("url"), snapshot.get("document_id"), scroll.get("top"), scroll.get("root"))


def _blocked(exc):
    if isinstance(exc, CollectionBlocked):
        return getattr(exc, "reason", None) or "blocked"
    return None


def _chars(snapshot):
    return sum(len(item.get("text") or "") for item in snapshot.get("items") or [])


def _unseen(snapshot, seen):
    return [item for item in (snapshot.get("items") or []) if item.get("url") not in seen]


async def _bound(deadline, awaitable):
    timeout = deadline[0] - time.monotonic()
    if timeout <= 0:
        awaitable.close()
        raise TimeoutError()
    return await asyncio.wait_for(awaitable, timeout)


async def run_feed(manager, sid, rid, plan, collector, event, pause, turn_id, checkpoint, counters, reviewer=None):
    if reviewer is None:
        reviewer = review_feed
    job = asyncio.current_task()
    started = time.monotonic()
    opening = {"due": True}
    base_elapsed = float(counters.get("elapsed_ms") or 0)
    deadline = [started + float(plan.max_seconds)]
    fence = {"time": False}
    finished = {"done": False}
    _replace(checkpoint, _plain_checkpoint(checkpoint))
    _replace(counters, _plain_counters(counters))

    def trace(name, **fields):
        manager._emit(name, session_id=sid, turn_id=turn_id, task_id=rid, **fields)

    def elapsed():
        counters["elapsed_ms"] = base_elapsed + (time.monotonic() - started) * 1000.0

    def persist():
        elapsed()
        manager.store.update(sid, rid, checkpoint=_plain_checkpoint(checkpoint), counters=_plain_counters(counters))

    def finish(status, reason):
        if finished["done"]:
            return
        finished["done"] = True
        elapsed()
        manager.store.update(
            sid,
            rid,
            status=status,
            reason=reason,
            checkpoint=_plain_checkpoint(checkpoint),
            counters=_plain_counters(counters),
        )
        trace(
            "collection.end",
            status=status,
            reason=reason,
            duration_ms=(time.monotonic() - started) * 1000.0,
            elapsed_ms=counters["elapsed_ms"],
            count=counters["pages"],
        )

    def user_stopped():
        return event.is_set() and not fence["time"]

    def paused():
        if user_stopped():
            return False
        if getattr(pause, "is_set", lambda: False)():
            return True
        return bool(getattr(manager, "pause_requested", False))

    try:
        trace("collection.start", model=plan.model)
        seen = set(manager.store.seen_urls(sid, rid) or ())
        saved_pass = 0
        scrolls_pass = 0
        snapshot = await _bound(deadline, collector.read())
        _observe(trace, snapshot)
        _resume(trace, checkpoint, snapshot)
        persist()
        while True:
            elapsed()
            due = manager.review_due(sid, rid, counters)
            if due and not user_stopped() and not paused():
                finish('paused', 'supervisor_review')
                manager.queue_review(sid, rid, due)
                return
            hold = await _drain(
                manager,
                sid,
                rid,
                plan,
                collector,
                event,
                snapshot,
                seen,
                checkpoint,
                counters,
                deadline,
                elapsed,
                saved_pass,
                user_stopped,
                paused,
                finish,
                trace,
            )
            saved_pass = hold
            if finished["done"]:
                return
            if user_stopped():
                finish("cancelled", "user_stopped")
                return
            if paused():
                finish("paused", "user_paused")
                return
            if scrolls_pass >= int(plan.max_scrolls):
                finish("paused", "scroll_budget")
                return
            if snapshot.get("end_of_feed"):
                finish("paused", "feed_end_unverified")
                return
            again = await _bound(deadline, collector.read())
            _observe(trace, again)
            if _view(again)[1] != _view(snapshot)[1]:
                finish("paused", "source_changed")
                return
            fresh = _unseen(again, seen)
            if fresh:
                snapshot = again
                _touch_view(checkpoint, again)
                persist()
                continue
            if user_stopped():
                finish("cancelled", "user_stopped")
                return
            if paused():
                finish("paused", "user_paused")
                return
            if _review_due(again, checkpoint, opening):
                opening["due"] = False
                verdict = await _consult(
                    reviewer,
                    plan,
                    collector,
                    event,
                    again,
                    checkpoint,
                    deadline,
                    user_stopped,
                    paused,
                    finish,
                    trace,
                )
                if verdict is None:
                    return
                action, again = verdict
                if action == "reobserve":
                    snapshot = again
                    opening["due"] = True
                    _touch_view(checkpoint, again)
                    persist()
                    continue
                if action == "needs_attention":
                    finish("paused", "needs_attention")
                    return
                if _unseen(again, seen):
                    snapshot = again
                    _touch_view(checkpoint, again)
                    persist()
                    continue
                if action == "wait":
                    observed = await _reobserve(
                        collector,
                        event,
                        again,
                        seen,
                        deadline,
                        user_stopped,
                        paused,
                        finish,
                        trace,
                    )
                    if observed is None:
                        return
                    snapshot = observed
                    opening["due"] = True
                    _touch_view(checkpoint, observed)
                    persist()
                    continue
            staged = _plain_checkpoint(checkpoint)
            staged["feed"]["pending_scroll"] = True
            elapsed()
            manager.store.update(sid, rid, checkpoint=staged, counters=_plain_counters(counters))
            _replace(checkpoint, staged)
            scrolled = await _bound(deadline, collector.scroll(again))
            feed = checkpoint["feed"]
            feed["pending_scroll"] = False
            feed["document_id"] = scrolled.get("document_id")
            feed["scroll_top"] = float((scrolled.get("scroll") or {}).get("top") or 0)
            feed["scrolls"] = int(feed["scrolls"]) + 1
            scrolls_pass += 1
            born = _unseen(scrolled, seen)
            moved = abs(scrolled["scroll"]["top"] - again["scroll"]["top"]) > 4
            progressed = bool(born) or moved
            feed["stalls"] = 0 if progressed else int(feed["stalls"]) + 1
            trace(
                "collection.scroll",
                steps=feed["scrolls"],
                count=len(born),
                scroll_top=feed["scroll_top"],
                scroll_height=scrolled["scroll"]["height"],
                viewport_height=scrolled["scroll"]["viewport"],
                status="ok" if progressed else "stall",
                reason=None if born else ("scroll_advanced" if moved else "no_new_items"),
            )
            persist()
            if feed["stalls"] >= 3:
                finish("paused", "feed_stalled")
                return
            snapshot = scrolled
    except asyncio.CancelledError:
        finish("cancelled", "user_stopped")
        raise
    except TimeoutError:
        fence["time"] = True
        event.set()
        finish("paused", "time_budget")
    except _ModelUnavailable:
        finish("paused", "model_unavailable")
    except _Hold as hold:
        finish(hold.status, hold.reason)
    except Exception as exc:
        reason = _blocked(exc)
        if reason is not None:
            finish("paused", reason)
        elif not finished["done"]:
            trace("collection.error", error_type=type(exc).__name__)
            finish("failed", "internal_error")
    finally:
        if getattr(manager, "job", None) is job:
            manager.job = None
            manager.active_id = None
            manager.active_session = None
            manager.pause_requested = False


def _observe(trace, snapshot):
    items = snapshot.get("items") or []
    trace("collection.observe", count=len(items), context_chars=_chars(snapshot))


def _touch_view(checkpoint, snapshot):
    feed = checkpoint["feed"]
    feed["document_id"] = snapshot.get("document_id")
    feed["scroll_top"] = float((snapshot.get("scroll") or {}).get("top") or 0)


def _review_input(snapshot, checkpoint):
    feed = checkpoint["feed"]
    scroll = snapshot.get("scroll") or {}
    return {
        "loading": bool(snapshot.get("loading")),
        "stalls": int(feed.get("stalls") or 0),
        "scrolls": int(feed.get("scrolls") or 0),
        "scroll": {
            "top": scroll.get("top"),
            "height": scroll.get("height"),
            "viewport": scroll.get("viewport"),
        },
        "status_text": snapshot.get("status_text") if isinstance(snapshot.get("status_text"), str) else "",
        "unseen": 0,
    }


def _review_due(snapshot, checkpoint, opening):
    if opening["due"]:
        return True
    feed = checkpoint["feed"]
    status = snapshot.get("status_text") if isinstance(snapshot.get("status_text"), str) else ""
    return (
        int(feed.get("scrolls") or 0) % 10 == 0
        or bool(snapshot.get("loading"))
        or int(feed.get("stalls") or 0) > 0
        or bool(status.strip())
    )


def _coerce_review(record):
    if not isinstance(record, dict):
        return "needs_attention", None, "needs_attention"
    action = record.get("action") or record.get("label_id")
    if action not in ("continue_scroll", "wait", "needs_attention"):
        action = "needs_attention"
    model = record.get("model")
    if not isinstance(model, str) or not model:
        model = None
        action = "needs_attention"
    reason = record.get("reason")
    if action == "needs_attention":
        reason = reason if isinstance(reason, str) and reason.strip() else "needs_attention"
    elif reason is None:
        reason = None
    elif not isinstance(reason, str):
        action, reason = "needs_attention", "needs_attention"
    else:
        reason = " ".join(reason.split())[:120] or None
    if isinstance(reason, str):
        reason = " ".join(reason.split())[:120]
    if reason:
        action = "needs_attention"
    return action, model, reason


async def _idle(deadline, seconds):
    timeout = deadline[0] - time.monotonic()
    if timeout <= 0 or timeout < seconds:
        if timeout > 0:
            await asyncio.sleep(timeout)
        raise TimeoutError()
    await asyncio.sleep(seconds)


async def _consult(
    reviewer, plan, collector, event, snapshot, checkpoint, deadline, user_stopped, paused, finish, trace
):
    if user_stopped():
        finish("cancelled", "user_stopped")
        return None
    if paused():
        finish("paused", "user_paused")
        return None
    started = time.monotonic()
    try:
        record = await _bound(
            deadline,
            asyncio.to_thread(reviewer, plan, _review_input(snapshot, checkpoint), stopped=event),
        )
    except asyncio.CancelledError:
        raise
    except TimeoutError:
        raise
    except Exception as exc:
        if _blocked(exc) is not None:
            raise
        raise _ModelUnavailable from exc
    action, model, reason = _coerce_review(record)
    duration_ms = (time.monotonic() - started) * 1000.0
    if user_stopped():
        finish("cancelled", "user_stopped")
        return None
    if paused():
        finish("paused", "user_paused")
        return None
    checked = await _bound(deadline, collector.read())
    _observe(trace, checked)
    if _view(checked) != _view(snapshot):
        raise _Hold("paused", "source_changed")
    trace("collection.review", decision=action, model=model, duration_ms=duration_ms, reason=reason)
    if (bool(checked.get("loading")), checked.get("status_text", "")) != (
        bool(snapshot.get("loading")),
        snapshot.get("status_text", ""),
    ):
        trace("collection.review_stale", reason="page_status_changed")
        return "reobserve", checked
    return action, checked


async def _reobserve(collector, event, snapshot, seen, deadline, user_stopped, paused, finish, trace):
    document_id = _view(snapshot)[1]
    for _attempt in range(3):
        if user_stopped():
            finish("cancelled", "user_stopped")
            return None
        if paused():
            finish("paused", "user_paused")
            return None
        await _idle(deadline, 1)
        observed = await _bound(deadline, collector.read())
        _observe(trace, observed)
        if _view(observed)[1] != document_id:
            raise _Hold("paused", "source_changed")
        if user_stopped():
            finish("cancelled", "user_stopped")
            return None
        if paused():
            finish("paused", "user_paused")
            return None
        if (
            _unseen(observed, seen)
            or (not observed.get("loading") and snapshot.get("loading"))
            or observed.get("status_text", "") != snapshot.get("status_text", "")
        ):
            return observed
    finish("paused", "feed_waiting")
    return None


def _resume(trace, checkpoint, snapshot):
    feed = checkpoint["feed"]
    prev_doc, prev_top = feed.get("document_id"), float(feed.get("scroll_top") or 0)
    pending = bool(feed.get("pending_scroll"))
    _touch_view(checkpoint, snapshot)
    if pending:
        feed["pending_scroll"] = False
        trace("collection.resume_observed", reason="observed_after_uncertain_scroll")
    top = float(feed["scroll_top"])
    if prev_doc is not None and (prev_doc != feed["document_id"] or prev_top != top):
        trace("collection.resume_observed", reason="resume_from_current_view")


async def _drain(
    manager,
    sid,
    rid,
    plan,
    collector,
    event,
    snapshot,
    seen,
    checkpoint,
    counters,
    deadline,
    elapsed,
    saved_pass,
    user_stopped,
    paused,
    finish,
    trace,
):
    for item in _unseen(snapshot, seen):
        if item.get("url") in seen:
            continue
        if user_stopped():
            finish("cancelled", "user_stopped")
            return saved_pass
        if paused():
            finish("paused", "user_paused")
            return saved_pass
        if max(len(seen), counters["pages"]) >= 5000:
            finish("paused", "storage_budget")
            return saved_pass
        if saved_pass >= int(plan.max_items):
            finish("paused", "item_budget")
            return saved_pass
        url = item.get("url")
        if not url:
            continue
        if user_stopped():
            finish("cancelled", "user_stopped")
            return saved_pass
        try:
            record = await _bound(
                deadline,
                asyncio.to_thread(
                    classify_feed_item,
                    manager.classifier,
                    plan,
                    item.get("text") or "",
                    event,
                ),
            )
        except asyncio.CancelledError:
            raise
        except TimeoutError:
            raise
        except Exception as exc:
            if _blocked(exc) is not None:
                raise
            raise _ModelUnavailable from exc
        if item.get("truncated") or record.get("reason") == "capture_limited":
            record = dict(record)
            record["label_id"] = "needs_review"
            record["reason"] = "capture_limited"
        if user_stopped():
            finish("cancelled", "user_stopped")
            return saved_pass
        verify = await _bound(deadline, collector.read())
        if _view(verify) != _view(snapshot):
            raise _Hold("paused", "source_changed")
        payload = {
            "url": url,
            "title": item.get("title") or "",
            "text": item.get("text") or "",
            "truncated": bool(item.get("truncated")),
            "captured_at": item.get("captured_at"),
            "classification": record,
            "author": item.get("author"),
            "published_at": item.get("published_at"),
        }
        elapsed()
        staged_cp = _plain_checkpoint(checkpoint)
        staged_ct = _plain_counters(counters)
        staged_cp["feed"]["last_url"] = url
        staged_ct["pages"] += 1
        staged_ct["model_calls"] += int(record["model_calls"])
        if record["label_id"] == "needs_review":
            staged_ct["needs_review"] += 1
        else:
            staged_ct["classified"] += 1
        staged_ct["elapsed_ms"] = counters["elapsed_ms"]
        if user_stopped():
            finish("cancelled", "user_stopped")
            return saved_pass
        manager.store.commit_item(sid, rid, payload, staged_cp, staged_ct)
        _replace(checkpoint, staged_cp)
        _replace(counters, staged_ct)

        seen.add(url)
        saved_pass += 1
        trace(
            "collection.item",
            steps=counters["pages"],
            chunks=record["model_calls"],
            model=record["model"],
            inference_ms=record["inference_ms"],
            reason=record["reason"],
        )
        if paused():
            finish("paused", "user_paused")
            return saved_pass
        due = manager.review_due(sid, rid, counters)
        if due and not user_stopped():
            finish('paused', 'supervisor_review')
            manager.queue_review(sid, rid, due)
            return saved_pass
        if saved_pass >= plan.max_items:
            finish("paused", "item_budget")
            return saved_pass
    return saved_pass
