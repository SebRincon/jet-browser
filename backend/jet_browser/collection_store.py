import copy
import hashlib
import json
import math
import os
import sqlite3
import stat
import time
import uuid

from .collection_plan import CollectionPlan, canonical_url

_STATUSES = frozenset(
    {
        "prepared",
        "running",
        "pausing",
        "paused",
        "completed",
        "partial",
        "failed",
        "cancelled",
    }
)
_COUNTER_KEYS = ("pages", "classified", "needs_review", "model_calls", "elapsed_ms")
_CLASS_KEYS = (
    "label_id",
    "taxonomy_version",
    "classifier_revision",
    "model",
    "confidence",
    "inference_ms",
    "reason",
    "excerpt_chars",
    "model_calls",
)
_ITEM_KEYS = ("url", "title", "text", "captured_at", "truncated", "classification")
_CHECKPOINT_KEYS = ("frontier", "visited", "pending_url")


def _dumps(value):
    if not isinstance(value, dict):
        raise ValueError("expected object")
    try:
        text = json.dumps(value, allow_nan=False, separators=(",", ":"), sort_keys=True)
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid json") from exc
    if not isinstance(json.loads(text), dict):
        raise ValueError("invalid json")
    return text


def _loads(text):
    try:
        value = json.loads(text)
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid json") from exc
    if not isinstance(value, dict):
        raise ValueError("invalid json")
    return value


