"""Background JavaScript workflow runs. One owned job; finite yields."""

from __future__ import annotations

import asyncio
import inspect
import json
import threading
import time
import uuid
from pathlib import Path

_MISSING = object()
_COUNTERS = ("calls", "saved", "classified", "scrolls", "elapsed_ms")
_SOURCE_LIMIT = 32 * 1024
_CHECKPOINT_LIMIT = 32 * 1024
_RESULT_LIMIT = 32 * 1024
# Consecutive local continuations that saved nothing before the run pauses itself.
_CONTINUE_WITHOUT_SAVES = 3


class WorkflowYield(Exception):
    def __init__(self, status, summary):
        super().__init__(status)
        self.status = status
        self.summary = summary


def _counters(row):
    raw = row.get("counters") or {}
    out = {}
    for key in _COUNTERS:
        value = raw.get(key, 0)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
            value = 0
        out[key] = int(value)
    return out


def _reason(exc):
    text = " ".join(str(exc).split())
    return (text or exc.__class__.__name__)[:300]


def _bound_result(value):
    if value is None:
        return None
    if isinstance(value, str):
        text = value
    else:
        try:
            text = json.dumps(value, separators=(",", ":"))
        except (TypeError, ValueError):
            text = str(value)
    if len(text) > _RESULT_LIMIT:
        text = text[:_RESULT_LIMIT]
    return text[:4000]


