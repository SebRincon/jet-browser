from __future__ import annotations

import copy
import json
import time
import uuid

from .collection_plan import Category, CollectionPlan

_CHANGE_KEYS = frozenset(
    {
        "add_categories",
        "fields",
        "mode",
        "first_items",
        "interval_seconds",
        "share_samples",
    }
)
_FIELDS = ("url", "text", "author", "published_at", "captured_at")
_MODES = frozenset({"checkpoints", "continuous"})
_REASONS = frozenset({"first_batch", "category_drift", "interval"})
_DEFAULT_FIELDS = ["url", "text", "author", "published_at", "captured_at"]
_SAMPLE_LIMIT = 5
_REVIEW_SAMPLE_LIMIT = 3
_ITEM_LIMIT = 5000
_INTERRUPTED = "Review was interrupted. Check the sample before continuing."


def _source(run: dict) -> str:
    kind = run.get("plan", {}).get("source_kind", "website")
    if not isinstance(kind, str):
        raise ValueError("source_kind")
    return kind


def _require_run(run: dict, statuses: frozenset[str]) -> None:
    if _source(run) not in {"feed", "x_bookmarks"}:
        raise ValueError("source_kind")
    if run.get("status") not in statuses:
        raise ValueError("status")


def _mode(value: object) -> str:
    if not isinstance(value, str) or value not in _MODES:
        raise ValueError("mode")
    return value


def _fields(value: object) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(v, str) for v in value) or len(value) != len(set(value)):
        raise ValueError("fields")
    if any(not isinstance(item, str) or item not in _FIELDS for item in value):
        raise ValueError("fields")
    if "url" not in value or "text" not in value:
        raise ValueError("fields")
    return list(value)


def _pint(value: object, lo: int, hi: int, label: str) -> int:
    if type(value) is not int or not lo <= value <= hi:
        raise ValueError(label)
    return value


def _reason(value: object) -> str:
    if not isinstance(value, str) or value not in _REASONS:
        raise ValueError("reason")
    return value


def _bounded_text(value: object, limit: int, label: str) -> str:
    if not isinstance(value, str) or len(value) > limit:
        raise ValueError(label)
    return value


def _supervision(run: dict) -> dict:
    raw = run.get("supervision")
    if not isinstance(raw, dict):
        raise ValueError("supervision")
    return raw


def _pending(sup: dict) -> dict:
    pending = sup.get("pending")
    if not isinstance(pending, dict) or not isinstance(pending.get("id"), str):
        raise ValueError("pending")
    return pending


def _categories_from_plan(run: dict) -> list[dict]:
    categories = run.get("plan", {}).get("categories")
    if not isinstance(categories, list):
        raise ValueError("categories")
    return categories


def _new_categories(value: object, existing_ids: set[str]) -> list[Category]:
    if not isinstance(value, list) or not 1 <= len(value) <= 8:
        raise ValueError("add_categories")
    found: list[Category] = []
    seen = set(existing_ids)
    for item in value:
        category = Category.from_dict(item)
        if category.id in seen:
            raise ValueError("add_categories")
        seen.add(category.id)
        found.append(category)
    if len(seen) > 8:
        raise ValueError("add_categories")
    return found


def _suggestions(value: object, existing_ids: set[str]) -> list[dict[str, str]]:
    if not isinstance(value, list) or len(value) > 3:
        raise ValueError("suggested_categories")
    seen = set(existing_ids)
    out: list[dict[str, str]] = []
    for item in value:
        category = Category.from_dict(item)
        if category.id in seen:
            raise ValueError("suggested_categories")
        seen.add(category.id)
        out.append(category.to_dict())
    if len(seen) > 8:
        raise ValueError("suggested_categories")
    return out


def _fresh(counters: dict) -> dict:
    return {
        "mode": "checkpoints",
        "first_items": 10,
        "interval_seconds": 600,
        "share_samples": False,
        "fields": list(_DEFAULT_FIELDS),
        "approved": False,
        "authorized_elapsed_ms": counters["elapsed_ms"],
        "authorized_items": counters["pages"],
        "authorized_scrolls": 0,
        "last_items": counters["pages"],
        "last_review_items": counters["needs_review"],
        "last_elapsed_ms": counters["elapsed_ms"],
        "review_count": 0,
        "pending": None,
    }


