"""One local browser task at a time, with an explicit stop and retained evidence."""

import asyncio
import json
import os
import threading
import time
import uuid
from contextlib import nullcontext
from pathlib import Path

from opentelemetry.trace import Status, StatusCode

from jev_ultrafast.agent import Agent
from jev_ultrafast.browser import Browser
from jev_ultrafast.local_models import MODELS, WORKER

from .bridge import ThreadBridge

LOCAL_MODELS = [
    {"id": key, "title": info["title"]}
    for key, info in MODELS.items()
    if key != "jev_hosted"
]


class TaskManager:
    def __init__(self, bridge, root, activity, on_complete=None, trace=None):
        self.bridge, self.root, self.activity = bridge, Path(root), activity
        self.on_complete = on_complete
        self.trace = trace
        self.current = None
        self.future = None
        self.stopped = threading.Event()
        self.results = {}

    @property
    def running(self):
        return self.future is not None and not self.future.done()

    def submit(self, goal, model="lfm_rlcd", tab_id=None):
        if self.running:
            raise ValueError("A browser task is already running; stop it before starting another")
        if not isinstance(goal, str) or not goal.strip() or len(goal) > 6000:
            raise ValueError("Supply an instruction of 1–6000 characters")
        if model not in {m["id"] for m in LOCAL_MODELS}:
            raise ValueError("Choose an installed local model")
        tab_id = self.bridge.tab(tab_id)
        self.stopped = threading.Event()
        self.current = {
            "id": uuid.uuid4().hex, "created_at": time.time(), "goal": goal.strip(), "model": model, "tab_id": tab_id,
            "status": "loading", "elapsed_ms": 0, "steps": 0, "native_calls": 0, "typing_calls": 0,
            "verification": "pending", "actions": [],
        }
        loop = asyncio.get_running_loop()
        self.future = asyncio.create_task(self._run(dict(self.current), self.stopped, loop))
        return dict(self.current)

    def stop(self):
        if self.running:
            self.stopped.set()
            self.current["status"] = "stopping"
        return self.current

    async def wait(self, task_id, timeout=150):
        if self.current and self.current["id"] == task_id and self.future:
            await asyncio.wait_for(asyncio.shield(self.future), timeout)
        return self.results.get(task_id) or self.current

    async def _run(self, task, stopped, loop):
        context = self.trace.span('task.run', task_id=task['id'], model=task['model'], tab_id=task['tab_id']) if self.trace else nullcontext()
        with context as span:
            result = await self._run_traced(task, stopped, loop)
            if span and result['status'] in {'error', 'blocked', 'stopped'}:
                span.set_status(Status(StatusCode.ERROR))
            return result

    async def _run_traced(self, task, stopped, loop):
        def publish(patch):
            def apply():
                # Progress queued by the worker must never rewrite a retained
                # terminal result when it reaches the event loop after completion.
                if (self.current and self.current["id"] == task["id"]
                        and task["id"] not in self.results):
                    self.current.update(patch)
            loop.call_soon_threadsafe(apply)

        self.activity("Browser task started", "running")
        result = await asyncio.to_thread(self._work, task, stopped, loop, publish)
        self.current = result
        self.results[task["id"]] = result
        if len(self.results) > 100:
            del self.results[next(iter(self.results))]
        self.activity("Browser task " + result["status"], result["status"])
        if self.trace:
            self.trace.emit('task.result', task_id=task['id'], status=result['status'], model=task['model'],
                            duration_ms=result['elapsed_ms'], steps=result['steps'],
                            native_calls=result['native_calls'], typing_calls=result['typing_calls'],
                            error=result.get('error'), level='error' if result['status'] == 'error' else 'info')
        if self.on_complete:
            self.on_complete(result)
        return result

    def _work(self, task, stopped, loop, publish):
        # A routed chat and a browser task must never swap the shared model's
        # subprocess while another inference/action loop is using it.
        waiting = time.monotonic()
        with WORKER.lock:
            if self.trace:
                self.trace.emit('task.queue.acquired', task_id=task['id'], queue_ms=round((time.monotonic() - waiting) * 1000))
                WORKER.trace = self.trace.emit
            return self._work_locked(task, stopped, loop, publish)

    def _work_locked(self, task, stopped, loop, publish):
        started = time.perf_counter()
        agent = None
        try:
            WORKER.start(task["model"])
            WORKER.records.clear()
            if stopped.is_set():
                raise RuntimeError("Stopped while the model was loading")
            transport = ThreadBridge(self.bridge, loop, task["tab_id"], stopped)
            browser = Browser(transport=transport)
            agent = Agent(None, task["goal"], browser=browser, decision_mode=task["model"],
                          policy_profile="anchored_form_safe", text_profile="examples_v2", screenshots=False)
            task["load_ms"] = round((time.perf_counter() - started) * 1000)
            task["status"] = "running"
            publish(dict(task))
            # Time and action limits are independent. No failed input is automatically retried.
            deadline = time.monotonic() + 90
            for _ in range(24):
                if stopped.is_set() or time.monotonic() > deadline:
                    break
                with self.trace.span('task.step', task_id=task['id'], steps=task['steps']) if self.trace else nullcontext():
                    agent.command("tick")
                snap = agent.snapshot()
                if self.trace and snap.get('decisions'):
                    decision = snap['decisions'][-1]
                    self.trace.emit('task.decision', task_id=task['id'], choice=decision.get('choice'),
                                    operation=decision.get('operation'), confidence=decision.get('confidence'),
                                    inference_ms=decision.get('latency_ms'), status=snap['status'])
                task.update(self._progress(snap, started))
                publish(dict(task))
                if snap["status"] in {"done", "blocked"}:
                    break
            snap = agent.snapshot()
            task.update(self._progress(snap, started))
            task["status"] = "stopped" if stopped.is_set() else snap["status"]
            if task["status"] not in {"done", "blocked", "stopped"}:
                task["status"] = "blocked"
                task["error"] = "Reached the task time or action budget"
            page = snap["page"]
            task["result"] = {"url": page.get("url"), "text": page.get("text", "")[:18000],
                              "actions": page.get("actions", [])[:80]}
            task["verification"] = "manual_check"
            task["result_note"] = "DONE is the model's completion decision. Inspect the observed page to verify this goal."
        except Exception as error:
            task["status"] = "stopped" if stopped.is_set() else "error"
            task["error"] = str(error)[:1200]
            task["verification"] = "unverified"
        finally:
            if agent:
                terminal = task["status"]
                task.update(self._progress(agent.snapshot(), started))
                task["status"] = terminal
            task["elapsed_ms"] = round((time.perf_counter() - started) * 1000)
            # Conversation data stays in its private store. Diagnostic files keep
            # timings and finite actions, never page text, typed values or prompts.
            trace = {"task": {key: task.get(key) for key in (
                'id', 'created_at', 'model', 'tab_id', 'status', 'elapsed_ms', 'steps', 'native_calls', 'typing_calls', 'load_ms')},
                "actions": [{key: action.get(key) for key in ('step', 'kind', 'choice', 'confidence', 'latency_ms', 'text_latency_ms', 'operation', 'target', 'page_changed')}
                            for action in task.get('actions', [])],
                "native_records": [{"backend": item['backend'], "latency_ms": item['latency_ms'],
                                    "status": "error" if item.get('result', {}).get('error') else "ok"} for item in WORKER.records],
                "input_diagnostics": agent.browser.transport.input_diagnostics if agent else []}
            folder = self.root / ".runtime/tasks"
            try:
                folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                path = folder / (task["id"] + ".json")
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, 'O_NOFOLLOW', 0), 0o600)
                with os.fdopen(descriptor, 'w') as output:
                    output.write(json.dumps(trace, ensure_ascii=False, default=str, indent=2))
            except OSError as error:
                if self.trace:
                    self.trace.emit('diagnostic.write.error', error_type=type(error).__name__, component='task_snapshot')
            if agent:
                agent.browser.close()
        return task

    @staticmethod
    def _progress(snap, started):
        histories = snap.get("history", [])
        return {
            "elapsed_ms": round((time.perf_counter() - started) * 1000),
            "steps": len(histories), "typing_calls": len(snap.get("text_calls", [])),
            "native_calls": sum(d.get("inference_requests", 0) for d in snap.get("decisions", [])),
            "actions": histories[-30:], "status": "running",
        }
