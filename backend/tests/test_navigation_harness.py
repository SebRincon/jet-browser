import importlib.util
import json
from pathlib import Path

import pytest


def _script():
    path = Path(__file__).resolve().parents[2] / 'scripts' / 'check_navigation_goals.py'
    spec = importlib.util.spec_from_file_location('check_navigation_goals', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _page(url, title='', heading=''):
    return {'url': url, 'title': title, 'heading': heading}


def test_oracles_reject_spoof_wrong_kind_topic_and_playlist_watch_mix():
    module = _script()
    channel = _page('https://www.youtube.com/@nasa', 'NASA - YouTube', 'NASA')
    assert module.oracle(channel, 'channel', 'NASA')
    assert not module.oracle(_page('https://youtube.com.evil/@nasa', 'NASA', 'NASA'), 'channel', 'NASA')
    assert not module.oracle(channel, 'video', 'Artemis')

    wrong_topic = _page('https://www.youtube.com/watch?v=dQw4w9WgxcQ', 'Cats', 'Cats')
    assert not module.oracle(wrong_topic, 'video', 'Artemis')
    artemis = _page('https://www.youtube.com/watch?v=abcdefghijk', 'Artemis II launch', 'Artemis II')
    assert module.oracle(artemis, 'video', 'Artemis')

    watch_with_list = _page(
        'https://www.youtube.com/watch?v=abcdefghijk&list=PLnasaPlaylist01',
        'NASA',
        'NASA',
    )
    playlist = _page('https://www.youtube.com/playlist?list=PLnasaPlaylist01', 'NASA playlist - YouTube', 'NASA')
    assert not module.oracle(watch_with_list, 'playlist', 'NASA')
    assert module.oracle(playlist, 'playlist', 'NASA')
    assert not module.oracle(playlist, 'video', 'Artemis')


def test_home_results_and_tracking_query_rules():
    module = _script()
    assert module.oracle(_page('https://www.youtube.com/', 'YouTube'), 'home', 'youtube.com')
    assert module.oracle(_page('https://github.com/', 'GitHub'), 'home', 'github.com')
    assert not module.oracle(_page('https://www.youtube.com/feed', 'YouTube'), 'home', 'youtube.com')
    assert not module.oracle(_page('https://www.youtube.com/', 'Home'), 'home', 'youtube.com')
    assert not module.oracle(_page('https://www.youtube.com/?feature=feed', 'YouTube'), 'home', 'youtube.com')
    results = _page('https://www.youtube.com/results?search_query=NASA', 'NASA - YouTube', 'Search')
    assert module.oracle(results, 'results', 'NASA')
    assert not module.oracle(_page('https://www.youtube.com/results?search_query=Space', 'NASA'), 'results', 'NASA')
    dropped = _page('https://m.youtube.com/watch?v=abcdefghijk', 'Artemis', 'Artemis')
    assert module.oracle(dropped, 'video', 'Artemis')
    assert not module.oracle(_page('https://www.youtube.com/watch?v=short', 'Artemis', 'Artemis'), 'video', 'Artemis')


def test_help_and_import_make_no_api_or_token_reads(monkeypatch):
    def boom(*_args, **_kwargs):
        raise AssertionError('api')

    monkeypatch.setattr('urllib.request.urlopen', boom)
    module = _script()
    monkeypatch.setattr(module.intent, '_headers', boom)
    with pytest.raises(SystemExit) as help_exit:
        module.main(['--help'])
    assert help_exit.value.code == 0
    with pytest.raises(SystemExit) as missing:
        module.main([])
    assert missing.value.code == 2


def test_case_validation_rejects_unknown_before_run(monkeypatch):
    module = _script()
    monkeypatch.setattr(module, '_headers', lambda: (_ for _ in ()).throw(AssertionError('token')))
    monkeypatch.setattr(module, 'run', lambda keys: (_ for _ in ()).throw(AssertionError('run')))
    with pytest.raises(SystemExit) as bad:
        module.main(['--run', '--case', 'watch'])
    assert bad.value.code == 2
    parser = module.parse_args()
    args = parser.parse_args(['--run', '--case', 'video', '--case', 'home_google'])
    assert args.cases == ['video', 'home_google']
    assert [case['key'] for case in module.selected_cases(module.CASE_KEYS)] == list(module.CASE_KEYS)


def test_oracle_rejects_unsafe_urls_and_unknown_kind():
    module = _script()
    good = _page('https://www.youtube.com/@nasa', 'NASA', 'NASA')
    assert module.oracle(good, 'channel', 'NASA')
    assert not module.oracle(_page('javascript:https://www.youtube.com/@nasa', 'NASA', 'NASA'), 'channel', 'NASA')
    assert not module.oracle(_page('https://user:secret@www.youtube.com/@nasa', 'NASA', 'NASA'), 'channel', 'NASA')
    assert not module.oracle(_page('https://www.youtube.com:8443/@nasa', 'NASA', 'NASA'), 'channel', 'NASA')
    assert not module.oracle(_page('https://www.youtube.com:abc/@nasa', 'NASA', 'NASA'), 'channel', 'NASA')
    assert not module.oracle(_page('https://www.youtube.com:99999/@nasa', 'NASA', 'NASA'), 'channel', 'NASA')
    assert not module.oracle(_page('file:///tmp/youtube', 'YouTube', ''), 'home', 'youtube.com')
    assert not module.oracle(good, 'article', 'NASA')
    assert not module.oracle(_page('https://music.youtube.com/@nasa', 'NASA', 'NASA'), 'channel', 'NASA')
    assert 'canonical_title' in module._PAGE_KEYS
    assert 'channel_identity' in module._PAGE_KEYS
    assert 'document_id' in module._PAGE_KEYS
    assert 'navigation_error' in module._PAGE_KEYS


_MOCK_HEADERS = {'Authorization': 'Bearer test-secret', 'Content-Type': 'application/json'}
_PAGES = {
    'Bring me to YouTube': _page('https://www.youtube.com/', 'YouTube'),
    'Go to GitHub': _page('https://github.com/', 'GitHub'),
    'Take me to Wikipedia': _page('https://www.wikipedia.org/', 'Wikipedia'),
    'Open the Google homepage': _page('https://www.google.com/', 'Google'),
    "Open NASA's YouTube channel": _page('https://www.youtube.com/@nasa', 'NASA - YouTube', 'NASA'),
    'Find a YouTube video about Artemis': _page('https://www.youtube.com/watch?v=abcdefghijk', 'Artemis II', 'Artemis II'),
    'Open a NASA playlist on YouTube': _page('https://www.youtube.com/playlist?list=PLnasaPlaylist01', 'NASA', 'NASA'),
    'Show YouTube search results for NASA': _page('https://www.youtube.com/results?search_query=NASA', 'NASA - YouTube'),
}


def _qa_state(turn, routes, busy=False, session='qa', tab='qa-tab'):
    return {
        'busy': busy,
        'browser': {'online': True, 'active_tab_id': tab},
        'session': {'id': session},
        'trace': {'turn_id': turn},
        'routes': routes,
    }


def _local_route(turn):
    return [{'turn_id': turn, 'decision': 'local', 'status': 'done', 'grok_calls': 0}]


def _prepare(module, monkeypatch, tmp_path):
    monkeypatch.setattr(module, 'ROOT', tmp_path)
    monkeypatch.setattr(module, '_headers', lambda: dict(_MOCK_HEADERS))

    def unreadable(*_args, **_kwargs):
        raise AssertionError('token')

    monkeypatch.setattr(module.intent, '_headers', unreadable)
    monkeypatch.setattr('urllib.request.urlopen', unreadable)


def _artifact(tmp_path):
    files = list((tmp_path / 'artifacts').glob('*.json'))
    assert len(files) == 1
    text = files[0].read_text()
    assert 'test-secret' not in text
    return json.loads(text)


def _run(module, keys):
    try:
        module.run(keys)
    except SystemExit as error:
        return error
    return None


def _before():
    return _qa_state(None, [], session='user', tab='user-tab')


def _evidence(case):
    page = dict(_PAGES[case['prompt']])
    page['canonical_title'] = page['title']
    page['channel_identity'] = '@nasa' if case['key'] == 'channel' else ''
    page['document_id'] = case['key']
    page['navigation_error'] = None
    return page


def _play(steps):
    queue = list(steps)
    seen = []

    def fake(path, body=None, headers=None):
        assert headers == _MOCK_HEADERS
        assert queue, 'unexpected ' + path
        expected, result = queue.pop(0)
        seen.append(path)
        assert path == expected, (seen, expected)
        if isinstance(result, BaseException):
            raise result
        return result

    fake.seen = seen
    fake.left = queue
    return fake


def _open(extra):
    return [('/state', _before()), ('/sessions', {'id': 'qa'}), ('/mcp/tool', {'tab_id': 'qa-tab'}), *extra]


def _restore():
    return [
        ('/state', _qa_state('ours', [])),
        ('/mcp/tool', {}),
        ('/mcp/tool', {}),
        ('/sessions/select', {}),
    ]


def test_run_selected_cases_pass_and_restore(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    steps = _open([])
    previous = None
    for index, case in enumerate(module.CASES, start=1):
        turn = 't' + str(index)
        steps.append(('/state', _qa_state(previous, [])))
        steps.append(('/chat', {'turn_id': turn}))
        steps.append(('/state', _qa_state(turn, _local_route(turn))))
        steps.append(('/mcp/tool', _evidence(case)))
        previous = turn
    steps.extend([
        ('/state', _qa_state('t8', _local_route('t8'))),
        ('/mcp/tool', {}),
        ('/mcp/tool', {}),
        ('/sessions/select', {}),
    ])
    fake = _play(steps)
    monkeypatch.setattr(module.intent, 'call', fake)
    assert _run(module, module.CASE_KEYS) is None
    assert fake.left == []
    assert '/chat/stop' not in fake.seen
    saved = _artifact(tmp_path)
    assert [row['key'] for row in saved['cases']] == list(module.CASE_KEYS)
    assert all(row['passed'] for row in saved['cases'])
    assert saved['error'] is None and saved['stop_error'] is None and saved['cleanup_error'] is None
    assert saved['cases'][0]['page']['canonical_title'] == 'YouTube'
    assert saved['cases'][0]['page']['document_id'] == 'home_youtube'
    assert saved['cases'][0]['page']['navigation_error'] is None


def test_preflight_busy_makes_no_mutations(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    calls = []

    def fake(path, body=None, headers=None):
        calls.append((path, body))
        if path == '/state':
            return {'busy': True, 'browser': {'online': True, 'active_tab_id': 'user-tab'}, 'session': {'id': 'user'}}
        raise AssertionError(path)

    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(RuntimeError, match='busy'):
        module.run(['home_youtube'])
    assert calls == [('/state', None)]
    saved = _artifact(tmp_path)
    assert saved['cases'] == []
    assert saved['error']['type'] == 'RuntimeError'
    assert saved['stop_error'] is None and saved['cleanup_error'] is None


def test_takeover_never_stops_a_new_turn_or_restores(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    calls = []

    def fake(path, body=None, headers=None):
        name = body.get('name') if isinstance(body, dict) else None
        action = (body.get('arguments') or {}).get('action') if isinstance(body, dict) else None
        calls.append((path, name, action))
        if path == '/state' and sum(item[0] == '/state' for item in calls) == 1:
            return _qa_state(None, [], session='user', tab='user-tab')
        if path == '/sessions':
            return {'id': 'qa'}
        if path == '/mcp/tool' and name == 'open_url':
            return {'tab_id': 'qa-tab'}
        if path == '/state' and sum(item[0] == '/chat' for item in calls) == 0:
            return _qa_state(None, [])
        if path == '/chat':
            return {'turn_id': 'ours'}
        if path == '/state':
            return _qa_state('theirs', [], busy=True, session='user', tab='user-tab')
        raise AssertionError(path)

    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(RuntimeError, match='session'):
        module.run(['video'])
    assert sum(item[0] == '/chat' for item in calls) == 1
    assert not any(item[0] == '/chat/stop' for item in calls)
    assert not any(item[0] == '/sessions/select' for item in calls)
    assert [item for item in calls if item[0] == '/mcp/tool'] == [('/mcp/tool', 'open_url', None)]
    saved = _artifact(tmp_path)
    assert saved['cases'][0]['passed'] is False
    assert saved['cases'][0]['key'] == 'video'
    assert 'session' in saved['cases'][0]['error']['detail']
    assert saved['error']['detail'] == saved['cases'][0]['error']['detail']


def test_tab_takeover_stops_only_our_turn_and_skips_restore(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    taken = _qa_state('ours', [], busy=True, tab='user-tab')
    fake = _play(_open([
        ('/state', _qa_state(None, [])),
        ('/chat', {'turn_id': 'ours'}),
        ('/state', taken),
        ('/chat/stop', {}),
        ('/state', taken),
    ]))
    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(RuntimeError, match='tab'):
        module.run(['video'])
    assert fake.left == []
    assert fake.seen.count('/chat/stop') == 1
    assert '/sessions/select' not in fake.seen
    saved = _artifact(tmp_path)
    assert len(saved['cases']) == 1 and saved['cases'][0]['passed'] is False


def test_transport_failure_stops_own_turn_once_then_restores(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    fake = _play(_open([
        ('/state', _qa_state(None, [])),
        ('/chat', {'turn_id': 'ours'}),
        ('/state', OSError('socket down Bearer test-secret')),
        ('/state', _qa_state('ours', [], busy=True)),
        ('/chat/stop', {}),
        *_restore(),
    ]))
    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(OSError, match='socket down'):
        module.run(['channel'])
    assert fake.left == []
    assert fake.seen.count('/chat/stop') == 1
    assert fake.seen.count('/sessions/select') == 1
    saved = _artifact(tmp_path)
    assert saved['cases'][0]['passed'] is False
    assert saved['cases'][0]['routes'] == []
    assert 'test-secret' not in saved['error']['detail']
    assert saved['error']['type'] == 'OSError'
    assert saved['stop_error'] is None and saved['cleanup_error'] is None


def test_lost_ownership_skips_restore(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    calls = []

    def fake(path, body=None, headers=None):
        calls.append(path)
        if path == '/state' and calls.count('/sessions') == 0:
            return _qa_state(None, [], session='user', tab='user-tab')
        if path == '/sessions':
            return {'id': 'qa'}
        if path == '/mcp/tool' and isinstance(body, dict) and body.get('name') == 'open_url':
            return {'tab_id': 'qa-tab'}
        if path == '/state' and calls.count('/chat') == 0:
            return _qa_state('ours', _local_route('ours'), session='other', tab='other-tab')
        raise AssertionError(path)

    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(RuntimeError, match='Lost QA'):
        module.run(['results'])
    assert calls == ['/state', '/sessions', '/mcp/tool', '/state', '/state']
    saved = _artifact(tmp_path)
    assert saved['cases'][0]['key'] == 'results' and saved['cases'][0]['passed'] is False
    assert saved['cleanup_error'] is None


def test_timeout_records_partial_row(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    now = {'t': 0.0}
    monkeypatch.setattr(module.time, 'monotonic', lambda: now['t'])
    monkeypatch.setattr(module.time, 'sleep', lambda _seconds: now.__setitem__('t', now['t'] + 80))
    seen = [{'turn_id': 'ours', 'decision': 'local', 'status': 'running', 'grok_calls': 0}]
    fake = _play(_open([
        ('/state', _qa_state(None, [])),
        ('/chat', {'turn_id': 'ours'}),
        ('/state', _qa_state('ours', seen, busy=True)),
        ('/chat/stop', {}),
        *_restore(),
    ]))
    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(RuntimeError, match='Timeout'):
        module.run(['video', 'playlist'])
    assert fake.left == []
    assert fake.seen.count('/chat') == 1
    assert fake.seen.count('/chat/stop') == 1
    saved = _artifact(tmp_path)
    assert [row['key'] for row in saved['cases']] == ['video']
    assert saved['cases'][0]['passed'] is False
    assert saved['cases'][0]['routes'] == seen
    assert saved['cases'][0]['elapsed_ms'] >= 75000
    assert 'Timeout' in saved['error']['detail']
    assert saved['stop_error'] is None and saved['cleanup_error'] is None


def test_cleanup_failure_preserves_primary_error(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    fake = _play(_open([
        ('/state', _qa_state(None, [])),
        ('/chat', {'turn_id': 'ours'}),
        ('/state', OSError('read failed')),
        ('/state', _qa_state('ours', [], busy=True)),
        ('/chat/stop', {}),
        ('/state', _qa_state('ours', [])),
        ('/mcp/tool', RuntimeError('close failed Bearer test-secret')),
    ]))
    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(OSError, match='read failed'):
        module.run(['home_github'])
    assert fake.left == []
    assert fake.seen.count('/chat/stop') == 1
    assert fake.seen.count('/mcp/tool') == 2
    saved = _artifact(tmp_path)
    assert saved['error']['type'] == 'OSError'
    assert 'read failed' in saved['error']['detail']
    assert saved['cleanup_error']['type'] == 'RuntimeError'
    assert 'test-secret' not in saved['cleanup_error']['detail']
    assert 'close failed' in saved['cleanup_error']['detail']
    assert saved['cases'][0]['passed'] is False


def test_mutation_failure_is_not_retried(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    fake = _play([
        ('/state', _before()),
        ('/sessions', {'id': 'qa'}),
        ('/mcp/tool', RuntimeError('open failed')),
        ('/state', _qa_state(None, [], tab='user-tab')),
        ('/sessions/select', {}),
    ])
    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(RuntimeError, match='open failed'):
        module.run(module.CASE_KEYS)
    assert fake.left == []
    assert fake.seen.count('/mcp/tool') == 1
    assert '/chat' not in fake.seen
    saved = _artifact(tmp_path)
    assert saved['cases'] == []
    assert saved['error']['detail'] == 'open failed'


def test_read_page_failure_keeps_one_partial_row(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    route = _local_route('ours')
    fake = _play(_open([
        ('/state', _qa_state(None, [])),
        ('/chat', {'turn_id': 'ours'}),
        ('/state', _qa_state('ours', route)),
        ('/mcp/tool', RuntimeError('page unread')),
        *_restore(),
    ]))
    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(RuntimeError, match='page unread'):
        module.run(['playlist', 'results'])
    assert fake.left == []
    assert fake.seen.count('/chat') == 1
    saved = _artifact(tmp_path)
    assert [row['key'] for row in saved['cases']] == ['playlist']
    assert saved['cases'][0]['passed'] is False
    assert saved['cases'][0]['routes'] == route
    assert 'page' not in saved['cases'][0]
    assert 'page unread' in saved['cases'][0]['error']['detail']


def test_each_handoff_stops_its_own_turn_once(monkeypatch, tmp_path):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)

    def grok(turn):
        return [{'turn_id': turn, 'decision': 'grok', 'status': 'done', 'grok_calls': 1}]

    fake = _play(_open([
        ('/state', _qa_state(None, [])),
        ('/chat', {'turn_id': 't1'}),
        ('/state', _qa_state('t1', grok('t1'), busy=True)),
        ('/chat/stop', {}),
        ('/state', _qa_state('t1', grok('t1'))),
        ('/mcp/tool', _page('https://www.youtube.com/watch?v=abcdefghijk', 'Artemis', 'Artemis')),
        ('/state', _qa_state('t1', grok('t1'))),
        ('/chat', {'turn_id': 't2'}),
        ('/state', _qa_state('t2', grok('t2'), busy=True)),
        ('/chat/stop', {}),
        ('/state', _qa_state('t2', grok('t2'))),
        ('/mcp/tool', _page('https://www.youtube.com/playlist?list=PLnasaPlaylist01', 'NASA', 'NASA')),
        ('/state', _qa_state('t2', grok('t2'))),
        ('/mcp/tool', {}),
        ('/mcp/tool', {}),
        ('/sessions/select', {}),
    ]))
    monkeypatch.setattr(module.intent, 'call', fake)
    assert _run(module, ['video', 'playlist']) is not None
    assert fake.left == []
    chats = [index for index, path in enumerate(fake.seen) if path == '/chat']
    stops = [index for index, path in enumerate(fake.seen) if path == '/chat/stop']
    assert len(chats) == 2 and len(stops) == 2
    assert chats[0] < stops[0] < chats[1] < stops[1]


@pytest.mark.parametrize('busy', [True, False])
def test_same_session_new_turn_does_not_stop_or_restore(monkeypatch, tmp_path, busy):
    module = _script()
    _prepare(module, monkeypatch, tmp_path)
    fake = _play(_open([
        ('/state', _qa_state(None, [])),
        ('/chat', {'turn_id': 'ours'}),
        ('/state', _qa_state('theirs', [], busy=busy)),
    ]))
    monkeypatch.setattr(module.intent, 'call', fake)
    with pytest.raises(RuntimeError, match='turn'):
        module.run(['video', 'playlist'])
    assert fake.left == []
    assert fake.seen.count('/chat') == 1
    assert '/chat/stop' not in fake.seen
    assert '/sessions/select' not in fake.seen
    assert fake.seen.count('/mcp/tool') == 1
    saved = _artifact(tmp_path)
    assert [row['key'] for row in saved['cases']] == ['video']
    assert saved['cases'][0]['passed'] is False


def test_artifact_names_stay_unique(tmp_path):
    module = _script()
    names = [module.artifact_path(tmp_path).name for _ in range(20)]
    assert len(set(names)) == 20
    assert all(name.startswith('navigation-goals-native-') and name.endswith('.json') for name in names)


def test_stop_once_is_the_shared_ownership_helper(monkeypatch):
    module = _script()
    assert module._stop_once is module.intent._stop_once
    assert module._cleanup is module.intent._cleanup
    seen = []

    def fake(path, body=None, headers=None):
        seen.append(path)
        return {}

    monkeypatch.setattr(module.intent, 'call', fake)
    foreign = {'busy': True, 'session': {'id': 'qa'}, 'trace': {'turn_id': 'other'}}
    module._stop_once(foreign, 'qa', 'ours', {})
    idle = {'busy': False, 'session': {'id': 'qa'}, 'trace': {'turn_id': 'ours'}}
    module._stop_once(idle, 'qa', 'ours', {})
    assert seen == []
    owned = {'busy': True, 'session': {'id': 'qa'}, 'trace': {'turn_id': 'ours'}}
    module._stop_once(owned, 'qa', 'ours', {})
    assert seen == ['/chat/stop']