def _apply_changes(run: dict, changes: dict) -> None:
    if not isinstance(changes, dict) or not changes or set(changes) - _CHANGE_KEYS:
        raise ValueError("changes")
    _require_run(run, frozenset({"prepared", "paused"}))
    existing = run.get("supervision")
    sup = _fresh(run["counters"]) if existing is None else copy.deepcopy(existing)
    if existing is None:
        sup["authorized_scrolls"] = run["checkpoint"]["feed"]["scrolls"]
    if not isinstance(sup, dict):
        raise ValueError("supervision")
    if "mode" in changes:
        sup["mode"] = _mode(changes["mode"])
    if "first_items" in changes:
        sup["first_items"] = _pint(changes["first_items"], 1, 100, "first_items")
    if "interval_seconds" in changes:
        sup["interval_seconds"] = _pint(changes["interval_seconds"], 60, 3600, "interval_seconds")
    if "share_samples" in changes:
        if type(changes["share_samples"]) is not bool:
            raise ValueError("share_samples")
        sup["share_samples"] = changes["share_samples"]
    if "fields" in changes:
        sup["fields"] = _fields(changes["fields"])
    if "add_categories" in changes:
        categories = _categories_from_plan(run)
        existing_ids = {item.get("id") for item in categories if isinstance(item, dict)}
        added = _new_categories(changes["add_categories"], {item for item in existing_ids if isinstance(item, str)})
        plan = copy.deepcopy(run["plan"])
        version = plan.get("taxonomy_version")
        if type(version) is not int:
            raise ValueError("taxonomy_version")
        plan["categories"] = list(plan["categories"]) + [item.to_dict() for item in added]
        plan["taxonomy_version"] = version + 1
        run["plan"] = CollectionPlan.from_dict(plan).to_dict()
    if sup.get("mode") not in _MODES or type(sup.get("share_samples")) is not bool:
        raise ValueError("supervision")
    run["supervision"] = sup


def _match(sup: dict, review_id: object, statuses: frozenset[str]) -> dict:
    if not isinstance(review_id, str) or not review_id:
        raise ValueError("review")
    pending = _pending(sup)
    if pending.get("id") != review_id or pending.get("status") not in statuses:
        raise ValueError("review")
    return pending


def _baseline(sup: dict, run: dict) -> None:
    counters = run["counters"]
    sup["last_items"] = counters["pages"]
    sup["last_review_items"] = counters["needs_review"]
    sup["last_elapsed_ms"] = counters["elapsed_ms"]
    sup["pending"] = None


def _clip(value: object, limit: int) -> str | None:
    if not isinstance(value, str) or value == "":
        return None
    return value[:limit]


def _published(item: dict) -> str | None:
    published = item.get("published_at")
    captured = item.get("captured_at")
    if isinstance(published, bool) or published is None or published == captured:
        return None
    if isinstance(published, str):
        return published[:80] if published != "" else None
    if isinstance(published, (int, float)) and published == published:
        return str(published)[:80]
    return None


def _truthy_text(value: object) -> bool:
    return isinstance(value, str) and value != ""


def _coverage_hit(item: dict, field: str) -> bool:
    if field in {"url", "text", "author"}:
        return _truthy_text(item.get(field))
    if field == "captured_at":
        value = item.get("captured_at")
        return not isinstance(value, bool) and bool(value)
    if field == "published_at":
        return _published(item) is not None
    return False


def _identity(item: dict, fallback: int) -> str:
    ident = item.get("id")
    if isinstance(ident, str) and ident:
        return ident
    return f"row:{fallback}"


def _label(item: dict) -> str | None:
    classification = item.get("classification")
    if not isinstance(classification, dict):
        return None
    label = classification.get("label_id")
    return label if isinstance(label, str) else None


def _when(item: dict) -> float:
    value = item.get("captured_at")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0
    return float(value)


def _select_samples(items: list[dict]) -> list[dict]:
    ranked = sorted(
        enumerate(items),
        key=lambda pair: (_when(pair[1]), _identity(pair[1], pair[0])),
        reverse=True,
    )
    chosen: list[tuple[int, dict]] = []
    seen: set[str] = set()

    def take(pair: tuple[int, dict]) -> bool:
        ident = _identity(pair[1], pair[0])
        if ident in seen:
            return False
        seen.add(ident)
        chosen.append(pair)
        return True

    for pair in ranked:
        if len(chosen) >= _REVIEW_SAMPLE_LIMIT:
            break
        if _label(pair[1]) == "needs_review":
            take(pair)
    used_labels = {_label(pair[1]) for pair in chosen}
    for pair in ranked:
        if len(chosen) >= _SAMPLE_LIMIT:
            break
        label = _label(pair[1])
        if label in used_labels:
            continue
        if take(pair):
            used_labels.add(label)
    for pair in ranked:
        if len(chosen) >= _SAMPLE_LIMIT:
            break
        take(pair)
    return [pair[1] for pair in chosen]


