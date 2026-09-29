import asyncio
import json

from aiohttp import ClientSession
from aiohttp.test_utils import TestServer

from jet_browser.service import PORT, Service, create_app, valid_url
from jet_browser.tasks import TaskManager


async def test_auth_origin_and_identity_only_health(tmp_path):
    service = Service(tmp_path)
    async with TestServer(create_app(service)) as server, ClientSession() as client:
        headers = {"Host": f"127.0.0.1:{PORT}"}
        response = await client.get(server.make_url('/health'), headers=headers)
        health = await response.json()
        assert health["application"] == "jet-browser" and health["version"] == "0.1.0"
        assert len(health["instance"]) == 16
        assert (await client.get(server.make_url('/state'), headers=headers)).status == 401
        headers['Authorization'] = 'Bearer ' + service.token
        assert (await client.get(server.make_url('/state'), headers=headers)).status == 200
        headers['Origin'] = 'https://foreign.example'
        assert (await client.post(server.make_url('/tasks/stop'), json={}, headers=headers)).status == 403


async def test_invalid_goal_tab_and_url_cannot_dispatch(tmp_path):
    service = Service(tmp_path)
    service.bridge.sync({'host_id': 'one', 'active_tab_id': 'tab', 'tabs': [{'id': 'tab'}]})
    for value in ['file:///etc/passwd', 'javascript:alert(1)', 'https://user:pass@example.com']:
        try:
            valid_url(value)
            assert False, 'accepted unsupported URL'
        except ValueError:
            pass
    try:
        service.tasks.submit('Enter hello', 'invented_model')
        assert False
    except ValueError:
        pass
    try:
        await service.tool('task_status', {'task_id': 'wrong-id'})
        assert False
    except ValueError:
        pass
    assert not service.bridge.pending


def test_task_progress_counts_real_inference_not_zero_choice_resolution():
    result = TaskManager._progress({'history': [], 'text_calls': [{}, {}],
                                   'decisions': [{'inference_requests': 3}, {'inference_requests': 0}]}, 0)
    assert result['native_calls'] == 3
    assert result['typing_calls'] == 2


async def test_mcp_transport_does_not_expose_host_token(tmp_path):
    service = Service(tmp_path)
    state = json.dumps(service.state())
    assert service.token not in state
    assert (tmp_path / '.runtime/token').stat().st_mode & 0o077 == 0


def test_model_setting_persists_and_messages_have_stable_chronology(tmp_path):
    service = Service(tmp_path)
    service.update_settings({'local_model': 'laya_mlx'})
    assert Service(tmp_path).state()['settings']['local_model'] == 'laya_mlx'
    first = service.message('user', 'Fill the form')
    second = service.message('assistant', 'Working on it')
    assert first['id'] != second['id']
    assert first['created_at'] <= second['created_at']
    second['text'] += ' now'
    assert service.state()['messages'][1]['id'] == second['id']


async def test_unified_stop_during_provider_startup_cannot_start_a_late_prompt(tmp_path, monkeypatch):
    from jet_browser import grok

    starting = asyncio.Event()
    release = asyncio.Event()
    calls = []

    class SlowProvider:
        def __init__(self, **kwargs):
            pass

        async def start(self):
            starting.set()
            await release.wait()

        async def prompt(self, text):
            calls.append('prompt')
            return 'Late response'

        async def cancel(self):
            calls.append('cancel')

        async def close(self):
            calls.append('close')

    monkeypatch.setattr(grok, 'GrokClient', SlowProvider)
    service = Service(tmp_path)
    class RouteToGrok:
        def route(self, *args):
            return {'id': 'r1', 'decision': 'grok', 'operation': 'explain', 'model': 'fake'}
    service.router = RouteToGrok()
    await service.chat('Use the current form')
    await starting.wait()
    await service.stop()
    release.set()
    await service.chat_job
    assert 'prompt' not in calls
    assert 'close' in calls
    assert service.provider_status == 'ready'


def _stalling_provider(on_prompt):
    from jet_browser.grok import GrokStalled

    class StallingProvider:
        def __init__(self, **kwargs):
            self.emit = kwargs['emit']
            self.review_only = kwargs.get('review_only', False)

        async def start(self):
            pass

        async def prompt(self, text):
            self.emit({'type': 'status', 'status': 'running', 'stage': 'thinking', 'tool': None,
                       'completed_tools': ['list_tabs', 'workflow_sdk']})
            on_prompt()
            raise GrokStalled('Grok timed out: no provider activity for 150 s while writing the workflow. '
                              'Jet ended the turn; no tool will be retried', reason='idle', stage='thinking',
                              completed_tools=('list_tabs', 'workflow_sdk'))

        async def cancel(self):
            pass

        async def close(self):
            pass

    return StallingProvider


class _RouteToGrok:
    def route(self, *args):
        return {'id': 'r1', 'decision': 'grok', 'operation': 'collect', 'model': 'fake'}


async def test_stalled_turn_reports_that_nothing_was_saved_or_started(tmp_path, monkeypatch):
    from jet_browser import grok

    seen_stage = []
    service = Service(tmp_path)
    monkeypatch.setattr(grok, 'GrokClient', _stalling_provider(
        lambda: seen_stage.append(service.state()['provider']['stage'])))
    service.router = _RouteToGrok()
    await service.chat('Organize my first 100 bookmarks')
    await service.chat_job
    reply = service.messages[-1]
    assert reply['role'] == 'assistant'
    assert 'while writing the workflow' in reply['text']
    assert 'No workflow or collection was saved or started' in reply['text']
    assert seen_stage[0]['stage'] == 'thinking' and seen_stage[0]['completed_tools'] == ['list_tabs', 'workflow_sdk']
    assert service.state()['provider']['stage'] is None
    events = [e for e in service.trace.snapshot(service.store.current_id, limit=200)['events']
              if e['event'] == 'grok.recovery.inspected']
    assert events and events[-1]['attributes']['saved_workflows'] == 0


async def test_stalled_turn_reports_a_saved_but_unstarted_workflow(tmp_path, monkeypatch):
    from test_workflow_capabilities import definition

    from jet_browser import grok

    service = Service(tmp_path)

    def save():
        service.workflow_store.save(service.store.current_id, definition())

    monkeypatch.setattr(grok, 'GrokClient', _stalling_provider(save))
    service.router = _RouteToGrok()
    await service.chat('Organize my first 100 bookmarks')
    await service.chat_job
    text = service.messages[-1]['text']
    assert '“Bookmarks” was saved (revision 1) but not started' in text
    assert not service.workflows.running
    assert service.workflows.summaries(service.store.current_id)[0]['status'] == 'prepared'


async def test_direct_and_delegated_tasks_start_the_typing_helper_first(tmp_path):
    service = Service(tmp_path)
    order = []

    async def ensure():
        order.append('ensure')

    def submit(goal, model, tab_id):
        order.append('submit')
        return {'id': 'task', 'status': 'loading'}

    service.text_runtime.ensure = ensure
    service.submit_task = submit
    async with TestServer(create_app(service)) as server, ClientSession() as client:
        headers = {"Host": f"127.0.0.1:{PORT}", 'Authorization': 'Bearer ' + service.token}
        response = await client.post(server.make_url('/tasks'), json={'goal': 'Enter Solstice in Team name', 'tab_id': 'tab'},
                                     headers=headers)
        assert response.status == 200
    assert order == ['ensure', 'submit']
    order.clear()
    await service._tool('run_task', {'goal': 'Enter Solstice in Team name', 'tab_id': 'tab'})
    assert order[:2] == ['ensure', 'submit']