def _exact(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValueError("invalid shape")
    return value


def _ident(value, limit, optional=False):
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value.strip() or value != value.strip() or len(value) > limit:
        raise ValueError("invalid id")
    return value


def _int(value, lo, hi):
    if type(value) is not int or value < lo or value > hi:
        raise ValueError("invalid integer")
    return value


def _num(value, lo, hi=None):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("invalid number")
    if value < lo or (hi is not None and value > hi):
        raise ValueError("invalid number")
    return value


def _reason(value):
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 400:
        raise ValueError("invalid reason")
    return value


def _http(url):
    if not isinstance(url, str) or not url or len(url) > 6000:
        raise ValueError("invalid url")
    canon = canonical_url(url)
    if not isinstance(canon, str) or not (canon.startswith("http://") or canon.startswith("https://")):
        raise ValueError("invalid url")
    return canon


class CollectionStore:
    def __init__(self, root):
        root = os.fspath(root)
        runtime = os.path.join(root, ".runtime")
        if os.path.islink(root) or os.path.islink(runtime):
            raise ValueError("symlink rejected")
        os.makedirs(runtime, mode=0o700, exist_ok=True)
        if os.path.islink(runtime) or not os.path.isdir(runtime):
            raise ValueError("symlink rejected")
        os.chmod(runtime, 0o700)
        path = os.path.join(runtime, "collections.sqlite3")
        if os.path.islink(path):
            raise ValueError("symlink rejected")
        if not os.path.exists(path):
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
            os.close(fd)
        if os.path.islink(path):
            raise ValueError("symlink rejected")
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("invalid database")
        os.chmod(path, 0o600)
        self._conn = sqlite3.connect(path, isolation_level=None)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.execute("PRAGMA journal_mode=DELETE")
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                created_at REAL NOT NULL, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS items (
                run_id TEXT NOT NULL REFERENCES runs(id), source_url TEXT NOT NULL,
                content_hash TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
                UNIQUE(run_id, source_url, content_hash));
            CREATE TABLE IF NOT EXISTS events (
                run_id TEXT NOT NULL REFERENCES runs(id), seq INTEGER NOT NULL,
                payload TEXT NOT NULL, UNIQUE(run_id, seq));
            """
        )

    def close(self):
        self._conn.close()

    def _tx(self, fn):
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            result = fn()
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise
        return result

    def _plan(self, run):
        return CollectionPlan.from_dict(run["plan"])

    def _get(self, session_id, run_id):
        _ident(session_id, 200)
        _ident(run_id, 200)
        row = self._conn.execute(
            "SELECT payload FROM runs WHERE id=? AND session_id=?", (run_id, session_id)
        ).fetchone()
        if row is None:
            raise ValueError("Unknown collection")
        run = _loads(row["payload"])
        if run.get("id") != run_id or run.get("session_id") != session_id:
            raise ValueError("Unknown collection")
        self._plan(run)
        return run

    def _urls(self, values, plan, limit):
        if not isinstance(values, list) or len(values) > limit:
            raise ValueError("invalid urls")
        out = []
        for value in values:
            canon = _http(value)
            if not plan.in_scope(canon):
                raise ValueError("url out of scope")
            out.append(canon)
        return out

    def _checkpoint(self, value, plan):
        if plan.source_kind != "website":
            raw = _exact(value, _CHECKPOINT_KEYS + ("feed",))
        else:
            raw = _exact(value, _CHECKPOINT_KEYS)
        pending = raw["pending_url"]
        if pending is not None:
            pending = _http(pending)
            if not plan.in_scope(pending):
                raise ValueError("url out of scope")
        checkpoint = {
            "frontier": self._urls(raw["frontier"], plan, 500),
            "visited": self._urls(raw["visited"], plan, 50),
            "pending_url": pending,
        }
        if plan.source_kind == "website":
            return checkpoint
        feed = _exact(raw["feed"], ("last_url", "document_id", "scroll_top", "scrolls", "stalls", "pending_scroll"))
        last_url = feed["last_url"]
        if last_url is not None:
            last_url = _http(last_url)
            if not plan.item_in_scope(last_url):
                raise ValueError("url out of scope")
        document_id = feed["document_id"]
        if document_id is not None and (not isinstance(document_id, str) or len(document_id) > 200):
            raise ValueError("invalid id")
        pending_scroll = feed["pending_scroll"]
        if type(pending_scroll) is not bool:
            raise ValueError("invalid shape")
        checkpoint["feed"] = {
            "last_url": last_url,
            "document_id": document_id,
            "scroll_top": _num(feed["scroll_top"], 0),
            "scrolls": _int(feed["scrolls"], 0, 10**12),
            "stalls": _int(feed["stalls"], 0, 10**12),
            "pending_scroll": pending_scroll,
        }
        return checkpoint

    def _counters(self, value):
        raw = _exact(value, _COUNTER_KEYS)
        out = {}
        for key in _COUNTER_KEYS:
            if key == "elapsed_ms":
                number = _num(raw[key], 0)
                out[key] = number
            else:
                out[key] = _int(raw[key], 0, 10**12)
        return out

    def _emit(self, run, event_type):
        run["updated_at"] = time.time()
        run["event_seq"] = _int(run["event_seq"], 0, 10**12) + 1
        event = {
            "seq": run["event_seq"],
            "run_id": run["id"],
            "turn_id": run.get("turn_id"),
            "at": run["updated_at"],
            "type": event_type,
            "status": run["status"],
            "reason": run["reason"],
        }
        self._conn.execute("UPDATE runs SET payload=? WHERE id=?", (_dumps(run), run["id"]))
        self._conn.execute(
            "INSERT INTO events(run_id, seq, payload) VALUES (?,?,?)",
            (run["id"], run["event_seq"], _dumps(event)),
        )

    def _apply(self, run, changes, event_type):
        if not changes or set(changes) - {"status", "reason", "checkpoint", "counters"}:
            raise ValueError("invalid changes")
        plan = self._plan(run)
        if "status" in changes:
            if not isinstance(changes["status"], str) or changes["status"] not in _STATUSES:
                raise ValueError("invalid status")
            run["status"] = changes["status"]
        if "reason" in changes:
            run["reason"] = _reason(changes["reason"])
        if "checkpoint" in changes:
            run["checkpoint"] = self._checkpoint(changes["checkpoint"], plan)
        if "counters" in changes:
            run["counters"] = self._counters(changes["counters"])
        run["checkpoint"] = self._checkpoint(run["checkpoint"], plan)
        _exact(run["counters"], _COUNTER_KEYS)
        self._emit(run, event_type)
        return run

    def create(self, session_id, turn_id, plan):
        session_id = _ident(session_id, 200)
        turn_id = _ident(turn_id, 200, optional=True)
        plan = CollectionPlan.from_dict(plan.to_dict())
        now = time.time()
        start = _http(plan.start_url)
        if not plan.in_scope(start):
            raise ValueError("url out of scope")
        run = {
            "id": uuid.uuid4().hex,
            "session_id": session_id,
            "turn_id": turn_id,
            "created_at": now,
            "updated_at": now,
            "status": "prepared",
            "reason": None,
            "plan": plan.to_dict(),
            "event_seq": 0,
            "checkpoint": (
                {
                    "frontier": [],
                    "visited": [],
                    "pending_url": None,
                    "feed": {
                        "last_url": None,
                        "document_id": None,
                        "scroll_top": 0,
                        "scrolls": 0,
                        "stalls": 0,
                        "pending_scroll": False,
                    },
                }
                if plan.source_kind != "website"
                else {"frontier": [start], "visited": [], "pending_url": None}
            ),
            "counters": {"pages": 0, "classified": 0, "needs_review": 0, "model_calls": 0, "elapsed_ms": 0},
        }

        def op():
            self._conn.execute(
                "INSERT INTO runs(id, session_id, created_at, payload) VALUES (?,?,?,?)",
                (run["id"], session_id, now, _dumps(run)),
            )
            return copy.deepcopy(self._apply(run, {"status": "prepared"}, "prepared"))

        return self._tx(op)

    def get(self, session_id, run_id):
        return copy.deepcopy(self._get(session_id, run_id))

    def seen_urls(self, session_id, run_id):
        run = self._get(session_id, run_id)
        rows = self._conn.execute("SELECT source_url FROM items WHERE run_id=?", (run["id"],)).fetchall()
        return {row["source_url"] for row in rows}

    def list(self, session_id):
        _ident(session_id, 200)
        rows = self._conn.execute(
            "SELECT payload FROM runs WHERE session_id=? ORDER BY created_at DESC, id DESC LIMIT 100",
            (session_id,),
        ).fetchall()
        out = []
        for row in rows:
            run = _loads(row["payload"])
            if run.get("session_id") != session_id:
                raise ValueError("Unknown collection")
            self._plan(run)
            out.append(copy.deepcopy(run))
        return out

    def update(self, session_id, run_id, **changes):
        def op():
            run = self._get(session_id, run_id)
            event_type = changes["status"] if "status" in changes else "updated"
            return copy.deepcopy(self._apply(run, changes, event_type))

        return self._tx(op)

    def configure_limits(self, session_id, run_id, limits):
        if not isinstance(limits, dict) or not limits or set(limits) - {"max_seconds", "max_items", "max_scrolls"}:
            raise ValueError("invalid limits")

        def op():
            run = self._get(session_id, run_id)
            plan = self._plan(run)
            if plan.source_kind == "website" or run["status"] not in {"prepared", "paused"}:
                raise ValueError("invalid limits")
            plan_dict = dict(run["plan"])
            plan_dict.update(limits)
            run["plan"] = CollectionPlan.from_dict(plan_dict).to_dict()
            self._emit(run, "policy_updated")
            return copy.deepcopy(run)

        return self._tx(op)

    def _classification(self, value, plan, text):
        raw = _exact(value, _CLASS_KEYS)
        labels = {cat.id for cat in plan.categories}
        labels.add("needs_review")
        if not isinstance(raw["label_id"], str) or raw["label_id"] not in labels:
            raise ValueError("invalid label")
        if (
            type(raw["taxonomy_version"]) is not int
            or raw["taxonomy_version"] != plan.taxonomy_version
            or raw["classifier_revision"] != plan.classifier_revision
        ):
            raise ValueError("invalid classifier")
        model = raw["model"]
        if not isinstance(model, str) or not model.strip() or len(model) > 300:
            raise ValueError("invalid model")
        confidence = raw["confidence"]
        if confidence is not None:
            _num(confidence, 0, 1)
        _num(raw["inference_ms"], 0)
        _reason(raw["reason"])
        _int(raw["excerpt_chars"], 0, len(text))
        _int(raw["model_calls"], 0, 6 if plan.source_kind != "website" else 1)
        return dict(raw)

    def commit_item(self, session_id, run_id, item, checkpoint, counters):
        if not isinstance(item, dict) or set(item) - set(_ITEM_KEYS) - {'author', 'published_at'}:
            raise ValueError('invalid item')
        raw = _exact({k: v for k, v in item.items() if k in _ITEM_KEYS}, _ITEM_KEYS)
        metadata = {}
        for key, limit in [('author', 160), ('published_at', 80)]:
            value = item.get(key)
            if value is not None and (not isinstance(value, str) or len(value) > limit):
                raise ValueError('invalid item metadata')
            metadata[key] = value or None
        title, text = raw["title"], raw["text"]
        if not isinstance(title, str) or len(title) > 500 or not isinstance(text, str) or len(text) > 20000:
            raise ValueError("invalid item")
        if type(raw["truncated"]) is not bool:
            raise ValueError("invalid item")
        _num(raw["captured_at"], 0)

        def op():
            run = self._get(session_id, run_id)
            plan = self._plan(run)
            url = _http(raw["url"])
            if not plan.item_in_scope(url):
                raise ValueError("url out of scope")
            if plan.source_kind != "website":
                found = self._conn.execute(
                    "SELECT payload FROM items WHERE run_id=? AND source_url=? ORDER BY rowid LIMIT 1",
                    (run["id"], url),
                ).fetchone()
                if found is not None:
                    return copy.deepcopy(_loads(found["payload"]))
            classification = self._classification(raw["classification"], plan, text)
            content_hash = hashlib.sha256(text.encode()).hexdigest()
            item_id = hashlib.sha256((url + "\0" + content_hash).encode()).hexdigest()
            record = {
                "id": item_id,
                "url": url,
                "source_url": url,
                "content_hash": content_hash,
                "title": title,
                "text": text,
                "captured_at": raw["captured_at"],
                "truncated": raw["truncated"],
                "classification": classification,
                **metadata,
            }
            try:
                self._conn.execute(
                    "INSERT INTO items(run_id, source_url, content_hash, id, payload) VALUES (?,?,?,?,?)",
                    (run["id"], url, content_hash, item_id, _dumps(record)),
                )
                stored = record
            except sqlite3.IntegrityError:
                found = self._conn.execute(
                    "SELECT payload FROM items WHERE run_id=? AND source_url=? AND content_hash=?",
                    (run["id"], url, content_hash),
                ).fetchone()
                if found is None:
                    raise
                stored = _loads(found["payload"])
            self._apply(run, {"checkpoint": checkpoint, "counters": counters}, "item")
            return copy.deepcopy(stored)

        return self._tx(op)

    def item(self, session_id, run_id, item_id):
        run = self._get(session_id, run_id)
        row = self._conn.execute("SELECT payload FROM items WHERE run_id=? AND id=?", (run["id"], item_id)).fetchone()
        if row is None:
            raise ValueError("Unknown collection item")
        return copy.deepcopy(_loads(row["payload"]))

    def repair_item(self, session_id, run_id, item_id, observed, classification, *, expected_hash):
        """Replace verified evidence atomically, retaining the first capture and stable identity."""
        def op():
            run = self._get(session_id, run_id)
            if run["status"] != "paused":
                raise ValueError("Pause the collection before repair")
            before = self.item(session_id, run_id, item_id)
            if before["content_hash"] != expected_hash or observed.get("url") != before["url"]:
                raise ValueError("Collection evidence changed")
            text = observed.get("text")
            if not isinstance(text, str) or not text.strip() or len(text) > 20000 or type(observed.get("truncated")) is not bool:
                raise ValueError("Invalid recovered evidence")
            label = self._classification(classification, self._plan(run), text)
            after = copy.deepcopy(before)
            after.setdefault("original_capture", {k: before.get(k) for k in ("text", "content_hash", "truncated", "classification", "author", "published_at", "captured_at")})
            after.update(text=text, truncated=observed["truncated"], classification=label,
                         content_hash=hashlib.sha256(text.encode()).hexdigest())
            for key, limit in (("author",160),("published_at",80)):
                value = observed.get(key)
                if value is not None and (not isinstance(value,str) or len(value)>limit):
                    raise ValueError("Invalid recovered metadata")
                if value:
                    after[key] = value
            after["recovery"] = {"method":"detail_tab", "observed_at":time.time(),
                                 "previous_hash":before["content_hash"], "added_chars":len(text)-len(before["text"])}
            counts = dict(run["counters"])
            old_review = before["classification"]["label_id"] == "needs_review"
            new_review = label["label_id"] == "needs_review"
            counts["needs_review"] += int(new_review)-int(old_review)
            counts["classified"] += int(old_review)-int(new_review)
            counts["model_calls"] += label["model_calls"]
            self._conn.execute("UPDATE items SET content_hash=?, payload=? WHERE run_id=? AND id=?",
                               (after["content_hash"], _dumps(after),run_id,item_id))
            run["counters"] = self._counters(counts)
            self._emit(run,"item_recovered")
            return copy.deepcopy(after)
        return self._tx(op)

    def items(self, session_id, run_id, offset=0, limit=50, query="", category=""):
        offset, limit = _int(offset, 0, 10000), _int(limit, 1, 100)
        if not isinstance(query, str) or len(query) > 200 or not isinstance(category, str):
            raise ValueError("invalid query")
        run = self._get(session_id, run_id)
        labels = {cat.id for cat in self._plan(run).categories}
        labels.add("needs_review")
        if category and category not in labels:
            raise ValueError("invalid category")
        rows = self._conn.execute("SELECT payload FROM items WHERE run_id=?", (run["id"],)).fetchall()
        needle = query.casefold()
        matched = []
        for row in rows:
            record = _loads(row["payload"])
            label = record.get("classification", {}).get("label_id")
            if category and label != category:
                continue
            if (
                needle
                and needle not in str(record.get("title", "")).casefold()
                and needle not in str(record.get("text", "")).casefold()
            ):
                continue
            matched.append(record)
        matched.sort(key=lambda record: (record.get("captured_at", 0), record.get("id", "")))
        total = len(matched)
        page = [copy.deepcopy(record) for record in matched[offset : offset + limit]]
        return {"items": page, "total": total, "offset": offset, "limit": limit}

    def events(self, session_id, run_id, after=0, limit=100):
        after, limit = _int(after, 0, 10**12), _int(limit, 1, 100)
        run = self._get(session_id, run_id)
        rows = self._conn.execute(
            "SELECT payload FROM events WHERE run_id=? AND seq>? ORDER BY seq LIMIT ?",
            (run["id"], after, limit),
        ).fetchall()
        return [copy.deepcopy(_loads(row["payload"])) for row in rows]

    def recover_interrupted(self):
        rows = self._conn.execute("SELECT id, session_id, payload FROM runs").fetchall()
        paused = []
        for row in rows:
            peek = _loads(row["payload"])
            if peek.get("status") not in ("running", "pausing"):
                continue

            def op(session_id=row["session_id"], run_id=row["id"]):
                run = self._get(session_id, run_id)
                if run["status"] not in ("running", "pausing"):
                    return None
                return copy.deepcopy(self._apply(run, {"status": "paused", "reason": "service_restarted"}, "paused"))

            result = self._tx(op)
            if result is not None:
                paused.append(result)
        return paused