def _sample_row(item: dict, fields: set[str]) -> dict:
    classification = item.get("classification") if isinstance(item.get("classification"), dict) else {}
    version = classification.get("taxonomy_version")
    return {
        "url": _clip(item.get("url"), 1000) if "url" in fields else None,
        "text": _clip(item.get("text"), 400) if "text" in fields else None,
        "author": _clip(item.get("author"), 160) if "author" in fields else None,
        "published_at": _published(item) if "published_at" in fields else None,
        "category": _label(item),
        "id": item.get("id"),
        "classification_reason": classification.get("reason"),
        "truncated": bool(item.get("truncated")),
        "captured_at": item.get("captured_at") if "captured_at" in fields else None,
        "taxonomy_version": version if type(version) is int else None,
    }


def _pending_view(pending: object, remote: bool) -> dict | None:
    if pending is None:
        return None
    if not isinstance(pending, dict):
        raise ValueError("pending")
    view = {
        "id": pending.get("id"),
        "status": pending.get("status"),
        "reason": pending.get("reason"),
        "created_at": pending.get("created_at"),
    }
    if remote:
        suggestions = pending.get("suggested_categories") or []
        view["suggested_category_ids"] = [
            item.get("id") for item in suggestions if isinstance(item, dict) and isinstance(item.get("id"), str)
        ]
        return view
    view["question"] = pending.get("question") if isinstance(pending.get("question"), str) else ""
    view["summary"] = pending.get("summary") if isinstance(pending.get("summary"), str) else ""
    view["suggested_categories"] = copy.deepcopy(pending.get("suggested_categories") or [])
    return view


