"""Session-scoped workflow revisions and audited records.

Definitions are user-authorized scripts for a separate JavaScriptCore process.
This module only persists them. It does not execute JavaScript or touch page state.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlsplit

CAPABILITIES = (
    "feed.observe",
    "feed.scroll",
    "post.recover",
    "model.decide",
    "model.classify",
    "model.summarize",
    "records.put",
    "records.list",
    "records.patch",
    "run.checkpoint",
    "run.progress",
)
LOCAL_MODELS = ("lfm_rlcd", "qwen4b_semif_shared", "laya_mlx", "laya_typed")

_SID = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
_CAT = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
_SHA = re.compile(r"^[0-9a-f]{64}$")
_WID = re.compile(r"^[0-9a-f]{32}$")
_DEF_KEYS = ("title", "source", "tab_id", "start_url", "source_kind", "model", "categories", "capabilities", "limits")
_LIMITS = {"max_seconds": (1, 14400), "max_calls": (1, 10000), "max_items": (1, 5000)}
_COUNTERS = ("calls", "saved", "classified", "scrolls", "elapsed_ms")
_RECORD_KEYS = ("id", "url", "text", "author", "published_at", "captured_at", "truncated", "tags", "summary")
_UPDATE_KEYS = {"status", "counters", "checkpoint", "error", "last_result", "run_id", "authorized_revision"}
_STATUSES = {"prepared", "running", "paused", "completed", "cancelled", "failed"}
_IMMUTABLE = ("tab_id", "start_url", "source_kind", "model")
_ROW_MAX = 200 * 1024
_BLOB_MAX = 32 * 1024
_RECORD_CAP = 5000
_AUDIT_MAX = 30


def _fail(label):
    raise ValueError(label)


def _dumps(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))


def _json_text(value, limit, label):
    try:
        raw = _dumps(value)
    except (TypeError, ValueError):
        _fail(label)
    if len(raw.encode("utf-8")) > limit:
        _fail(label)
    return raw


def _sid(sid):
    if not isinstance(sid, str) or not _SID.fullmatch(sid):
        _fail("session id")


def _wid(wid):
    if not isinstance(wid, str) or not _WID.fullmatch(wid):
        _fail("workflow id")


def _int(value, label):
    if type(value) is not int:
        _fail(label)
    return value


def _finite(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        _fail(label)
    return value


def _text(value, lo, hi, label):
    if not isinstance(value, str) or not (lo <= len(value) <= hi):
        _fail(label)
    return value


def _http_url(value, limit, label="url"):
    if not isinstance(value, str) or not (1 <= len(value) <= limit) or any(ch.isspace() for ch in value):
        _fail(label)
    parts = urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.netloc or not parts.hostname:
        _fail(label)
    if parts.username is not None or parts.password is not None:
        _fail(label)
    return value


def _categories(value):
    if not isinstance(value, list) or not (1 <= len(value) <= 16):
        _fail("categories")
    out, seen = [], set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {"id", "name", "description"}:
            _fail("categories")
        cid = item["id"]
        if not isinstance(cid, str) or not _CAT.fullmatch(cid) or cid in seen:
            _fail("categories")
        seen.add(cid)
        out.append({"id": cid, "name": _text(item["name"], 1, 80, "categories"), "description": _text(item["description"], 1, 400, "categories")})
    return out


def _definition(value):
    if not isinstance(value, dict) or set(value) != set(_DEF_KEYS):
        _fail("definition")
    source = value["source"]
    if not isinstance(source, str) or not (1 <= len(source.encode("utf-8")) <= 32000):
        _fail("source")
    caps = value["capabilities"]
    if not isinstance(caps, list) or not caps or any(not isinstance(c, str) or c not in CAPABILITIES for c in caps) or len(caps) != len(set(caps)):
        _fail("capabilities")
    limits = value["limits"]
    if not isinstance(limits, dict) or set(limits) != set(_LIMITS):
        _fail("limits")
    clean_limits = {}
    for key, (lo, hi) in _LIMITS.items():
        num = _int(limits[key], "limits")
        if not lo <= num <= hi:
            _fail("limits")
        clean_limits[key] = num
    kind = value["source_kind"]
    model = value["model"]
    if kind not in ("feed", "x_bookmarks") or model not in LOCAL_MODELS:
        _fail("definition")
    return {
        "title": _text(value["title"], 1, 120, "title"),
        "source": source,
        "tab_id": _text(value["tab_id"], 1, 200, "tab_id"),
        "start_url": _http_url(value["start_url"], 6000, "start_url"),
        "source_kind": kind,
        "model": model,
        "categories": _categories(value["categories"]),
        "capabilities": list(caps),
        "limits": clean_limits,
    }


def _scope(old, new):
    for key in _IMMUTABLE:
        if old[key] != new[key]:
            _fail(key + " is immutable")
    for key in _LIMITS:
        if new["limits"][key] > old["limits"][key]:
            _fail(key + " cannot increase")


def _counters(value):
    if not isinstance(value, dict) or set(value) != set(_COUNTERS):
        _fail("counters")
    out = {}
    for key in _COUNTERS:
        num = _finite(value[key], "counters")
        if num < 0:
            _fail("counters")
        out[key] = num
    return out


def _tags(value, allowed):
    if not isinstance(value, list) or len(value) > 16 or any(not isinstance(tag, str) for tag in value) or len(value) != len(set(value)):
        _fail("tags")
    for tag in value:
        if not isinstance(tag, str) or tag not in allowed:
            _fail("tags")
    return list(value)


def _summary(value):
    if not isinstance(value, str) or len(value) > 1000:
        _fail("summary")
    return value


def _nullable(value, limit, label):
    if value is None:
        return None
    return _text(value, 0, limit, label)


def _record_in(value, allowed):
    if not isinstance(value, dict) or set(value) != set(_RECORD_KEYS):
        _fail("record")
    text = value["text"]
    if not isinstance(text, str) or len(text) > 20000:
        _fail("text")
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        _fail("text")
    if type(value["truncated"]) is not bool:
        _fail("truncated")
    item = value["id"]
    if not isinstance(item, str) or not _SHA.fullmatch(item):
        _fail("record id")
    return {
        "id": item,
        "url": _http_url(value["url"], 6000),
        "text": text,
        "author": _nullable(value["author"], 160, "author"),
        "published_at": _nullable(value["published_at"], 80, "published_at"),
        "captured_at": _finite(value["captured_at"], "captured_at"),
        "truncated": value["truncated"],
        "tags": _tags(value["tags"], allowed),
        "summary": _summary(value["summary"]),
    }


def _audit(actor, record, kind):
    entry = {
        "timestamp": time.time(),
        "actor": actor,
        "previous_tags": list(record["tags"]),
        "previous_summary": record["summary"],
        "previous_revision": record["revision"],
    }
    if kind:
        entry["kind"] = kind
    return entry


class WorkflowStore:
    def __init__(self, root):
        self.root = Path(root)
        self._lock = threading.RLock()
        runtime = self.root / ".runtime"
        runtime.mkdir(parents=True, exist_ok=True)
        os.chmod(runtime, 0o700)
        self.path = runtime / "workflows.sqlite3"
        self._conn = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self._conn.row_factory = sqlite3.Row
        os.chmod(self.path, 0o600)
        self._conn.execute("PRAGMA journal_mode=DELETE")
        with self._lock:
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS workflows ("
                "session_id TEXT NOT NULL, workflow_id TEXT NOT NULL, revision INTEGER NOT NULL, "
                "status TEXT NOT NULL, definition TEXT NOT NULL, counters TEXT NOT NULL, checkpoint TEXT NOT NULL, "
                "error TEXT, last_result TEXT, run_id TEXT, authorized_revision INTEGER, "
                "created_at REAL NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY (session_id, workflow_id))"
            )
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS workflow_versions ("
                "session_id TEXT NOT NULL, workflow_id TEXT NOT NULL, revision INTEGER NOT NULL, "
                "definition TEXT NOT NULL, saved_at REAL NOT NULL, PRIMARY KEY (session_id, workflow_id, revision))"
            )
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS records ("
                "session_id TEXT NOT NULL, workflow_id TEXT NOT NULL, item_id TEXT NOT NULL, "
                "position INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (session_id, workflow_id, item_id))"
            )
            self._conn.execute(
                "UPDATE workflows SET status='paused', error=?, updated_at=? WHERE status='running'",
                ("Service restarted; resume explicitly", time.time()),
            )

    def claim_review(self, sid, wid, run_id):
        """Persist a one-time review claim and cumulative remote-review ceiling."""
        _sid(sid)
        _wid(wid)
        with self._tx() as conn:
            self._row(conn, sid, wid)
            conn.execute('CREATE TABLE IF NOT EXISTS workflow_reviews(session_id TEXT, workflow_id TEXT, run_id TEXT, PRIMARY KEY(session_id,workflow_id,run_id))')
            if conn.execute('SELECT COUNT(*) FROM workflow_reviews WHERE session_id=? AND workflow_id=?', (sid,wid)).fetchone()[0] >= 100:
                _fail('review_limit')
            return conn.execute('INSERT OR IGNORE INTO workflow_reviews VALUES(?,?,?)', (sid,wid,run_id)).rowcount == 1

    def close(self):
        with self._lock:
            self._conn.close()

    @contextmanager
    def _tx(self):
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                yield self._conn
                self._conn.commit()
            except BaseException:
                self._conn.rollback()
                raise

    def _row(self, conn, sid, wid):
        row = conn.execute("SELECT * FROM workflows WHERE session_id=? AND workflow_id=?", (sid, wid)).fetchone()
        if row is None:
            _fail("unknown workflow")
        return row

    def _obj(self, row):
        return {
            "id": row["workflow_id"],
            "session_id": row["session_id"],
            "revision": row["revision"],
            "status": row["status"],
            "definition": json.loads(row["definition"]),
            "counters": json.loads(row["counters"]),
            "checkpoint": json.loads(row["checkpoint"]),
            "error": row["error"],
            "last_result": None if row["last_result"] is None else json.loads(row["last_result"]),
            "run_id": row["run_id"],
            "authorized_revision": row["authorized_revision"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def _insert(self, conn, sid, wid, definition, now):
        counters = {key: 0 for key in _COUNTERS}
        obj_json = _json_text({"definition": definition, "counters": counters, "checkpoint": {}}, _ROW_MAX, "workflow")
        del obj_json
        conn.execute(
            "INSERT INTO workflows (session_id, workflow_id, revision, status, definition, counters, checkpoint, "
            "error, last_result, run_id, authorized_revision, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (sid, wid, 1, "prepared", _dumps(definition), _dumps(counters), _dumps({}), None, None, None, None, now, now),
        )
        conn.execute(
            "INSERT INTO workflow_versions (session_id, workflow_id, revision, definition, saved_at) VALUES (?,?,?,?,?)",
            (sid, wid, 1, _dumps(definition), now),
        )

    def save(self, sid, definition, workflow_id=None, expected_revision=None):
        _sid(sid)
        definition = _definition(definition)
        now = time.time()
        with self._tx() as conn:
            if workflow_id is None:
                if expected_revision is not None:
                    _fail("expected_revision")
                if conn.execute("SELECT COUNT(*) FROM workflows WHERE session_id=?", (sid,)).fetchone()[0] >= 500:
                    _fail("workflow cap")
                wid = uuid.uuid4().hex
                self._insert(conn, sid, wid, definition, now)
                return self._obj(self._row(conn, sid, wid))
            _wid(workflow_id)
            _int(expected_revision, "expected_revision")
            row = self._row(conn, sid, workflow_id)
            if row["revision"] != expected_revision:
                _fail("revision conflict")
            if row["status"] == "running":
                _fail("workflow is running")
            _scope(json.loads(row["definition"]), definition)
            if row["revision"] >= 500:
                _fail("revision cap")
            rev = row["revision"] + 1
            conn.execute(
                "UPDATE workflows SET revision=?, status='paused', definition=?, updated_at=? WHERE session_id=? AND workflow_id=?",
                (rev, _dumps(definition), now, sid, workflow_id),
            )
            conn.execute(
                "INSERT INTO workflow_versions (session_id, workflow_id, revision, definition, saved_at) VALUES (?,?,?,?,?)",
                (sid, workflow_id, rev, _dumps(definition), now),
            )
            return self._obj(self._row(conn, sid, workflow_id))

    def get(self, sid, wid):
        _sid(sid)
        _wid(wid)
        with self._lock:
            return self._obj(self._row(self._conn, sid, wid))

    def list(self, sid):
        _sid(sid)
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM workflows WHERE session_id=? ORDER BY updated_at DESC, workflow_id ASC LIMIT 20", (sid,)
            ).fetchall()
        return [self._obj(row) for row in rows]

    def version(self, sid, wid, revision):
        _sid(sid)
        _wid(wid)
        _int(revision, "revision")
        if revision < 1:
            _fail("revision")
        with self._lock:
            self._row(self._conn, sid, wid)
            row = self._conn.execute(
                "SELECT definition FROM workflow_versions WHERE session_id=? AND workflow_id=? AND revision=?",
                (sid, wid, revision),
            ).fetchone()
        if row is None:
            _fail("unknown revision")
        return json.loads(row["definition"])

    def update(self, sid, wid, **fields):
        _sid(sid)
        _wid(wid)
        if not fields or not set(fields) <= _UPDATE_KEYS:
            _fail("fields")
        with self._tx() as conn:
            obj = self._obj(self._row(conn, sid, wid))
            if "status" in fields:
                if fields["status"] not in _STATUSES:
                    _fail("status")
                obj["status"] = fields["status"]
            if "counters" in fields:
                obj["counters"] = _counters(fields["counters"])
            if "checkpoint" in fields:
                if not isinstance(fields["checkpoint"], dict):
                    _fail("checkpoint")
                _json_text(fields["checkpoint"], _BLOB_MAX, "checkpoint")
                obj["checkpoint"] = fields["checkpoint"]
            if "error" in fields:
                err = fields["error"]
                if err is not None and (not isinstance(err, str) or len(err) > 4000):
                    _fail("error")
                obj["error"] = err
            if "last_result" in fields:
                result = fields["last_result"]
                if result is not None:
                    _json_text(result, _BLOB_MAX, "last_result")
                obj["last_result"] = result
            if "run_id" in fields:
                run_id = fields["run_id"]
                if run_id is not None and (not isinstance(run_id, str) or not (1 <= len(run_id) <= 80) or any(ch.isspace() for ch in run_id)):
                    _fail("run_id")
                obj["run_id"] = run_id
            if "authorized_revision" in fields:
                auth = fields["authorized_revision"]
                if auth is not None:
                    _int(auth, "authorized_revision")
                    if auth < 1:
                        _fail("authorized_revision")
                obj["authorized_revision"] = auth
            obj["updated_at"] = time.time()
            _json_text(obj, _ROW_MAX, "workflow")
            conn.execute(
                "UPDATE workflows SET status=?, counters=?, checkpoint=?, error=?, last_result=?, run_id=?, authorized_revision=?, updated_at=? "
                "WHERE session_id=? AND workflow_id=?",
                (
                    obj["status"], _dumps(obj["counters"]), _dumps(obj["checkpoint"]), obj["error"],
                    None if obj["last_result"] is None else _dumps(obj["last_result"]),
                    obj["run_id"], obj["authorized_revision"], obj["updated_at"], sid, wid,
                ),
            )
            return self._obj(self._row(conn, sid, wid))

    def _allowed(self, obj):
        return {item["id"] for item in obj["definition"]["categories"]}

    def _load_record(self, conn, sid, wid, item_id):
        row = conn.execute(
            "SELECT payload FROM records WHERE session_id=? AND workflow_id=? AND item_id=?", (sid, wid, item_id)
        ).fetchone()
        return None if row is None else json.loads(row["payload"])

    def _store_record(self, conn, sid, wid, record):
        conn.execute(
            "UPDATE records SET payload=? WHERE session_id=? AND workflow_id=? AND item_id=?",
            (_dumps(record), sid, wid, record["id"]),
        )

    def put_record(self, sid, wid, record):
        _sid(sid)
        _wid(wid)
        with self._tx() as conn:
            obj = self._obj(self._row(conn, sid, wid))
            incoming = _record_in(record, self._allowed(obj))
            digest = hashlib.sha256(incoming["text"].encode("utf-8")).hexdigest()
            existing = self._load_record(conn, sid, wid, incoming["id"])
            if existing is None:
                count = conn.execute("SELECT COUNT(*) AS n FROM records WHERE session_id=? AND workflow_id=?", (sid, wid)).fetchone()["n"]
                if count >= _RECORD_CAP or count >= obj["definition"]["limits"]["max_items"]:
                    _fail("record cap")
                pos = conn.execute(
                    "SELECT COALESCE(MAX(position), 0) + 1 AS n FROM records WHERE session_id=? AND workflow_id=?", (sid, wid)
                ).fetchone()["n"]
                snap = dict(incoming)
                snap["tags"] = list(incoming["tags"])
                stored = dict(snap)
                stored["tags"] = list(incoming["tags"])
                stored.update({"content_hash": digest, "revision": 1, "original_capture": snap, "audit": []})
                conn.execute(
                    "INSERT INTO records (session_id, workflow_id, item_id, position, payload) VALUES (?,?,?,?,?)",
                    (sid, wid, incoming["id"], pos, _dumps(stored)),
                )
                return stored
            if existing["url"] != incoming["url"] or existing["text"] != incoming["text"] or existing["content_hash"] != digest:
                _fail("immutable record")
            for key in ("author", "published_at", "captured_at", "truncated"):
                if existing[key] != incoming[key]:
                    _fail("immutable record")
            if existing["tags"] == incoming["tags"] and existing["summary"] == incoming["summary"]:
                return existing
            existing["audit"] = (existing["audit"] + [_audit("local", existing, "local_save")])[-_AUDIT_MAX:]
            existing["tags"] = incoming["tags"]
            existing["summary"] = incoming["summary"]
            existing["revision"] += 1
            self._store_record(conn, sid, wid, existing)
            return existing

    def recover_record(self, sid, wid, item_id, observed, expected_revision):
        """Code-owned evidence replacement. Not exposed as a model write API."""
        _sid(sid)
        _wid(wid)
        _int(expected_revision, "expected_revision")
        with self._tx() as conn:
            obj = self._obj(self._row(conn, sid, wid))
            if obj["status"] != "running":
                _fail("recovery requires active workflow")
            existing = self._load_record(conn, sid, wid, item_id)
            if existing is None or existing["revision"] != expected_revision:
                _fail("revision conflict")
            fields = {key: existing[key] for key in _RECORD_KEYS}
            if not isinstance(observed, dict) or set(observed) - set(_RECORD_KEYS):
                _fail("observed record")
            fields.update(observed)
            fields["tags"], fields["summary"] = existing["tags"], existing["summary"]
            incoming = _record_in(fields, self._allowed(obj))
            if incoming["id"] != item_id or incoming["url"] != existing["url"]:
                _fail("source identity changed")
            if len(incoming["text"]) < len(existing["text"]):
                _fail("recovery shortened evidence")
            if all(incoming[k] == existing[k] for k in _RECORD_KEYS):
                return existing
            audit = _audit("local", existing, "source_recovery")
            audit["previous_content_hash"] = existing["content_hash"]
            existing["audit"] = (existing["audit"] + [audit])[-_AUDIT_MAX:]
            existing.update(incoming)
            existing["content_hash"] = hashlib.sha256(incoming["text"].encode()).hexdigest()
            existing["revision"] += 1
            self._store_record(conn, sid, wid, existing)
            return existing

    def patch_record(self, sid, wid, item_id, patch, expected_revision, actor="grok"):
        _sid(sid)
        _wid(wid)
        if not isinstance(item_id, str) or not _SHA.fullmatch(item_id):
            _fail("record id")
        if actor not in ("grok", "local"):
            _fail("actor")
        _int(expected_revision, "expected_revision")
        if not isinstance(patch, dict) or not patch or not set(patch) <= {"tags", "summary"}:
            _fail("patch")
        with self._tx() as conn:
            obj = self._obj(self._row(conn, sid, wid))
            if obj["status"] != "paused" and not (actor == "local" and obj["status"] == "running"):
                _fail("pause required")
            existing = self._load_record(conn, sid, wid, item_id)
            if existing is None:
                _fail("unknown record")
            if existing["revision"] != expected_revision:
                _fail("revision conflict")
            allowed = self._allowed(obj)
            tags = _tags(patch["tags"], allowed) if "tags" in patch else list(existing["tags"])
            summary = _summary(patch["summary"]) if "summary" in patch else existing["summary"]
            if tags == existing["tags"] and summary == existing["summary"]:
                return existing
            existing["audit"] = (existing["audit"] + [_audit(actor, existing, "manual_patch")])[-_AUDIT_MAX:]
            existing["tags"] = tags
            existing["summary"] = summary
            existing["revision"] += 1
            self._store_record(conn, sid, wid, existing)
            return existing

    def records(self, sid, wid, limit=20, offset=0):
        _sid(sid)
        _wid(wid)
        _int(limit, "limit")
        _int(offset, "offset")
        if not 0 <= limit <= 100 or not 0 <= offset <= 5000:
            _fail("page")
        with self._lock:
            self._row(self._conn, sid, wid)
            total = self._conn.execute("SELECT COUNT(*) AS n FROM records WHERE session_id=? AND workflow_id=?", (sid, wid)).fetchone()["n"]
            rows = self._conn.execute(
                "SELECT payload FROM records WHERE session_id=? AND workflow_id=? ORDER BY position ASC LIMIT ? OFFSET ?",
                (sid, wid, limit, offset),
            ).fetchall()
        return {"items": [json.loads(row["payload"]) for row in rows], "total": total}

    def get_record(self, sid, wid, item_id):
        _sid(sid)
        _wid(wid)
        if not isinstance(item_id, str) or not _SHA.fullmatch(item_id):
            _fail("record id")
        with self._lock:
            self._row(self._conn, sid, wid)
            found = self._load_record(self._conn, sid, wid, item_id)
        if found is None:
            _fail("unknown record")
        return found
