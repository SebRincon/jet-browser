"""Authenticated loopback control plane for Jet Browser."""

import asyncio
import hashlib
import hmac
import json
import os
import secrets
import sys
import threading
import time
import uuid
from contextlib import nullcontext, suppress
from pathlib import Path
from urllib.parse import urlparse

from aiohttp import web

from . import collection_repair_tools, collection_supervision_tools, collection_tools, workflow_tools
from .bridge import BridgeError, BrowserBridge
from .collection_runner import CollectionManager
from .collection_store import CollectionStore
from .paths import DATA_ROOT as ROOT
from .paths import PORT, RESOURCE_ROOT
from .routing import ROUTER_MODEL, LocalRouter
from .runtime_setup import RuntimeSetup
from .sessions import ConversationStore
from .supervisor_agent import SupervisorAgent
from .tasks import LOCAL_MODELS, TaskManager
from .text_runtime import TextRuntime
from .tracing import TraceStore
from .workflow_manager import WorkflowManager
from .workflow_store import WorkflowStore
from .workflow_supervisor import WorkflowSupervisor
from .workflow_supervisor import register_routes as workflow_routes
from .workspace import NAMES as WORKSPACE_NAMES
from .workspace import WorkspaceStore
from .workspace import register_routes as register_workspace_routes
from .workspace import tool as workspace_tool


def token_file(root=ROOT):
    runtime = root / ".runtime"
    runtime.mkdir(exist_ok=True, mode=0o700)
    path = runtime / "token"
    if not path.exists():
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write(secrets.token_urlsafe(32))
    if path.stat().st_mode & 0o077:
        raise RuntimeError("Jet Browser token must have owner-only permissions")
    return path.read_text().strip()


def valid_url(value):
    if not isinstance(value, str) or len(value) > 6000:
        raise ValueError("Supply an HTTP or HTTPS URL")
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Only HTTP/HTTPS pages without embedded credentials are supported")
    return value