class CollectionSupervision:
    def __init__(self, store):
        self._store = store

    def _op(self, sid, rid, event, fn):
        def op():
            run = self._store._get(sid, rid)
            fn(run)
            self._store._emit(run, event)
            return copy.deepcopy(run)

        return self._store._tx(op)

    def configure(self, sid, rid, changes):
        def apply(run):
            _apply_changes(run, changes)

        return self._op(sid, rid, "supervision_configured", apply)

    def due(self, sid, rid, counters):
        run = self._store._get(sid, rid)
        if not isinstance(run.get("supervision"), dict):
            return None
        measured = self._store._counters(counters)
        sup = run["supervision"]
        if sup.get("pending") is not None:
            return None
        pages = measured["pages"] - sup["last_items"]
        if sup.get("approved") is not True:
            if pages >= sup["first_items"]:
                return "first_batch"
            return None
        review_delta = measured["needs_review"] - sup["last_review_items"]
        if pages >= 10 and review_delta >= 5 and (review_delta / pages) >= 0.30:
            return "category_drift"
        elapsed = measured["elapsed_ms"] - sup["last_elapsed_ms"]
        if sup.get("mode") == "checkpoints" and elapsed >= sup["interval_seconds"] * 1000:
            return "interval"
        return None

    def checkpoint(self, sid, rid, reason):
        token = _reason(reason)

        def apply(run):
            _require_run(run, frozenset({"paused"}))
            sup = _supervision(run)
            if sup.get("pending") is not None:
                return False
            count = sup.get("review_count")
            if type(count) is not int or count < 0:
                raise ValueError("review_count")
            sup["review_count"] = count + 1
            sup["pending"] = {
                "id": uuid.uuid4().hex,
                "status": "queued",
                "reason": token,
                "created_at": time.time(),
                "question": "",
                "suggested_categories": [],
                "summary": "",
            }
            return True

        def op():
            run = self._store._get(sid, rid)
            if apply(run):
                self._store._emit(run, "supervision_checkpoint")
            return copy.deepcopy(run)

        return self._store._tx(op)

    def claim(self, sid, rid, review_id):
        def apply(run):
            _require_run(run, frozenset({"paused"}))
            pending = _match(_supervision(run), review_id, frozenset({"queued"}))
            pending["status"] = "reviewing"

        return self._op(sid, rid, "supervision_reviewing", apply)

    def mark_reviewing(self, sid, rid, review_id):
        def op():
            run = self._store._get(sid, rid)
            _require_run(run, frozenset({"paused"}))
            pending = _match(_supervision(run), review_id, frozenset({"queued", "reviewing"}))
            changed = pending.get("status") != "reviewing"
            pending["status"] = "reviewing"
            if changed:
                self._store._emit(run, "supervision_reviewing")
            return copy.deepcopy(run)

        return self._store._tx(op)

    def finish_review(self, sid, rid, review_id, summary, question="", suggested_categories=None):
        text = _bounded_text(summary, 1000, "summary")
        prompt = _bounded_text(question, 500, "question")
        ideas = [] if suggested_categories is None else suggested_categories

        def apply(run):
            _require_run(run, frozenset({"paused"}))
            sup = _supervision(run)
            pending = _match(sup, review_id, frozenset({"queued", "reviewing"}))
            existing = {item.get("id") for item in _categories_from_plan(run) if isinstance(item, dict)}
            pending["suggested_categories"] = _suggestions(ideas, {item for item in existing if isinstance(item, str)})
            pending["summary"] = text
            pending["question"] = prompt
            pending["status"] = "awaiting_user"

        return self._op(sid, rid, "supervision_awaiting_user", apply)

    def recover(self):
        rows = self._store._conn.execute("SELECT id, session_id FROM runs").fetchall()
        changed = []
        for row in rows:

            def op(session_id=row["session_id"], run_id=row["id"]):
                run = self._store._get(session_id, run_id)
                raw = run.get("supervision")
                if not isinstance(raw, dict):
                    return None
                pending = raw.get("pending")
                if not isinstance(pending, dict) or pending.get("status") not in {"queued", "reviewing"}:
                    return None
                pending["status"] = "awaiting_user"
                pending["question"] = _INTERRUPTED
                self._store._emit(run, "supervision_recovered")
                return copy.deepcopy(run)

            result = self._store._tx(op)
            if result is not None:
                changed.append(result)
        return changed

    def approve(self, sid, rid, review_id, mode=None):
        selected = None if mode is None else _mode(mode)

        def apply(run):
            _require_run(run, frozenset({"paused"}))
            sup = _supervision(run)
            _match(sup, review_id, frozenset({"awaiting_user"}))
            if selected is not None:
                sup["mode"] = selected
            sup["approved"] = True
            sup["authorized_elapsed_ms"] = run["counters"]["elapsed_ms"]
            sup["authorized_items"] = run["counters"]["pages"]
            sup["authorized_scrolls"] = run["checkpoint"]["feed"]["scrolls"]
            _baseline(sup, run)

        return self._op(sid, rid, "supervision_approved", apply)

    def accept(self, sid, rid, review_id):
        def apply(run):
            _require_run(run, frozenset({"paused"}))
            sup = _supervision(run)
            if sup.get("approved") is not True:
                raise ValueError("review")
            pending = _match(sup, review_id, frozenset({"queued", "reviewing"}))
            if pending.get("reason") != "interval":
                raise ValueError("reason")
            _baseline(sup, run)

        return self._op(sid, rid, "supervision_accepted", apply)

    def packet(self, sid, rid, remote=False):
        if type(remote) is not bool:
            raise ValueError("remote")

        def op():
            run = self._store._get(sid, rid)
            sup = _supervision(run)
            fields = _fields(sup.get("fields"))
            plan = run["plan"]
            categories = plan.get("categories") if isinstance(plan.get("categories"), list) else []
            counts = {}
            for category in categories:
                if isinstance(category, dict) and isinstance(category.get("id"), str):
                    counts[category["id"]] = 0
            counts["needs_review"] = 0
            coverage = {field: 0 for field in fields}
            rows = self._store._conn.execute(
                "SELECT payload FROM items WHERE run_id=? ORDER BY rowid LIMIT ?",
                (run["id"], _ITEM_LIMIT),
            ).fetchall()
            items = []
            review_reasons = {}
            for row in rows:
                item = json.loads(row["payload"])
                if not isinstance(item, dict):
                    continue
                items.append(item)
                label = _label(item)
                if label == "needs_review":
                    reason = (item.get("classification") or {}).get("reason") or "needs_review"
                    review_reasons[reason] = review_reasons.get(reason, 0) + 1
                if label in counts:
                    counts[label] += 1
                for field in fields:
                    if _coverage_hit(item, field):
                        coverage[field] += 1
            share = sup.get("share_samples") is True
            include = (not remote) or (share and sup.get("pending") is not None)
            if remote and include:
                notice = (
                    "Remote packet includes bounded content samples because share_samples is enabled. "
                    "Samples are truncated, capped at 5, and are not the collection request."
                )
            elif remote:
                notice = (
                    "Remote packet omits content samples unless sharing is enabled and a checkpoint is pending. "
                    "No collection request or raw item text is included."
                )
            else:
                notice = "Local packet includes bounded content samples for operator review."
            field_set = set(fields)
            samples = [_sample_row(item, field_set) for item in _select_samples(items)] if include else []
            taxonomy = []
            for category in categories:
                if isinstance(category, dict) and isinstance(category.get("id"), str):
                    name = category.get("name") if isinstance(category.get("name"), str) else ""
                    taxonomy.append({"id": category["id"], "name": name[:80]})
            return {
                "remote": remote,
                "notice": notice,
                "mode": sup.get("mode"),
                "categories": copy.deepcopy(categories),
                "interval_seconds": sup["interval_seconds"],
                "fields": fields,
                "counters": copy.deepcopy(run.get("counters")),
                "taxonomy": {"version": plan.get("taxonomy_version"), "categories": taxonomy},
                "revision": plan.get("classifier_revision"),
                "counts": counts,
                "coverage": coverage,
                "review_reasons": review_reasons,
                "pending": _pending_view(sup.get("pending"), remote),
                "samples": samples,
            }

        return self._store._tx(op)
