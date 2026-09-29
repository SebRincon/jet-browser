import asyncio
import threading

import pytest

from jet_browser import grok
from jet_browser.service import Service


class FakeRouter:
    def __init__(self, operation='search'):
        self.operation = operation

    def route(self, prompt, model, browser, recent, stopped):
        return {'id': 'route-' + str(len(recent)), 'model': model, 'operation': self.operation,
                'decision': 'grok' if self.operation == 'explain' else 'local',
                'reason': 'Test route', 'grok_calls': 0, 'elapsed_ms': 1}

    def prepare(self, route, prompt, browser, recent, stopped):
        return {'operation': self.operation, 'tab_id': browser['active_tab_id'],
                'url': 'https://en.wikipedia.org/wiki/Ada_Lovelace',
                'provider': 'wikipedia', 'query': 'Ada Lovelace'}


def native_fixture(service):
    service.bridge.sync({'host_id': 'test', 'active_tab_id': 'tab-a', 'tabs': [
        {'id': 'tab-a', 'url': 'https://example.com', 'title': 'Example'},
    ]})
    commands = []
    page = {'url': 'https://example.com', 'title': 'Example', 'marker': [1],
            'ready_state': 'complete', 'actions': [], 'text': 'Example'}

    async def call(tab_id, method, params=None, **kwargs):
        commands.append((tab_id, method, params))
        if method == 'Page.navigate':
            page.update(url=params['url'], title='Ada Lovelace - Wikipedia', marker=[2], text='Ada Lovelace')
            return {}
        if method == 'Runtime.evaluate':
            return {'result': {'value': dict(page)}}
        return {'tab_id': tab_id, 'active_tab_id': tab_id}

    service.bridge.call = call
    return commands


async def test_local_lookup_never_constructs_grok_and_retains_observed_result(tmp_path, monkeypatch):
    def forbidden(**kwargs):
        pytest.fail('Local lookup constructed Grok')
    monkeypatch.setattr(grok, 'GrokClient', forbidden)
    service = Service(tmp_path)
    service.router = FakeRouter()
    commands = native_fixture(service)
    await service.chat('Find the Wikipedia page for Ada Lovelace')
    await service.chat_job
    assert service.provider_status == 'ready'
    assert [c[1] for c in commands].count('Page.navigate') == 1
    route = service.store.routes()[-1]
    assert route['grok_calls'] == 0
    assert route['result']['verified'] == 'title_and_url'
    assert service.messages[-1]['source'] == 'local'
    assert 'Ada Lovelace' in service.messages[-1]['text']
    service.store.close()


async def test_grok_receives_local_history_after_restart(tmp_path, monkeypatch):
    service = Service(tmp_path)
    service.router = FakeRouter()
    native_fixture(service)
    await service.chat('Find the Wikipedia page for Ada Lovelace')
    await service.chat_job
    session_id = service.store.current_id
    service.store.close()

    prompts = []
    class Provider:
        def __init__(self, **kwargs):
            self.emit = kwargs['emit']

        async def start(self):
            pass

        async def prompt(self, text):
            prompts.append(text)
            self.emit({'type': 'text', 'text': 'You opened Ada Lovelace.'})
            return 'You opened Ada Lovelace.'

    monkeypatch.setattr(grok, 'GrokClient', Provider)
    restored = Service(tmp_path)
    restored.router = FakeRouter('explain')
    native_fixture(restored)
    await restored.chat('What page did we just open?')
    await restored.chat_job
    assert restored.store.current_id == session_id
    assert 'Ada Lovelace' in prompts[0]
    assert 'wikipedia.org/wiki/Ada_Lovelace' in prompts[0]
    assert 'CURRENT USER REQUEST:\nWhat page did we just open?' in prompts[0]
    assert 'historical data' in prompts[0]
    assert restored.messages[-1]['source'] == 'grok'
    restored.store.close()


async def test_new_session_isolates_history_without_browser_replay(tmp_path):
    service = Service(tmp_path)
    first = service.store.current_id
    service.message('user', 'Remember the Juniper form')
    commands = native_fixture(service)
    second = await service.select_session()
    assert service.messages == []
    assert service.state()['routes'] == []
    await service.select_session(first)
    assert 'Juniper' in service.messages[0]['text']
    assert second['id'] != service.store.current_id
    assert commands == []
    service.store.close()


async def test_stop_during_routing_cannot_dispatch_late_action(tmp_path):
    started, release = threading.Event(), threading.Event()
    class SlowRouter(FakeRouter):
        def route(self, *args):
            started.set()
            assert release.wait(5)
            return super().route(*args)
    service = Service(tmp_path)
    service.router = SlowRouter()
    commands = native_fixture(service)
    await service.chat('Find the Wikipedia page for Ada Lovelace')
    assert await asyncio.to_thread(started.wait, 2)
    with pytest.raises(ValueError, match='active turn'):
        await service.select_session()
    await service.stop()
    release.set()
    await asyncio.sleep(.02)
    assert commands == []
    assert service.grok is None
    assert service.messages[-1]['text'] == 'Stopped.'
    service.store.close()


async def test_history_tool_cannot_read_other_sessions(tmp_path):
    service = Service(tmp_path)
    first = service.store.current_id
    service.message('user', 'Email is sam@example.test')
    await service.select_session()
    result = await service.tool('conversation_history', {'query': 'email', 'session_id': first})
    assert 'sam@example.test' not in result['context']
    service.store.close()


async def test_app_actions_are_finite_and_preserve_tab_id(tmp_path):
    service = Service(tmp_path)
    commands = native_fixture(service)
    await service.tool('browser_action', {'action': 'back', 'tab_id': 'tab-a'})
    assert commands[-1] == ('tab-a', 'Browser.back', None)
    with pytest.raises(ValueError, match='Unsupported'):
        await service.tool('browser_action', {'action': 'eval', 'code': 'anything'})
    assert len(commands) == 1
    service.store.close()


def test_restart_marks_interrupted_work_without_replaying_it(tmp_path):
    service = Service(tmp_path)
    service.store.save_task({'id': 't-old', 'status': 'running'})
    service.store.save_route({'id': 'r-old', 'status': 'handoff'})
    service.store.close()
    restored = Service(tmp_path)
    assert restored.store.tasks()[0]['status'] == 'stopped'
    assert restored.store.routes()[0]['status'] == 'stopped'
    assert restored.tasks.future is None
    assert restored.grok is None
    restored.store.close()


async def test_continue_cannot_replay_older_work_or_move_it_to_a_different_tab(tmp_path):
    from jet_browser.conversation import execute_local
    service = Service(tmp_path)
    service.store.save_task({'id': 'old', 'created_at': 1, 'status': 'blocked', 'tab_id': 'tab-old', 'goal': 'Old goal'})
    with pytest.raises(ValueError, match='different tab'):
        await execute_local(service, {}, {'operation': 'page_task', 'tab_id': 'tab-current'}, 'continue')
    service.store.save_task({'id': 'new', 'created_at': 2, 'status': 'done', 'tab_id': 'tab-old', 'goal': 'New goal'})
    with pytest.raises(ValueError, match='not unfinished'):
        await execute_local(service, {}, {'operation': 'page_task', 'tab_id': 'tab-old'}, 'continue')
    assert service.tasks.future is None
    service.store.close()
    service.trace.close()
