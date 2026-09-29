import asyncio
import threading

from jet_browser import tasks
from jet_browser.bridge import BrowserBridge
from jet_browser.tracing import TraceStore


async def test_diagnostic_disk_failure_keeps_completed_task_and_reports_trace(tmp_path, monkeypatch):
    trace = TraceStore(tmp_path)
    bridge = BrowserBridge(trace=trace)
    bridge.sync({'host_id': 'host', 'active_tab_id': 'tab', 'tabs': [{'id': 'tab'}]})
    class Worker:
        lock = threading.RLock()
        records = []
        def start(self, model):
            pass
    class Agent:
        def __init__(self, *args, browser, **kwargs):
            self.browser = browser
        def command(self, name):
            pass
        def snapshot(self):
            return {'status': 'done', 'page': {'url': 'https://example.com'},
                    'decisions': [], 'history': [], 'text_calls': []}
    monkeypatch.setattr(tasks, 'WORKER', Worker())
    monkeypatch.setattr(tasks, 'Agent', Agent)
    original_open = tasks.os.open
    def failing_open(path, *args, **kwargs):
        if '/tasks/' in str(path):
            raise OSError('disk failure with secret content should not appear')
        return original_open(path, *args, **kwargs)
    monkeypatch.setattr(tasks.os, 'open', failing_open)
    completed = []
    manager = tasks.TaskManager(bridge, tmp_path, lambda *args: None, completed.append, trace=trace)
    with trace.bind(session_id='session', turn_id='turn'):
        task = manager.submit('Test goal', 'lfm_rlcd', 'tab')
        result = await asyncio.wait_for(manager.wait(task['id']), 2)
    assert result['status'] == 'done'
    assert completed == [result]
    assert manager.results[task['id']] == result
    events = trace.recent('session', 'turn')
    assert any(row['event'] == 'diagnostic.write.error' for row in events)
    assert 'secret content' not in str(events)
    trace.close()



async def test_delayed_progress_cannot_overwrite_a_completed_result(tmp_path, monkeypatch):
    queued = []

    class DelayedLoop:
        def call_soon_threadsafe(self, callback):
            queued.append(callback)

    def work(task, stopped, loop, publish):
        publish({"status": "running", "steps": 1})
        return {**task, "status": "done", "steps": 2}

    manager = tasks.TaskManager(None, tmp_path, lambda *args: None)
    manager.current = {"id": "task", "status": "loading"}
    monkeypatch.setattr(manager, "_work", work)
    result = await manager._run_traced(dict(manager.current), threading.Event(), DelayedLoop())
    assert result["status"] == "done"
    # Reproduce a progress notification delivered after completion, without sleeps.
    for callback in queued:
        callback()
    assert manager.current["status"] == "done"
    assert manager.results["task"]["status"] == "done"
    assert result["steps"] == 2
