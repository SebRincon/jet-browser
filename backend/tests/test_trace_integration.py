import asyncio
import json

import pytest
from aiohttp import ClientSession
from aiohttp.test_utils import TestServer

from jet_browser.bridge import BridgeError, BrowserBridge
from jet_browser.service import PORT, Service, create_app
from jet_browser.tracing import TraceStore


async def test_native_ack_and_error_keep_original_turn_across_http_tasks(tmp_path):
    trace = TraceStore(tmp_path)
    bridge = BrowserBridge(trace=trace)
    bridge.sync({'host_id': 'host', 'active_tab_id': 'tab', 'tabs': [{'id': 'tab'}]})
    async def turn():
        with trace.bind(session_id='session', turn_id='turn'):
            with trace.span('chat.turn'):
                with pytest.raises(BridgeError, match='lost focus'):
                    await bridge.call('tab', 'Input.insertText', {'text': 'secret-input@example.test'})
    task = asyncio.create_task(turn())
    command = await bridge.next_command('host')
    # Simulates an unrelated HTTP request context returning the native reply.
    bridge.resolve({'host_id': 'host', 'command_id': command['command_id'], 'error': 'lost focus'})
    await task
    events = trace.recent('session', 'turn', limit=100)
    trace_ids = {event['trace_id'] for event in events}
    assert len(trace_ids) == 1 and None not in trace_ids
    ack = next(event for event in events if event['event'] == 'browser.command.ack')
    dispatch = next(event for event in events if event['event'] == 'browser.command.dispatched')
    assert ack['span_id'] == dispatch['span_id']
    assert ack['attributes']['status'] == 'error'
    assert ack['attributes']['command_id'] == command['command_id']
    assert any(event['level'] == 'error' for event in events)
    assert 'secret-input' not in json.dumps(events)
    trace.close()


async def test_trace_endpoints_private_scoped_and_poll_metrics_sane(tmp_path):
    service = Service(tmp_path)
    first = service.store.current_id
    with service.trace.bind(session_id=first, turn_id='a' * 32):
        service.trace.emit('chat.completed', status='done')
    async with TestServer(create_app(service)) as server, ClientSession() as client:
        headers = {'Host': f'127.0.0.1:{PORT}'}
        assert (await client.get(server.make_url('/traces'), headers=headers)).status == 401
        assert (await client.get(server.make_url('/metrics'), headers=headers)).status == 401
        headers['Authorization'] = 'Bearer ' + service.token
        result = await client.get(server.make_url('/traces'), headers=headers)
        assert result.headers['X-Request-ID']
        data = await result.json()
        assert data['turn_id'] == 'a' * 32
        await service.select_session()
        result = await client.get(server.make_url('/traces?turn_id=' + 'a' * 32), headers=headers)
        assert (await result.json())['events'] == []
        before = len(service.trace.recent(None, limit=2000))
        assert (await client.get(server.make_url('/state'), headers=headers)).status == 200
        assert len(service.trace.recent(None, limit=2000)) == before
        metrics = await client.get(server.make_url('/metrics'), headers=headers)
        assert (await metrics.json())['http.GET./state']['error_count'] == 0


async def test_local_turn_trace_and_history_have_same_stable_turn(tmp_path):
    service = Service(tmp_path)
    class ListRouter:
        def route(self, *args):
            return {'id': 'route', 'decision': 'local', 'operation': 'list_tabs', 'model': 'fake'}
        def prepare(self, *args):
            return {'operation': 'list_tabs'}
    service.router = ListRouter()
    started = await service.chat('Show my open tabs')
    await service.chat_job
    snapshot = service.state()['trace']
    assert snapshot['turn_id'] == started['turn_id']
    assert {message['turn_id'] for message in service.messages} == {started['turn_id']}
    assert service.store.routes()[0]['turn_id'] == started['turn_id']
    assert {'chat.turn.start', 'route.updated', 'local.result', 'chat.completed', 'chat.turn.end'} <= {
        event['event'] for event in snapshot['events']}
    assert snapshot['summary']['error_count'] == 0
    service.store.close()
    service.trace.close()


async def test_stop_cancels_queued_native_tool_and_rejects_late_provider(tmp_path):
    service = Service(tmp_path)
    service.bridge.sync({'host_id': 'host', 'active_tab_id': 'tab', 'tabs': [{'id': 'tab'}]})
    service.provider_id = 'old-provider'
    pending = asyncio.create_task(service.tool('open_url', {'tab_id': 'tab', 'url': 'https://example.com'}))
    await asyncio.sleep(0)
    assert len(service.bridge.pending) == 1
    await service.stop()
    with pytest.raises(BridgeError, match='Stopped before native dispatch'):
        await pending
    assert not service.bridge.pending
    async with TestServer(create_app(service)) as server, ClientSession() as client:
        headers = {'Host': f'127.0.0.1:{PORT}', 'Authorization': 'Bearer ' + service.token}
        result = await client.post(server.make_url('/mcp/tool'), headers=headers, json={
            'provider_id': 'old-provider', 'name': 'open_url', 'arguments': {'url': 'https://example.com'}})
        assert result.status == 409
        assert 'no late browser tool' in (await result.json())['error']
        assert not service.bridge.pending


async def test_internal_tool_preserves_intermediate_parent_span(tmp_path):
    service = Service(tmp_path)
    service.turn_id = 'turn'
    with service.trace.bind(session_id=service.store.current_id, turn_id='turn'):
        with service.trace.span('chat.turn'):
            service.turn_context = service.trace.capture()
            with service.trace.span('browser.settle'):
                parent = service.trace.current_context()['span_id']
                await service.tool('list_tabs', {})
    event = next(row for row in service.trace.recent(service.store.current_id) if row['event'] == 'browser.tool.start')
    assert event['parent_span_id'] == parent
    service.store.close()
    service.trace.close()


async def test_stop_finishes_started_mouse_action_but_cancels_queued_navigation(tmp_path):
    import threading

    from jet_browser.bridge import ThreadBridge
    service = Service(tmp_path)
    service.bridge.sync({'host_id': 'host', 'active_tab_id': 'tab', 'tabs': [{'id': 'tab'}]})
    transport = ThreadBridge(service.bridge, asyncio.get_running_loop(), 'tab', threading.Event())
    transport.action_active = True
    def click():
        transport.call('Input.dispatchMouseEvent', type='mousePressed')
        transport.call('Input.dispatchMouseEvent', type='mouseReleased')
    clicked = asyncio.create_task(asyncio.to_thread(click))
    pressed = await service.bridge.next_command('host')
    service.bridge.resolve({'host_id': 'host', 'command_id': pressed['command_id'], 'result': {}})
    for _ in range(100):
        if any(item.request['params'].get('type') == 'mouseReleased' for item in service.bridge.pending.values()):
            break
        await asyncio.sleep(.001)
    else:
        pytest.fail('Mouse release did not queue')
    navigate = asyncio.create_task(service.bridge.call('tab', 'Page.navigate', {'url': 'https://example.com'}))
    await asyncio.sleep(0)
    await service.stop()
    with pytest.raises(BridgeError, match='Stopped before native dispatch'):
        await navigate
    released = await service.bridge.next_command('host')
    assert released['params']['type'] == 'mouseReleased'
    service.bridge.resolve({'host_id': 'host', 'command_id': released['command_id'], 'result': {}})
    await clicked
    service.store.close()
    service.trace.close()
