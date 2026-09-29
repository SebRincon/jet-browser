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