class Service:
    def __init__(self, root=ROOT):
        self.root = root
        self.token = token_file(root)
        self.trace = TraceStore(root)
        self.bridge = BrowserBridge(trace=self.trace)
        self.activity_log = []
        self.store = ConversationStore(root)
        self.messages = self.store.messages()
        self.task_sessions = {}
        self.tasks = TaskManager(self.bridge, root, self.activity, self.task_completed, trace=self.trace)
        self.router = LocalRouter(trace=self.trace)
        self.turn_id = None
        self.turn_context = None
        self.chat_stopped = threading.Event()
        self.turn_browser = self.browser_state()
        self.chat_job = None
        self.grok = None
        self.provider_id = None
        self.provider_status = "ready"
        # Safe identifiers only (stage, tool name); see GrokClient.stage.
        self.provider_stage = None
        self.response = None
        self.settings = {"local_model": "qwen4b_semif_shared" if (RESOURCE_ROOT / "python/bin/python3.12").is_file() else "lfm_rlcd"}
        saved = root / ".runtime/settings.json"
        if saved.exists():
            value = json.loads(saved.read_text()).get("local_model")
            if value in {item["id"] for item in LOCAL_MODELS}:
                self.settings["local_model"] = value
        self.collection_store = CollectionStore(root)
        self.collections = CollectionManager(self.collection_store, self.bridge, trace=self.trace)
        self.recovery_active = False
        self.auto_review = None
        self._review_continue = False
        self.supervisor = SupervisorAgent(self)
        self.collections.on_checkpoint = self.supervisor.queue
        preferences = root / '.runtime/supervision_preferences.json'
        self.share_review_samples = preferences.exists() and json.loads(preferences.read_text()).get('share_samples') is True
        if root == ROOT:
            # Workspaces are independent of DATA_ROOT; isolated launches must set
            # JET_WORKSPACE_ROOT too (see docs/development.md).
            override = os.environ.get('JET_WORKSPACE_ROOT')
            workspace_root = Path(override).expanduser() if override else Path.home() / '.jet-browser'
        else:
            workspace_root = root / '.runtime' / 'agent-workspace'
        self.workspace = WorkspaceStore(workspace_root)
        self.workflow_store = WorkflowStore(root)
        self.workflows = WorkflowManager(self, self.workflow_store)
        self.workflow_review = None
        self.workflow_supervisor = WorkflowSupervisor(self)
        self.workflows.on_checkpoint = self.workflow_supervisor.queue
        self.runtime_setup = RuntimeSetup(root, RESOURCE_ROOT, PORT)
        self.text_runtime = TextRuntime(root, RESOURCE_ROOT, PORT)
        self._import_previous_session()
        # A restart restores evidence, never a half-finished action queue.
        for task in self.store.tasks():
            if task.get('status') in {'loading', 'running', 'stopping'}:
                self.store.save_task({**task, 'status': 'stopped', 'error': 'Service restarted; actions were not replayed'})
        for route in self.store.routes():
            if route.get('status') in {'selected', 'running', 'handoff'}:
                self.store.save_route({**route, 'status': 'stopped', 'reason': 'Service restarted; this turn was not resumed automatically'})
        self.trace.emit('service.ready', session_id=self.store.current_id, pid=os.getpid())

    def _import_previous_session(self):
        path = self.root / '.runtime/session-import.json'
        if path.exists() and not self.messages and len(self.store.list()) == 1:
            data = json.loads(path.read_text())
            for message in data.get('messages', []):
                self.store.save_message({**message, 'source': message.get('source', 'grok')})
            for task in data.get('task_history', []):
                trace = self.root / '.runtime/tasks' / (task['id'] + '.json')
                if trace.exists():
                    task = json.loads(trace.read_text()).get('task', task)
                self.store.save_task(task)
            self.messages = self.store.messages()
            path.rename(path.with_suffix('.imported.json'))

    @property
    def busy(self):
        return ((self.chat_job is not None and not self.chat_job.done())
                or self.tasks.running or self.collections.running or self.workflows.running or self.recovery_active)

    @property
    def chat_busy(self):
        return ((self.chat_job is not None and not self.chat_job.done())
                or self.tasks.running or self.recovery_active)

    def browser_state(self):
        return {'online': self.bridge.online, 'tabs': self.bridge.tabs,
                'active_tab_id': self.bridge.active_tab_id}

    def task_completed(self, task):
        session_id = self.task_sessions.get(task['id'], self.store.current_id)
        self.store.save_task(task, session_id)

    def submit_task(self, goal, model, tab_id):
        if self.collections.running or self.workflows.running:
            raise ValueError('A collection owns the browser')
        if not self.chat_job or self.chat_job.done():
            self.turn_id = uuid.uuid4().hex
        with self.trace.bind(session_id=self.store.current_id, turn_id=self.turn_id):
            task = self.tasks.submit(goal, model, tab_id)
        self.task_sessions[task['id']] = self.store.current_id
        self.store.save_task(task)
        return task

    def save_route(self, route):
        route['turn_id'] = self.turn_id
        saved = self.store.save_route(route)
        route.update(saved)
        self.trace.emit('route.updated', route_id=route['id'], operation=route.get('operation'),
                        decision=route.get('decision'), status=route.get('status'),
                        model=route.get('model'), duration_ms=route.get('total_ms', route.get('elapsed_ms')),
                        task_id=route.get('task_id'), reason=route.get('reason'))
        return route

    async def local_call(self, function, *args):
        from jev_ultrafast.local_models import WORKER
        stopped = self.chat_stopped

        def run():
            waiting = time.monotonic()
            with WORKER.lock:
                self.trace.emit('local.queue.acquired', queue_ms=round((time.monotonic() - waiting) * 1000))
                if stopped.is_set():
                    raise RuntimeError('Stopped before local work')
                return function(*args)
        result = await asyncio.to_thread(run)
        if stopped.is_set():
            raise asyncio.CancelledError()
        return result

    async def select_session(self, session_id=None):
        if self.busy:
            raise ValueError('Stop the active turn before changing conversations')
        # Validate before ending an otherwise usable Grok session.
        session = self.store.activate(session_id) if session_id is not None else self.store.create()
        if self.grok:
            await self.grok.close()
            self.grok = None
        self.provider_id = None
        self.messages = self.store.messages()
        self.response = None
        self.activity_log = []
        self.provider_status = 'ready'
        self.turn_id = None
        self.turn_context = None
        self.trace.emit('session.selected', session_id=session['id'])
        return session

    def activity(self, title, status="info"):
        self.activity_log.append({"title": title[:300], "status": status, "time": time.time()})
        self.activity_log = self.activity_log[-80:]

    def message(self, role, text, source=None):
        item = {"id": uuid.uuid4().hex, "created_at": time.time(), "role": role, "text": text,
                "turn_id": self.turn_id,
                "source": source or ('local' if self.provider_status in {'routing', 'local'} else 'grok')}
        self.messages.append(item)
        self.store.save_message(item)
        return item

    def update_settings(self, body):
        model = body.get("local_model")
        if not isinstance(model, str) or model not in {item["id"] for item in LOCAL_MODELS}:
            raise ValueError("Choose an installed local browser model")
        self.settings["local_model"] = model
        path = self.root / ".runtime/settings.json"
        path.write_text(json.dumps(self.settings))
        path.chmod(0o600)
        return self.settings

    def state(self):
        task = dict(self.tasks.current) if self.tasks.current and self.task_sessions.get(self.tasks.current['id']) == self.store.current_id else None
        if task:
            task.pop("result", None)
        history = [{k: v for k, v in item.items() if k != "result"}
                   for item in self.store.tasks()[-20:]]
        return {"application": "jet-browser", "messages": self.messages[-100:],
                "busy": self.busy,
                "session": self.store.session(), "sessions": self.store.list(),
                "routes": [{k: v for k, v in route.items() if k not in {'audit', 'result'}} for route in self.store.routes()[-30:]],
                "settings": self.settings, "task_history": history,
                "activity": self.activity_log[-40:], "task": task, "models": LOCAL_MODELS,
                "trace": self.trace.snapshot(self.store.current_id, limit=120),
                "provider": {"name": "Jet Assistant", "status": self.provider_status, "router_model": ROUTER_MODEL,
                             "stage": self.provider_stage},
                "browser": self.browser_state(),
                "collections": self.collections.summaries(self.store.current_id),
                "workflows": self.workflows.summaries(self.store.current_id),
                "setup": {"packaged": self.runtime_setup.packaged, "ready": self.runtime_setup.status()['ready']},
                "chat_busy": self.chat_busy,
                "workspace": {"files": self.workspace.list(self.store.current_id)}}

    async def chat(self, text):
        if self.chat_busy:
            raise ValueError("A conversation turn or browser task is already running")
        if not isinstance(text, str) or not text.strip() or len(text) > 16000:
            raise ValueError("Enter a message of 1–16000 characters")
        self.turn_id = uuid.uuid4().hex
        self.message("user", text.strip())
        self.response = None
        self.chat_stopped = threading.Event()
        self.turn_browser = self.browser_state()
        self.provider_status = 'routing'

        async def turn():
            with self.trace.bind(session_id=self.store.current_id, turn_id=self.turn_id):
                try:
                    with self.trace.span('chat.turn', input_chars=len(text), model=ROUTER_MODEL):
                        self.turn_context = self.trace.capture()
                        await execute_turn()
                except (Exception, asyncio.CancelledError):
                    pass  # Already surfaced and persisted below; the span retains its actual terminal status.

        async def execute_turn():
            try:
                pending_review = any(
                    run.get('status') == 'paused' and (run.get('supervision') or {}).get('pending')
                    for run in self.collection_store.list(self.store.current_id)
                )
                await self.text_runtime.ensure()
                workflow_context = self.workflows.summaries(self.store.current_id)
                if self.collections.running or pending_review or workflow_context:
                    await self.grok_turn(text.strip())
                else:
                    from .conversation import run_turn
                    await run_turn(self, text.strip())
                self.provider_status = 'ready'
                self.trace.emit('chat.completed', status='done')
            except asyncio.CancelledError:
                self.message('assistant', 'Stopped.', source='local')
                self.provider_status = 'ready'
                self.activity('Agent turn stopped', 'stopped')
                self.trace.emit('chat.stopped', status='stopped')
                raise
            except Exception as error:
                self.trace.emit('chat.error', level='error', error_type=type(error).__name__, error=str(error))
                self.message('assistant', str(error)[:1000], source='grok')
                self.provider_status = 'error'
                if self.grok:
                    await self.grok.close()
                    self.grok = None
                raise
            finally:
                for message in self.messages:
                    self.store.save_message(message)

        self.chat_job = asyncio.create_task(turn())
        return {"status": "started", "session_id": self.store.current_id, "turn_id": self.turn_id}

    async def grok_turn(self, text):
        with self.trace.span('grok.turn', provider='grok'):
            self.turn_context = self.trace.capture()
            return await self._grok_turn(text)

    async def _grok_turn(self, text):
        self.provider_status = 'connecting'
        self.response = self.message('assistant', '', source='grok')
        separate_text = False
        last_save = 0.0

        def emit(event):
            nonlocal separate_text, last_save
            kind = event.get("type")
            if kind == "text":
                if self.response is None:
                    self.response = self.message("assistant", "", source='grok')
                if separate_text and self.response['text']:
                    self.response['text'] += '\n\n'
                separate_text = False
                self.response["text"] += event.get("text", "")
                if time.monotonic() - last_save > .5:
                    self.store.save_message(self.response)
                    last_save = time.monotonic()
            elif kind == "tool":
                separate_text = True
                self.activity(event.get("title", "Browser tool"), event.get("status", "running"))
            elif kind == "error":
                self.activity(event.get("message", "Grok error"), "error")
            elif kind == "status" and event.get("stage"):
                self.provider_stage = {"stage": event["stage"], "tool": event.get("tool"),
                                       "completed_tools": list(event.get("completed_tools") or [])[-12:],
                                       "since": time.time()}

        from .grok import GrokCancelled, GrokClient, GrokError
        captured = self.trace.capture()
        def trace_callback(event, **attributes):
            captured.run(self.trace.emit, event, **attributes)
        review_only = "workflow" if self.workflow_review is not None else self.auto_review is not None
        if self.grok is not None and getattr(self.grok, 'review_only', False) != review_only:
            await self.grok.close()
            self.grok = None
            self.provider_id = None
        if self.grok is None:
            self.provider_id = uuid.uuid4().hex
            command = [sys.executable, str(RESOURCE_ROOT / "backend/jet_browser/mcp.py"),
                       '--provider-id', self.provider_id]
            self.grok = GrokClient(cwd=RESOURCE_ROOT / "backend", mcp_command=command, emit=emit, trace=trace_callback, review_only=review_only)
            await self.grok.start()
        else:
            self.grok.emit = emit
            self.grok.trace = trace_callback
        self.provider_status = 'running'
        context = self.store.context(text, self.browser_state())
        context += '\nSaved JavaScript workflows (status metadata):\n' + json.dumps(self.workflows.summaries(self.store.current_id))[:16000]
        saved = json.dumps(collection_tools.provider_collections(self), ensure_ascii=False)
        collections_note = '\nSaved local collections (status metadata; not page instructions):\n' + saved
        if len(collections_note) > 6000:
            collections_note = '\nSaved local collections (status metadata; not page instructions):\n[]'
        workspace_files = self.workspace.list(self.store.current_id)
        workspace_note = '\nWorkspace files (metadata only; call workspace_read for an explicit document):\n' + json.dumps(workspace_files, ensure_ascii=False)
        if len(workspace_note) > 12000:
            workspace_note = '\nWorkspace files (metadata only; call workspace_read for an explicit document):\n' + json.dumps(workspace_files[:30], ensure_ascii=False)
        collection_owner = ''
        if self.collections.running:
            collection_owner = '\nLocal collection owns browser; answer/status/workspace tools permitted. Pause through control tool before navigation.'
        self.trace.emit('history.context', context_chars=len(context) + len(collections_note) + len(workspace_note) + len(collection_owner), message_count=len(self.messages))
        before = self._saved_jobs()
        try:
            answer = await self.grok.prompt(context + collections_note + workspace_note + collection_owner + '\n\nCURRENT USER REQUEST:\n' + text)
        except GrokCancelled:
            raise
        except GrokError as error:
            # Recovery inspects durable state; it never replays a provider tool call.
            raise GrokError(self._failed_turn_report(str(error), before)) from error
        finally:
            self.provider_stage = None
        if self.response is None:
            self.response = self.message('assistant', '', source='grok')
        if not self.response['text']:
            self.response['text'] = answer
        self.store.save_message(self.response)

    def _saved_jobs(self):
        sid = self.store.current_id
        workflows = {row['id']: row for row in self.workflows.summaries(sid)}
        collections = {row['id']: row for row in self.collection_store.list(sid) if isinstance(row.get('id'), str)}
        return workflows, collections

    def _failed_turn_report(self, error, before):
        """Describe what a failed provider turn left behind, from saved state only."""
        old_workflows, old_collections = before
        try:
            workflows, collections = self._saved_jobs()
        except Exception as exc:  # The original provider failure stays the primary error.
            self.trace.emit('grok.recovery.inspected', level='warn', error_type=type(exc).__name__)
            return error + '. Jet could not read saved workflow state; check the job cards before retrying.'
        saved, started = [], []
        for wid, row in workflows.items():
            old = old_workflows.get(wid)
            if row.get('status') in {'running', 'completed'} and (old is None or old.get('run_id') != row.get('run_id')):
                started.append(row)
            elif old is None or old.get('revision') != row.get('revision'):
                saved.append(row)
        prepared = [row for cid, row in collections.items() if cid not in old_collections]
        resumed = [row for cid, row in collections.items()
                   if row.get('status') == 'running' and (old_collections.get(cid) or {}).get('status') != 'running']
        self.trace.emit('grok.recovery.inspected', saved_workflows=len(saved), started_workflows=len(started),
                        prepared_collections=len(prepared), started_collections=len(resumed))

        def title(row):
            return '“' + str(row.get('title') or 'Workflow')[:80] + '”'

        if started:
            detail = f'Workflow {title(started[0])} was started and is {started[0].get("status")}; its card shows progress.'
        elif resumed:
            detail = 'A collection was started; its card shows progress.'
        elif saved:
            row = saved[0]
            detail = (f'Workflow {title(row)} was saved (revision {row.get("revision")}) but not started. '
                      'Ask me to start it, or send the request again.')
        elif prepared:
            detail = 'A collection was prepared but not started. Ask me to start it, or send the request again.'
        else:
            detail = 'No workflow or collection was saved or started. You can send the request again.'
        return error.rstrip('.') + '. ' + detail

    async def stop(self):
        await self.workflow_supervisor.close()
        await self.workflows.close()
        await self.supervisor.close()
        if self.busy:
            with self.trace.bind(session_id=self.store.current_id, turn_id=self.turn_id):
                self.trace.emit('chat.stop_requested', stop_requested=True)
        self.chat_stopped.set()
        await self.collections.stop_active()
        self.tasks.stop()
        self.provider_id = None
        self.bridge.cancel_queued()
        # Cancel the whole turn, including provider startup before prompt() is active.
        # The ACP adapter closes its child on task cancellation so no late tool can run.
        if self.chat_job and not self.chat_job.done():
            self.chat_job.cancel()
            with suppress(asyncio.CancelledError):
                await self.chat_job
        if self.grok:
            await self.grok.close()
            self.grok = None
        self.provider_status = "ready"
        return {"status": "stopping"}

    def _fold_job_narration(self):
        if self.chat_job is None or self.chat_job.done():
            return
        current = self.response
        if not isinstance(current, dict):
            return
        text = current.get('text')
        if (current.get('role') == 'assistant' and current.get('source') == 'grok'
                and isinstance(text, str) and text.strip()):
            current['phase'] = 'progress'
            self.store.save_message(current)
            self.response = None

    async def tool(self, name, args):
        current = self.trace.current_context()
        if current['trace_id'] and current['turn_id'] == self.turn_id:
            context = nullcontext()
        else:
            context = self.turn_context.bind() if self.turn_context and self.busy else self.trace.bind(session_id=self.store.current_id)
        with context:
            with self.trace.span('browser.tool', tool=name, tab_id=args.get('tab_id') if isinstance(args, dict) else None):
                return await self._tool(name, args)

    async def _tool(self, name, args):
        if not isinstance(args, dict):
            raise ValueError('Tool arguments must be an object')
        if self.workflow_review is not None:
            if name not in workflow_tools.NAMES or (name != 'workflow_sdk' and args.get('workflow_id') != self.workflow_review[1]):
                raise ValueError('Workflow review is limited to its own workflow')
        if self.auto_review is not None:
            if name not in {'collection_review', 'review_collection', 'recover_collection_item'} or args.get('collection_id') != self.auto_review[1]:
                raise ValueError('Checkpoint review only permits its own review tools')
        if name in workflow_tools.NAMES:
            self._fold_job_narration()
            return await workflow_tools.tool(self, name, args)
        if self.workflows.running and name in {'prepare_collection', 'start_collection', 'control_collection', 'recover_collection_item', 'browser_action', 'open_url', 'read_page', 'run_task'}:
            raise ValueError('A workflow owns the browser; pause it first')
        if self.recovery_active:
            raise ValueError("A source recovery owns the browser")
        if name in collection_repair_tools.NAMES:
            return await collection_repair_tools.tool(self, name, args)
        if name in collection_supervision_tools.NAMES:
            self._fold_job_narration()
            return await collection_supervision_tools.tool(self, name, args)
        if name in {'browser_action', 'open_url', 'read_page', 'run_task'} and self.collections.running:
            raise ValueError('A collection owns the browser')
        if name in collection_tools.NAMES or name in WORKSPACE_NAMES:
            self._fold_job_narration()
        if name in collection_tools.NAMES:
            return await collection_tools.tool(self, name, args)
        if name in WORKSPACE_NAMES:
            return await workspace_tool(self, name, args)
        if name == "list_tabs":
            return {"tabs": self.bridge.tabs, "active_tab_id": self.bridge.active_tab_id}
        if name == 'conversation_history':
            return {'session': self.store.session(),
                    'context': self.store.context(str(args.get('query', ''))[:2000], self.browser_state()),
                    'collections': collection_tools.provider_collections(self),
                    'workspace_files': self.workspace.list(self.store.current_id)}
        if name == 'browser_action':
            if self.tasks.running:
                raise ValueError('Wait for the current browser task before changing tabs')
            methods = {'back': 'Browser.back', 'forward': 'Browser.forward', 'reload': 'Browser.reload',
                       'switch_tab': 'Browser.selectTab', 'close_tab': 'Browser.closeTab'}
            action = args.get('action')
            if action == 'new_tab':
                return await self.bridge.call(None, 'Browser.openTab', {'url': 'about:blank'})
            if action not in methods:
                raise ValueError('Unsupported application action')
            return await self.bridge.call(args.get('tab_id'), methods[action])
        if name == "open_url":
            if self.tasks.running:
                raise ValueError("A browser task is running; wait or stop before navigating")
            url = valid_url(args.get("url"))
            tab_id = args.get("tab_id")
            if tab_id:
                await self.bridge.call(tab_id, "Page.navigate", {"url": url})
            else:
                result = await self.bridge.call(None, "Browser.openTab", {"url": url})
                tab_id = result.get("tab_id")
            return {"tab_id": tab_id, "url": url, "note": "Read the page after navigation settles."}
        if name == "read_page":
            if self.tasks.running:
                raise ValueError("Wait for the running task's result before reading another snapshot")
            from jev_ultrafast.browser import READ_STATE
            expression = '(() => { const s=' + READ_STATE + '; if(s) s.ready_state=document.readyState; return s; })()'
            result = await self.bridge.call(args.get("tab_id"), "Runtime.evaluate",
                                           {"expression": expression, "returnByValue": True})
            page = result.get("result", {}).get("value") or {}
            identity = page.get('channel_identity') if isinstance(page.get('channel_identity'), dict) else {}
            return {"url": page.get("url"), "title": page.get('title', ''),
                    "heading": page.get('heading', ''), "lead": page.get('lead', ''),
                    "canonical_url": page.get('canonical_url') or '',
                    "canonical_title": page.get('canonical_title') or '',
                    "channel_identity": {
                        'external_id': str(identity.get('external_id') or '')[:80],
                        'vanity_url': str(identity.get('vanity_url') or '')[:300],
                        'title': str(identity.get('title') or '')[:180],
                    },
                    "navigation_error": str(page.get('navigation_error') or '')[:300],
                    "missing_article": page.get('missing_article') is True,
                    "document_id": (page.get('marker') or [None])[0], "ready_state": page.get('ready_state'),
                    "text": str(page.get("text", ""))[:20000],
                    "actions": page.get("actions", [])[:100]}
        if name == "run_task":
            task = self.submit_task(args.get("goal"), args.get("model", self.settings["local_model"]), args.get("tab_id"))
            if self.response:
                self.store.save_message(self.response)
            self.response = None  # The next agent text belongs after this tool card.
            return await self.tasks.wait(task["id"])
        if name == "task_status":
            task_id = args.get("task_id")
            if task_id:
                saved = {t['id']: t for t in self.store.tasks()}
                if task_id in saved and self.task_sessions.get(task_id) != self.store.current_id:
                    return saved[task_id]
                if task_id in self.tasks.results and self.task_sessions.get(task_id) == self.store.current_id:
                    return self.tasks.results[task_id]
                if (not self.tasks.current or self.tasks.current["id"] != task_id
                        or self.task_sessions.get(task_id) != self.store.current_id):
                    raise ValueError("Unknown browser task id")
            if self.tasks.current and self.task_sessions.get(self.tasks.current['id']) == self.store.current_id:
                return self.tasks.current
            return {"status": "idle"}
        if name == "stop_task":
            return self.tasks.stop() or {"status": "idle"}
        raise ValueError("Unknown browser tool")