class WorkflowManager:
    def __init__(self, service, store, execute=None, capability_factory=None, executable=None):
        self.service = service
        self.store = store
        self.execute = execute
        self.capability_factory = capability_factory
        self.executable = executable
        self.running = False
        self.job = None
        self.stopped = threading.Event()
        self.on_checkpoint = None
        self._sid = None
        self._wid = None
        self._run_id = None
        self._auth_rev = None
        self._stop_action = None
        self._t0 = None
        self._continuation = None
        self._idle_continues = {}

    def _trace(self, event, **fields):
        trace = getattr(self.service, 'trace', None)
        if trace is not None:
            trace.emit(event, **fields)

    def _runtime_path(self):
        if self.executable:
            return Path(self.executable)
        from .paths import workflow_executable

        return Path(workflow_executable())

    def _make_capability(self, sid, wid):
        factory = self.capability_factory
        if factory is None:
            from .workflow_capabilities import WorkflowCapabilities as factory

        return factory(self.service, self.store, sid, wid, self.stopped, self.progress)

    async def _invoke(self):
        execute = self.execute
        if execute is None:
            from .workflow_runtime import run_script as execute

        return execute

    def _limits_ok(self, row):
        limits = (row.get("definition") or {}).get("limits") or {}
        counters = _counters(row)
        remain_ms = int(limits.get("max_seconds") or 0) * 1000 - counters["elapsed_ms"]
        remain_calls = int(limits.get("max_calls") or 0) - counters["calls"]
        if remain_ms < 1000:
            return False, "time limit reached"
        if remain_calls < 1:
            return False, "call limit reached"
        return True, None

    def _native_budget(self, row):
        limits = row["definition"]["limits"]
        counters = _counters(row)
        remain_s = int((limits["max_seconds"] * 1000 - counters["elapsed_ms"]) / 1000)
        remain_calls = limits["max_calls"] - counters["calls"]
        return max(1, min(180, remain_s)), max(1, min(1000, remain_calls))

    async def start(self, sid, wid, continuing=False):
        if self.running:
            raise RuntimeError("a workflow is already running")
        if getattr(self.service.collections, "running", False):
            raise RuntimeError("collections are running")
        if getattr(self.service.tasks, "running", False):
            raise RuntimeError("tasks are running")
        if getattr(self.service, "recovery_active", False):
            raise RuntimeError("recovery is active")
        row = self.store.get(sid, wid)
        if not row:
            raise RuntimeError("workflow not found")
        if row.get("session_id") not in (None, sid):
            raise RuntimeError("workflow session is not current")
        if getattr(self.service.store, "current_id", None) != sid:
            raise RuntimeError("workflow session is not current")
        if row.get("status") not in ("prepared", "paused"):
            raise RuntimeError("workflow is not ready")
        runtime = self._runtime_path()
        if not runtime.is_file():
            raise RuntimeError("workflow runtime is not installed")
        ok, why = self._limits_ok(row)
        if not ok:
            self.store.update(sid, wid, error=why)
            raise RuntimeError(why)
        source = (row.get("definition") or {}).get("source") or ""
        if not isinstance(source, str) or len(source.encode("utf-8")) > _SOURCE_LIMIT:
            raise RuntimeError("workflow source is not runnable")
        if not continuing:
            self._idle_continues.pop(wid, None)
        run_id = str(uuid.uuid4())
        revision = row.get("revision")
        self.store.update(
            sid,
            wid,
            status="running",
            run_id=run_id,
            authorized_revision=revision,
            error=None,
        )
        self._sid = sid
        self._wid = wid
        self._run_id = run_id
        self._auth_rev = revision
        self._stop_action = None
        self.stopped.clear()
        self._t0 = time.monotonic()
        self.running = True
        self._trace("workflow.start", task_id=wid, session_id=sid, count=revision)
        self.job = asyncio.create_task(self._run(sid, wid, run_id, revision))
        return self.summary(sid, wid)

    async def _run(self, sid, wid, run_id, revision):
        cap = None
        settled = False
        notify = False
        outcome = {"status": "paused", "error": "workflow stopped", "result": _MISSING}
        try:
            row = self.store.get(sid, wid)
            definition = row.get("definition") or {}
            source = definition.get("source") or ""
            counters = _counters(row)
            before = counters
            seconds, max_calls = self._native_budget(row)
            payload = {
                "checkpoint": row.get("checkpoint"),
                "categories": definition.get("categories") or [],
                "counts": counters,
                # This slice's own limits, so a script can checkpoint before them.
                "budget": {"seconds": seconds, "calls": max_calls},
            }
            cap = self._make_capability(sid, wid)
            await cap.open()
            handlers = {}
            for name, fn in (cap.handlers() or {}).items():
                if name not in definition["capabilities"]:
                    continue
                handlers[name] = self._wrap(name, fn, sid, wid)
            execute = await self._invoke()
            result = await execute(
                self._runtime_path(),
                source,
                payload,
                handlers,
                self.stopped,
                seconds=seconds,
                max_calls=max_calls,
            )
            if self._stop_action == "cancel":
                outcome = {"status": "cancelled", "error": None, "result": _MISSING}
            elif self.stopped.is_set() or self._stop_action == "pause":
                outcome = {"status": "paused", "error": None, "result": _MISSING}
            else:
                outcome = {"status": "completed", "error": None, "result": _bound_result(result)}
            settled = True
        except WorkflowYield as yielded:
            summary = yielded.summary if isinstance(yielded.summary, str) else ""
            summary = summary[:500]
            if yielded.status == "complete":
                outcome = {"status": "completed", "error": None, "result": summary}
            elif yielded.status == "review":
                outcome = {"status": "paused", "error": "checkpoint_review", "result": summary}
                notify = True
            elif yielded.status == "pause":
                outcome = {"status": "paused", "error": "checkpoint_pause", "result": summary}
            elif yielded.status == "continue":
                outcome = {"status": "paused", "error": "checkpoint_continue", "result": summary}
            else:
                outcome = {"status": "paused", "error": "checkpoint rejected", "result": _MISSING}
            settled = True
        except TimeoutError:
            notify = True
            outcome = {"status": "paused", "error": "time_slice", "result": _MISSING}
            settled = True
        except asyncio.CancelledError:
            status = "cancelled" if self._stop_action == "cancel" else "paused"
            outcome = {"status": status, "error": None, "result": _MISSING}
            settled = True
        except Exception as exc:
            notify = True
            outcome = {"status": "paused", "error": _reason(exc), "result": _MISSING}
            settled = True
        finally:
            self.stopped.set()
            if cap is not None:
                try:
                    result = cap.close()
                    if inspect.isawaitable(result):
                        await result
                except Exception:
                    pass
            delta = 0
            if self._t0 is not None:
                delta = max(0, int((time.monotonic() - self._t0) * 1000))
            self._t0 = None
            try:
                fresh = self.store.get(sid, wid) or {}
                counters = _counters(fresh)
                counters["elapsed_ms"] += delta
                fields = {"counters": counters}
                if settled:
                    fields["status"] = outcome["status"]
                    fields["error"] = outcome["error"]
                    if outcome["result"] is not _MISSING:
                        fields["last_result"] = outcome["result"]
                self.store.update(sid, wid, **fields)
            except Exception:
                pass
            self._trace("workflow.end", task_id=wid, session_id=sid, status=outcome["status"], elapsed_ms=delta)
            self.running = False
            self.job = None
            if settled and outcome["error"] == "checkpoint_continue" and self._stop_action is None:
                self._schedule_continue(sid, wid, before)
            if notify and self.on_checkpoint is not None:
                callback = self.on_checkpoint
                asyncio.get_running_loop().call_soon(callback, sid, wid)
            del run_id, revision

    def _schedule_continue(self, sid, wid, before):
        """Start the next slice locally when the last one made progress; no provider turn."""
        try:
            after = _counters(self.store.get(sid, wid) or {})
        except Exception:
            return
        if after["saved"] > before["saved"]:
            self._idle_continues[wid] = 0
        else:
            self._idle_continues[wid] = self._idle_continues.get(wid, 0) + 1
        if after["saved"] == before["saved"] and after["scrolls"] == before["scrolls"]:
            self.store.update(sid, wid, error="continue_no_progress")
            return
        if self._idle_continues[wid] >= _CONTINUE_WITHOUT_SAVES:
            self.store.update(sid, wid, error="continue_no_new_items")
            return
        self._continuation = asyncio.get_running_loop().create_task(self._continue(sid, wid))

    async def _continue(self, sid, wid):
        await asyncio.sleep(0)
        row = self.store.get(sid, wid) or {}
        if row.get("status") != "paused" or row.get("error") != "checkpoint_continue":
            return
        try:
            self._trace("workflow.continue", task_id=wid, session_id=sid)
            await self.start(sid, wid, continuing=True)
        except Exception as exc:
            # start() records its own limit errors; others stay visible on the card.
            fresh = self.store.get(sid, wid) or {}
            if fresh.get("status") == "paused" and fresh.get("error") == "checkpoint_continue":
                self.store.update(sid, wid, error="continue_blocked: " + _reason(exc))
        finally:
            if self._continuation is asyncio.current_task():
                self._continuation = None

    async def _cancel_continuation(self):
        task, self._continuation = self._continuation, None
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    def _wrap(self, name, fn, sid, wid):
        async def wrapped(args):
            if self.stopped.is_set():
                raise RuntimeError("workflow is stopping")
            if getattr(self.service.store, "current_id", None) != sid or self._sid != sid:
                raise RuntimeError("workflow session is not current")
            if not isinstance(args, dict):
                args = {}
            row = self.store.get(sid, wid)
            if not row or row.get("status") != "running":
                raise RuntimeError("workflow is not running")
            if row.get("run_id") not in (None, self._run_id):
                raise RuntimeError("workflow run changed")
            if row.get("revision") != self._auth_rev:
                raise RuntimeError("workflow source changed")
            auth = row.get("authorized_revision")
            if auth is not None and auth != self._auth_rev:
                raise RuntimeError("workflow source changed")
            limits = (row.get("definition") or {}).get("limits") or {}
            counters = _counters(row)
            max_calls = int(limits.get("max_calls") or 0)
            if counters["calls"] >= max_calls:
                raise RuntimeError("call limit reached")
            counters["calls"] += 1
            self.store.update(sid, wid, counters=counters)
            started = time.monotonic()
            self._trace("workflow.call", task_id=wid, session_id=sid, method=name, count=counters["calls"])
            try:
                result = fn(args)
                if inspect.isawaitable(result):
                    result = await result
                self._trace("workflow.call.end", task_id=wid, session_id=sid, method=name, duration_ms=(time.monotonic()-started)*1000, status="ok")
                return result
            except (WorkflowYield, asyncio.CancelledError):
                raise
            except Exception as exc:
                trace = getattr(self.service, "trace", None)
                if trace is not None and hasattr(trace, "emit"):
                    trace.emit(
                        "workflow.capability",
                        task_id=wid,
                        stage=str(name)[:80],
                        status="error",
                        error_type=exc.__class__.__name__[:80],
                    )
                raise

        return wrapped

    def progress(self, event, args=None):
        if self.stopped.is_set():
            raise RuntimeError("workflow is stopping")
        sid, wid = self._sid, self._wid
        if event in ("saved", "classified", "scroll"):
            key = {"saved": "saved", "classified": "classified", "scroll": "scrolls"}[event]
            delta = 1
            if isinstance(args, dict) and "delta" in args:
                delta = args.get("delta")
            elif isinstance(args, int) and not isinstance(args, bool):
                delta = args
            if isinstance(delta, bool) or not isinstance(delta, int) or delta < 1:
                raise RuntimeError("progress delta is invalid")
            if delta > 1000:
                raise RuntimeError("progress delta is invalid")
            row = self.store.get(sid, wid)
            counters = _counters(row)
            if event == "saved":
                limit = int((row.get("definition") or {}).get("limits", {}).get("max_items") or 0)
                if counters["saved"] + delta > limit:
                    raise RuntimeError("item limit reached")
            counters[key] += delta
            self.store.update(sid, wid, counters=counters)
            return None
        if event == "progress":
            message = ""
            if isinstance(args, dict):
                message = args.get("message") or ""
            message = " ".join(str(message).split())[:160]
            activity = getattr(self.service, "activity", None)
            if message and callable(activity):
                activity(message)
            elif message and activity is not None and hasattr(activity, "post"):
                activity.post(message)
            return None
        if event == "checkpoint":
            if not isinstance(args, dict):
                raise RuntimeError("checkpoint is invalid")
            status = args.get("status")
            if status not in ("review", "pause", "complete", "continue"):
                raise RuntimeError("checkpoint is invalid")
            summary = args.get("summary", "")
            if not isinstance(summary, str):
                raise RuntimeError("checkpoint summary must be text")
            summary = summary[:500]
            state = args.get("state")
            try:
                encoded = json.dumps(state, separators=(",", ":"))
            except (TypeError, ValueError):
                raise RuntimeError("checkpoint must be JSON") from None
            if len(encoded.encode("utf-8")) > _CHECKPOINT_LIMIT:
                raise RuntimeError("checkpoint is too large")
            self.store.update(sid, wid, checkpoint=state)
            raise WorkflowYield(status, summary)
        raise RuntimeError("unknown progress event")

    def summary(self, sid, wid, include_source=False):
        row = self.store.get(sid, wid)
        if not row:
            raise RuntimeError("workflow not found")
        definition = row.get("definition") or {}
        counters = _counters(row)
        if self.running and self._sid == sid and self._wid == wid and self._t0 is not None:
            counters["elapsed_ms"] += max(0, int((time.monotonic() - self._t0) * 1000))
        public = {
            "id": row.get("id", wid),
            "session_id": sid,
            "title": row.get("title") or definition.get("title"),
            "categories": definition.get("categories") or [],
            "capabilities": definition.get("capabilities") or [],
            "tab_id": definition.get("tab_id"),
            "start_url": definition.get("start_url"),
            "model": definition.get("model"),
            "limits": definition.get("limits") or {},
            "revision": row.get("revision"),
            "status": row.get("status"),
            "error": row.get("error"),
            "counters": counters,
            "run_id": row.get("run_id"),
        }
        if include_source:
            public["source"] = definition.get("source")
        return public

    def summaries(self, sid):
        rows = list(self.store.list(sid) or [])
        rows.sort(key=lambda row: str(row.get("updated_at") or ""), reverse=True)
        return [self.summary(sid, row["id"]) for row in rows[:20]]

    async def control(self, sid, wid, action):
        if action == "resume":
            return await self.start(sid, wid)
        if action not in ("pause", "stop"):
            raise RuntimeError("unknown workflow action")
        if not self.running:
            # Between local slices: cancel the pending continuation instead of failing.
            await self._cancel_continuation()
            row = self.store.get(sid, wid)
            if row and row.get("status") == "paused" and row.get("error") == "checkpoint_continue":
                if action == "stop":
                    self.store.update(sid, wid, status="cancelled", error=None)
                else:
                    self.store.update(sid, wid, error=None)
                return self.summary(sid, wid)
        if not (self.running and self._sid == sid and self._wid == wid and self.job is not None):
            raise RuntimeError("workflow run is not active")
        row = self.store.get(sid, wid)
        if not row or row.get("run_id") != self._run_id:
            raise RuntimeError("workflow run is not active")
        self._stop_action = "cancel" if action == "stop" else "pause"
        self.stopped.set()
        job = self.job
        job.cancel()
        try:
            await job
        except asyncio.CancelledError:
            pass
        if self.job is job:
            self.running = False
            self.job = None
            self._t0 = None
        fresh = self.store.get(sid, wid)
        if fresh and fresh.get("status") == "running":
            self.store.update(sid, wid, status="cancelled" if action == "stop" else "paused")
        return self.summary(sid, wid)

    async def close(self):
        await self._cancel_continuation()
        if self.running and self._sid and self._wid:
            await self.control(self._sid, self._wid, "pause")