def create_app(service):
    @web.middleware
    async def observe(request, handler):
        started = time.monotonic()
        status = 500
        request_id = uuid.uuid4().hex
        resource = request.match_info.route.resource
        route = resource.canonical if resource is not None else 'unknown'
        try:
            response = await handler(request)
            status = response.status
            response.headers['X-Request-ID'] = request_id
            return response
        except web.HTTPException as error:
            status = error.status
            error.headers['X-Request-ID'] = request_id
            raise
        finally:
            elapsed = (time.monotonic() - started) * 1000
            service.trace.record('http.' + request.method + '.' + route, elapsed,
                                 status=str(status // 100) + 'xx')
            if status >= 400 or (request.method == 'POST' and route not in {'/browser/sync', '/browser/results'}):
                with service.trace.bind(session_id=service.store.current_id, turn_id=service.turn_id):
                    service.trace.emit('http.request', request_id=request_id, method=request.method,
                                       stage=route.lstrip('/') or 'root', status_code=status, duration_ms=round(elapsed, 2),
                                       level='warn' if status >= 400 else 'info')

    @web.middleware
    async def guard(request, handler):
        allowed_hosts = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
        if request.host not in allowed_hosts:
            raise web.HTTPForbidden(text="Invalid host")
        if request.headers.get("Origin") not in {None, f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"}:
            raise web.HTTPForbidden(text="Foreign origin")
        resource = request.match_info.route.resource
        canonical = resource.canonical if resource is not None else None
        if canonical not in {"/health", "/fixture", "/artifacts/view/{token}"}:
            supplied = request.headers.get("Authorization", "")
            if not hmac.compare_digest(supplied, "Bearer " + service.token):
                raise web.HTTPUnauthorized(text="Authentication required")
        try:
            return await handler(request)
        except (ValueError, BridgeError, RuntimeError) as error:
            return web.json_response({"error": str(error)}, status=409 if isinstance(error, BridgeError) else 400)
        except asyncio.TimeoutError:
            return web.json_response({"error": "Request timed out; no browser input was retried"}, status=504)

    app = web.Application(middlewares=[observe, guard], client_max_size=8 * 1024 * 1024)

    async def get(request):
        if request.path == "/health":
            return web.json_response({"application": "jet-browser", "version": "0.1.0", "instance": hashlib.sha256(str(service.root.resolve()).encode()).hexdigest()[:16]})
        if request.path == "/fixture":
            return web.FileResponse(RESOURCE_ROOT / "backend/jet_browser/fixture.html")
        if request.path == "/setup":
            return web.json_response(service.runtime_setup.status())
        if request.path == "/state":
            return web.json_response(service.state())
        if request.path == '/traces':
            turn_id = request.query.get('turn_id')
            if turn_id is not None and (len(turn_id) != 32 or any(c not in '0123456789abcdef' for c in turn_id)):
                raise ValueError('Use a known turn ID')
            limit = min(2000, max(1, int(request.query.get('limit', '2000'))))
            return web.json_response(service.trace.snapshot(service.store.current_id, turn_id=turn_id, limit=limit))
        if request.path == '/metrics':
            return web.json_response(service.trace.metrics())
        if request.path == "/browser/commands":
            return web.json_response(await service.bridge.next_command(request.query.get("host_id")))
        raise web.HTTPNotFound()

    async def post(request):
        body = await request.json()
        if not isinstance(body, dict):
            raise ValueError("Expected an object")
        path = request.path
        if path == '/setup/install':
            result = await service.runtime_setup.install(body.get('model_id'))
        elif path == '/setup/cancel':
            result = await service.runtime_setup.cancel()
        elif path == '/setup/login':
            result = await service.runtime_setup.login()
        elif path == "/browser/sync":
            service.bridge.sync(body)
            result = {"ok": True}
        elif path == "/browser/results":
            result = {"accepted": service.bridge.resolve(body)}
        elif path == "/settings":
            result = service.update_settings(body)
        elif path == '/sessions':
            result = await service.select_session()
        elif path == '/sessions/select':
            if not isinstance(body.get('session_id'), str):
                raise ValueError('Select a known conversation id')
            result = await service.select_session(body['session_id'])
        elif path == "/tasks":
            if service.busy:
                raise ValueError('A conversation turn or browser task is already running')
            result = service.submit_task(body.get("goal"), body.get("model", service.settings['local_model']), body.get("tab_id"))
        elif path == "/tasks/stop":
            result = service.tasks.stop() or {"status": "idle"}
        elif path == "/chat":
            result = await service.chat(body.get("message"))
        elif path == "/chat/stop":
            result = await service.stop()
        elif path == "/mcp/tool":
            if 'provider_id' in body:
                if (not service.provider_id or body['provider_id'] != service.provider_id
                        or not service.chat_job or service.chat_job.done() or service.chat_stopped.is_set()):
                    raise BridgeError('This provider turn has ended; no late browser tool was dispatched')
            result = await service.tool(body.get("name"), body.get("arguments", {}))
        else:
            raise web.HTTPNotFound()
        return web.json_response(result)

    for path in ("/health", "/state", "/setup", "/fixture", "/browser/commands", "/traces", "/metrics"):
        app.router.add_get(path, get)
    for path in ("/setup/install", "/setup/cancel", "/setup/login", "/browser/sync", "/browser/results", "/settings", "/sessions", "/sessions/select", "/tasks", "/tasks/stop", "/chat", "/chat/stop", "/mcp/tool"):
        app.router.add_post(path, post)
    workflow_routes(app, service)
    collection_tools.register_routes(app, service)
    register_workspace_routes(app, service)

    async def cleanup(_):
        await service.stop()
        service.bridge.fail_pending("Jet Browser service is shutting down")
        if service.grok:
            await service.grok.close()
        if service.tasks.future:
            try:
                await asyncio.wait_for(asyncio.shield(service.tasks.future), 20)
            except (TimeoutError, asyncio.CancelledError):
                pass
        await service.runtime_setup.close()
        await service.text_runtime.close()
        service.workflow_store.close()
        service.store.close()
        service.collection_store.close()
        service.workspace.close()
        service.trace.emit('service.closed')
        service.trace.close()
    app.on_cleanup.append(cleanup)
    return app


def main():
    service = Service()
    web.run_app(create_app(service), host="127.0.0.1", port=PORT, access_log=None, print=None)


if __name__ == "__main__":
    main()
