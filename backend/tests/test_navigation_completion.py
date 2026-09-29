"""Destination verification for homepage, explicit URL, and YouTube resources."""

import asyncio
import json
from urllib.parse import quote_plus

import pytest
from test_intent_completion import _install, _plan, _route

from jet_browser.bridge import BridgeError
from jet_browser.conversation import (
    _IDENTITY_CRITERIA,
    _IDENTITY_QUESTION,
    execute_local,
    semantic_identity_state,
)
from jet_browser.navigation_completion import (
    blocked_reason,
    explicit_url_matches,
    structural_status,
    youtube_resource,
)
from jet_browser.service import Service

_VIDEO = 'AAAAAAAAAAA'
_OTHER = 'BBBBBBBBBBB'
_LIST = 'PL0123456789ABCDEF'


def _yt(kind, query, prompt):
    search_query = query + ' playlist' if kind == 'playlist' and 'playlist' not in query.casefold() else query
    url = 'https://www.youtube.com/results?search_query=' + quote_plus(search_query)
    return {
        'operation': 'search', 'tab_id': 'tab-a', 'provider': 'youtube', 'query': search_query,
        'outcome': 'search_results' if kind == 'search_results' else 'destination', 'url': url,
        'navigation_goal': {
            'provider': 'youtube', 'kind': kind, 'request': prompt, 'query': query,
            'tab_id': 'tab-a', 'url': url,
        },
    }


def _page(url, title, heading, text='A meaningful public page with enough visible text for a settled document.',
          actions=(), canonical=None, marker='doc-page'):
    return {
        'url': url, 'title': title, 'heading': heading, 'lead': '', 'text': text,
        'ready_state': 'complete', 'marker': [marker], 'actions': list(actions),
        'canonical_url': canonical if canonical is not None else url,
        'canonical_title': heading or title,
    }


def _link(identity, label, href, context=''):
    action = {'id': identity, 'role': 'link', 'kind': 'click', 'label': label, 'href': href}
    if context:
        action['context'] = context
    return action


def _results(plan, actions):
    return _page(plan['url'], 'Search results - YouTube', 'Search results', actions=actions, marker='doc-results',
                 canonical=plan['url'])


def _watch(video, heading, marker='doc-video'):
    url = f'https://www.youtube.com/watch?v={video}'
    return _page(url, heading + ' - YouTube', heading, canonical=url, marker=marker)


@pytest.fixture(autouse=True)
def fast_navigation_hydrate(monkeypatch):
    monkeypatch.setattr('jet_browser.conversation._HYDRATE_DEADLINE', 0.0)
    monkeypatch.setattr('jet_browser.conversation._HYDRATE_INTERVAL', 0.0)


def _goal_events(service):
    return [row for row in service.trace._events if row['event'] in {'route.goal', 'route.outcome'}]


async def test_channel_video_and_playlist_complete_only_after_identity(tmp_path):
    channel_prompt = 'open the NASA youtube channel'
    channel_plan = _yt('channel', 'NASA', channel_prompt)
    channel = _page('https://www.youtube.com/@NASA', 'NASA - YouTube', 'NASA', canonical='https://www.youtube.com/@NASA',
                    marker='doc-channel')
    service = Service(tmp_path)
    commands = _install(service, [_results(channel_plan, [_link('e1', 'NASA', 'https://www.youtube.com/@NASA')]), channel],
                        ['e1', 'yes'])
    route = _route()
    result = await execute_local(service, route, channel_plan, channel_prompt)
    assert result['verified'] is False
    assert result['assessment'] == 'local_model'
    assert result['structural'] == 'channel'
    assert result['observed_page']['url'] == 'https://www.youtube.com/@NASA'
    assert route['outcome']['kind'] == 'assessment'
    assert route['outcome']['structural'] == 'channel'
    assert route['outcome']['reason'] == 'local_model'
    assert channel_plan['navigation_goal']['tab_id'] == 'tab-a'
    blob = json.dumps(_goal_events(service))
    assert '"kind": "channel"' in blob
    assert 'NASA' not in blob
    service.store.close()
    service.trace.close()

    video_prompt = 'find a youtube video about shuttle launch'
    video_plan = _yt('video', 'shuttle launch', video_prompt)
    video = _watch(_VIDEO, 'Shuttle launch')
    service = Service(tmp_path)
    commands = _install(service, [
        _results(video_plan, [_link('e1', 'Shuttle launch', video['url'])]), video,
    ], ['e1', 'yes'])
    result = await execute_local(service, _route(), video_plan, video_prompt)
    assert result['verified'] is False and result['structural'] == 'video'
    assert [item[1]['url'] for item in commands if item[0] == 'Page.navigate'][-1] == video['url']
    service.store.close()
    service.trace.close()

    playlist_prompt = 'open the NASA Moon Tunes playlist on youtube'
    playlist_plan = _yt('playlist', 'NASA Moon Tunes', playlist_prompt)
    playlist_url = f'https://www.youtube.com/playlist?list={_LIST}'
    card = _link('e1', 'NASA Moon Tunes', f'https://www.youtube.com/watch?v={_VIDEO}&list={_LIST}')
    full = _link('e2', 'View full playlist', playlist_url, context='NASA Moon Tunes Playlist')
    playlist = _page(playlist_url, 'NASA Moon Tunes Playlist - YouTube', 'NASA Moon Tunes Playlist',
                     canonical=playlist_url, marker='doc-playlist')
    service = Service(tmp_path)
    _install(service, [_results(playlist_plan, [card, full]), playlist], ['e2', 'yes'])
    seen = []
    choose = service.router.choose

    def record(model, state, question, criteria, stopped=None):
        seen.append(criteria)
        return choose(model, state, question, criteria, stopped)

    service.router.choose = record
    result = await execute_local(service, _route(), playlist_plan, playlist_prompt)
    assert result['structural'] == 'playlist'
    assert result['verified'] is False
    assert any('NASA Moon Tunes Playlist' in line for line in seen[0].values())
    assert youtube_resource(card['href'])[0] == 'video'
    service.store.close()
    service.trace.close()


async def test_identity_chooser_receives_goal_kind_and_subject(tmp_path):
    prompt = 'Find a YouTube video about Artemis'
    plan = _yt('video', 'Artemis', prompt)
    title = 'NASA’s Artemis II Crew Comes Home (Official Broadcast)'
    video = _watch(_VIDEO, title)
    service = Service(tmp_path)
    _install(service, [_results(plan, [_link('e1', title, video['url'])]), video], ['e1', 'yes'])
    result = await execute_local(service, _route(), plan, prompt)
    identity = json.loads(service.router.states[-1])
    assert identity == semantic_identity_state(prompt, video, plan['navigation_goal'])
    assert identity['requested_kind'] == 'video'
    assert identity['requested_subject'] == 'Artemis'
    assert set(identity) == {'request', 'heading', 'title', 'requested_kind', 'requested_subject'}
    assert result['verified'] is False and result['assessment'] == 'local_model'
    service.store.close()
    service.trace.close()

    channel = _page('https://www.youtube.com/@NASA', 'NASA - YouTube', 'NASA',
                    canonical='https://www.youtube.com/@NASA', marker='doc-channel')
    service = Service(tmp_path)
    _install(service, [channel], ['yes'])
    with pytest.raises(ValueError, match='wrong_kind'):
        await execute_local(service, _route(), plan, prompt)
    assert service.router.labels == ['yes']
    assert service.router.states == []
    assert _IDENTITY_QUESTION.startswith('The requested page kind and site have already been checked')
    assert _IDENTITY_CRITERIA['yes'].startswith('The title identifies')
    service.store.close()
    service.trace.close()


async def test_wrong_kind_and_wrong_entity_do_not_count_as_arrival(tmp_path):
    prompt = 'find a youtube video about NASA'
    plan = _yt('video', 'NASA', prompt)
    channel = _page('https://www.youtube.com/@NASA', 'NASA - YouTube', 'NASA',
                    canonical='https://www.youtube.com/@NASA', marker='doc-channel')
    service = Service(tmp_path)
    commands = _install(service, [channel], ['yes'])
    with pytest.raises(ValueError, match='wrong_kind'):
        await execute_local(service, _route(), plan, prompt)
    assert service.router.labels == ['yes']
    assert [item[0] for item in commands].count('Page.navigate') == 1
    service.store.close()
    service.trace.close()

    wrong = _watch(_OTHER, 'Cat song')
    service = Service(tmp_path)
    commands = _install(service, [_results(plan, [_link('e1', 'Cat song', wrong['url'])]), wrong], ['e1', 'no'])
    with pytest.raises(ValueError, match='no_link'):
        await execute_local(service, _route(), plan, prompt)
    assert [item[0] for item in commands].count('Page.navigate') == 2
    service.store.close()
    service.trace.close()


async def test_search_results_are_not_a_video_destination(tmp_path):
    prompt = 'find a youtube video about NASA'
    plan = _yt('video', 'NASA', prompt)
    service = Service(tmp_path)
    commands = _install(service, [_results(plan, [_link('e1', 'Something else', 'https://example.com/not-youtube')])],
                        ['reached'])
    with pytest.raises(ValueError, match='no_link'):
        await execute_local(service, _route(), plan, prompt)
    assert [item[0] for item in commands].count('Page.navigate') == 1
    service.store.close()
    service.trace.close()

    results_prompt = 'show youtube search results for NASA'
    results_plan = _yt('search_results', 'NASA', results_prompt)
    service = Service(tmp_path)
    _install(service, [_results(results_plan, [])], [])
    result = await execute_local(service, _route(), results_plan, results_prompt)
    assert result['verified'] == 'search_results'
    assert service.router.labels == []
    service.store.close()
    service.trace.close()


async def test_consent_and_lookalike_hosts_are_blocked(tmp_path):
    prompt = 'open the NASA youtube channel'
    plan = _yt('channel', 'NASA', prompt)
    consent = _page('https://consent.youtube.com/m', 'Before you continue to YouTube', 'Before you continue to YouTube',
                    text='Sign in is not why this page is blocked. Consent is the visible page.', marker='doc-consent',
                    canonical='')
    service = Service(tmp_path)
    _install(service, [consent], ['yes'])
    with pytest.raises(ValueError, match='consent'):
        await execute_local(service, _route(), plan, prompt)
    assert service.router.labels == ['yes']
    service.store.close()
    service.trace.close()

    lookalike = _watch(_VIDEO, 'NASA')
    lookalike['url'] = f'https://youtube.com.evil.test/watch?v={_VIDEO}'
    lookalike['canonical_url'] = lookalike['url']
    service = Service(tmp_path)
    _install(service, [lookalike], ['yes'])
    with pytest.raises(ValueError, match='lookalike_host'):
        await execute_local(service, _route(), plan, prompt)
    service.store.close()
    service.trace.close()


async def test_empty_or_stale_canonical_waits_then_cannot_complete(tmp_path, monkeypatch):
    monkeypatch.setattr('jet_browser.conversation._HYDRATE_DEADLINE', 0.05)
    monkeypatch.setattr('jet_browser.conversation._HYDRATE_INTERVAL', 0.0)
    prompt = 'find a youtube video about shuttle launch'
    plan = _yt('video', 'shuttle launch', prompt)
    stale = _watch(_VIDEO, 'Previous video')
    stale['canonical_url'] = f'https://www.youtube.com/watch?v={_OTHER}'
    stale['canonical_title'] = 'Previous video'
    empty = _watch(_VIDEO, 'Shuttle launch')
    empty['canonical_url'] = ''

    for page in (stale, empty):
        service = Service(tmp_path)
        commands = _install(service, [page], ['yes'])
        with pytest.raises(ValueError, match='unready'):
            await execute_local(service, _route(), plan, prompt)
        assert [item[0] for item in commands].count('Runtime.evaluate') >= 8
        assert [item[0] for item in commands].count('Page.navigate') == 1
        assert service.router.labels == ['yes']
        service.store.close()
        service.trace.close()


async def test_homepage_and_explicit_url(tmp_path):
    prompt = 'open youtube'
    home = _page('https://www.youtube.com/', 'YouTube', '', text='Home Shorts Subscriptions library recommended videos ' * 3,
                 marker='doc-home', canonical='https://www.youtube.com/')
    plan = {
        'operation': 'open_url', 'tab_id': 'tab-a', 'provider': 'youtube', 'url': 'https://www.youtube.com/',
        'navigation_goal': {
            'provider': 'youtube', 'kind': 'homepage', 'request': prompt, 'query': '',
            'tab_id': 'tab-a', 'url': 'https://www.youtube.com/',
        },
    }
    service = Service(tmp_path)
    _install(service, [home], [])
    result = await execute_local(service, _route(), plan, prompt)
    assert result['verified'] == 'homepage'
    assert result['observed_page']['url'] == 'https://www.youtube.com/'
    service.store.close()
    service.trace.close()

    target = f'https://www.youtube.com/watch?v={_VIDEO}'
    prompt = 'open https://www.youtube.com/watch?v=' + _VIDEO
    explicit = {
        'operation': 'open_url', 'tab_id': 'tab-a', 'url': target,
        'navigation_goal': {
            'provider': 'web', 'kind': 'explicit_url', 'request': prompt, 'query': '',
            'tab_id': 'tab-a', 'url': target,
        },
    }
    drifted = _page('https://www.youtube.com/results?search_query=shuttle', 'shuttle - YouTube', 'Search results',
                    marker='doc-drift')
    service = Service(tmp_path)
    commands = _install(service, [drifted], ['yes'])
    with pytest.raises(ValueError, match='explicit_mismatch'):
        await execute_local(service, _route(), explicit, prompt)
    assert [item[0] for item in commands].count('Page.navigate') == 1
    service.store.close()
    service.trace.close()

    landed = _page('https://github.com/jet', 'jet', 'jet', marker='doc-repo')
    explicit['url'] = 'http://github.com/jet'
    explicit['navigation_goal'] = {**explicit['navigation_goal'], 'url': 'http://github.com/jet', 'request': 'open http://github.com/jet'}
    service = Service(tmp_path)
    _install(service, [landed], [])
    result = await execute_local(service, _route(), explicit, 'open http://github.com/jet')
    assert result['verified'] == 'explicit_url'
    assert result['observed_page']['url'] == 'https://github.com/jet'
    assert explicit_url_matches(f'https://m.youtube.com/watch?v={_VIDEO}&si=tracking', target)
    assert explicit_url_matches(f'https://www.youtube.com/watch?v={_VIDEO}&feature=share', target)
    assert explicit_url_matches(f'https://www.youtube.com/watch?v={_VIDEO}&list={_LIST}&index=1',
                                f'https://www.youtube.com/watch?v={_VIDEO}&list={_LIST}&index=1')
    assert not explicit_url_matches(f'https://www.youtube.com/watch?v={_VIDEO}&list={_LIST}', target)
    assert not explicit_url_matches(f'https://www.youtube.com/watch?v={_VIDEO}&t=30', target)
    assert not explicit_url_matches(f'https://www.youtube.com/watch?v={_VIDEO}&start=10', target)
    assert not explicit_url_matches(f'https://www.youtube.com/watch?v={_VIDEO}&index=2', target)
    assert not explicit_url_matches(target + '#chapter', target)
    assert explicit_url_matches(target + '#chapter', target + '#chapter')
    assert explicit_url_matches('https://www.youtube.com:443/watch?v=' + _VIDEO, target)
    assert not explicit_url_matches('http://example.com:99999/watch', 'http://example.com/watch')
    assert not explicit_url_matches('https://accounts.google.com/ServiceLogin', target)
    service.store.close()
    service.trace.close()


async def test_stop_stale_href_and_failed_navigation_do_not_retry(tmp_path):
    prompt = 'find a youtube video about shuttle launch'
    plan = _yt('video', 'shuttle launch', prompt)
    video = _watch(_VIDEO, 'Shuttle launch')
    results = _results(plan, [_link('e1', 'Shuttle launch', video['url'])])
    service = Service(tmp_path)
    commands = _install(service, [results], ['e1'])

    async def stopping(tab_id, method, params=None, **kwargs):
        if method == 'Runtime.evaluate' and sum(item[0] == 'Page.navigate' for item in commands) == 1:
            post = sum(item[0] == 'Runtime.evaluate' for item in commands)
            if post >= 2:
                service.chat_stopped.set()
        return await original(tab_id, method, params, **kwargs)

    original = service.bridge.call
    service.bridge.call = stopping
    with pytest.raises(asyncio.CancelledError):
        await execute_local(service, _route(), plan, prompt)
    assert [item[0] for item in commands].count('Page.navigate') == 1
    service.store.close()
    service.trace.close()

    service = Service(tmp_path)
    commands = _install(service, [results], ['e1'])
    # Hydration reads the linked page before the follow-up re-read. Drop only that re-read.
    post = {'n': 0}
    original = service.bridge.call

    async def drop_late(tab_id, method, params=None, **kwargs):
        if method == 'Runtime.evaluate':
            post['n'] += 1
        page_call = await original(tab_id, method, params, **kwargs)
        if method == 'Runtime.evaluate' and post['n'] >= 4:
            value = page_call['result']['value']
            value['actions'] = [{**action, 'href': ''} for action in value.get('actions') or []]
        return page_call

    service.bridge.call = drop_late
    with pytest.raises(ValueError, match='stale_href'):
        await execute_local(service, _route(), plan, prompt)
    assert [item[0] for item in commands].count('Page.navigate') == 1
    service.store.close()
    service.trace.close()

    service = Service(tmp_path)
    commands = _install(service, [results, video], ['e1', 'yes'], fail_followup=True)
    with pytest.raises(BridgeError):
        await execute_local(service, _route(), plan, prompt)
    navigated = [item for item in commands if item[0] == 'Page.navigate']
    assert len(navigated) == 2
    assert navigated[-1][1]['url'] == video['url']
    service.store.close()
    service.trace.close()


async def test_wikipedia_goal_keeps_the_existing_completion_path(tmp_path):
    article = {
        'url': 'https://en.wikipedia.org/wiki/Quantum_mechanics',
        'title': 'Quantum mechanics - Wikipedia', 'heading': 'Quantum mechanics',
        'lead': 'Fundamental theory', 'text': 'Quantum mechanics describes nature.',
        'ready_state': 'complete', 'marker': ['doc-article'], 'actions': [],
    }
    plan = _plan(query='Quantum mechanics')
    plan['url'] = 'https://en.wikipedia.org/wiki/Quantum_mechanics'
    plan['navigation_goal'] = {
        'provider': 'wikipedia', 'kind': 'article', 'request': 'go to quantum mechanics wikipedia page',
        'query': 'Quantum mechanics', 'tab_id': 'tab-a', 'url': plan['url'],
    }
    service = Service(tmp_path)
    _install(service, [article], ['yes'])
    result = await execute_local(service, _route(), plan, 'go to quantum mechanics wikipedia page')
    assert result['verified'] == 'title_and_url'
    assert service.router.labels == ['yes']
    service.store.close()
    service.trace.close()


_CHANNEL_ID = 'UCLA_DiR1FfKNvjuUpBHmylQ'


def _channel_plan():
    url = 'https://www.youtube.com/@NASA'
    goal = {
        'provider': 'youtube', 'kind': 'channel', 'request': 'open the NASA youtube channel',
        'query': 'NASA', 'tab_id': 'tab-a', 'url': url,
    }
    return {'operation': 'open_url', 'tab_id': 'tab-a', 'provider': 'youtube', 'url': url,
            'navigation_goal': goal}, goal


def _nasa_alias():
    url = 'https://www.youtube.com/@NASA'
    canonical = f'https://www.youtube.com/channel/{_CHANNEL_ID}'
    page = _page(url, 'NASA - YouTube', 'NASA', canonical=canonical, marker='doc-channel')
    page['channel_identity'] = {
        'external_id': _CHANNEL_ID,
        'vanity_url': 'https://www.youtube.com/@NASA',
        'title': 'NASA',
    }
    return page


def test_channel_alias_uses_renderer_identity():
    plan, goal = _channel_plan()
    assert structural_status(_nasa_alias(), plan, goal) == 'kind_ok'
    wrong = _nasa_alias()
    wrong['channel_identity'] = {**wrong['channel_identity'], 'external_id': 'UCWRONGCHANNELID'}
    assert structural_status(wrong, plan, goal) == 'unready'
    stale = _nasa_alias()
    stale['heading'] = 'NASA Clips'
    stale['title'] = 'NASA Clips - YouTube'
    assert structural_status(stale, plan, goal) == 'unready'
    missing = _nasa_alias()
    missing['channel_identity'] = {}
    assert structural_status(missing, plan, goal) == 'unready'


async def test_channel_alias_completes_through_read_page(tmp_path):
    plan, _goal = _channel_plan()
    service = Service(tmp_path)
    _install(service, [_nasa_alias()], ['yes'])
    result = await execute_local(service, _route(), plan, 'open the NASA youtube channel')
    assert result['structural'] == 'channel'
    assert result['assessment'] == 'local_model'
    assert result['observed_page']['channel_identity']['external_id'] == _CHANNEL_ID
    service.store.close()
    service.trace.close()


async def test_metadata_shell_is_not_video_or_playlist_completion(tmp_path):
    watch = f'https://www.youtube.com/watch?v={_VIDEO}'
    shell = _page(watch, 'YouTube', '', canonical=watch, marker='doc-shell')
    shell['canonical_title'] = 'Shuttle launch'
    plan = {
        'operation': 'open_url', 'tab_id': 'tab-a', 'url': watch, 'provider': 'youtube',
        'navigation_goal': {
            'provider': 'youtube', 'kind': 'video', 'request': 'watch the shuttle', 'query': 'shuttle',
            'tab_id': 'tab-a', 'url': watch,
        },
    }
    assert structural_status(shell, plan, plan['navigation_goal']) == 'unready'
    service = Service(tmp_path)
    commands = _install(service, [shell], ['yes'])
    with pytest.raises(ValueError, match='unready'):
        await execute_local(service, _route(), plan, 'watch the shuttle')
    assert service.router.labels == ['yes']
    assert [item[0] for item in commands].count('Page.navigate') == 1
    service.store.close()
    service.trace.close()

    playlist_url = f'https://www.youtube.com/playlist?list={_LIST}'
    playlist = _page(playlist_url, 'NASA Moon Tunes Playlist - YouTube', '', canonical=playlist_url, marker='doc-shell')
    playlist['canonical_title'] = 'NASA Moon Tunes Playlist'
    plan = {
        'operation': 'open_url', 'tab_id': 'tab-a', 'url': playlist_url, 'provider': 'youtube',
        'navigation_goal': {
            'provider': 'youtube', 'kind': 'playlist', 'request': 'open the playlist', 'query': 'NASA Moon Tunes',
            'tab_id': 'tab-a', 'url': playlist_url,
        },
    }
    assert structural_status(playlist, plan, plan['navigation_goal']) == 'unready'
    service = Service(tmp_path)
    _install(service, [playlist], ['yes'])
    with pytest.raises(ValueError, match='unready'):
        await execute_local(service, _route(), plan, 'open the playlist')
    service.store.close()
    service.trace.close()


def test_player_error_blocks_without_matching_sign_in_chrome():
    page = _watch(_VIDEO, 'Shuttle launch')
    page['navigation_error'] = 'Video unavailable'
    assert blocked_reason(page) == 'unavailable'
    page['navigation_error'] = ''
    page['text'] = 'Sign in\nUnavailable videos are hidden\n' + page['text']
    assert blocked_reason(page) is None


async def test_page_change_after_identity_yes_is_not_done(tmp_path):
    prompt = 'find a youtube video about shuttle launch'
    plan = _yt('video', 'shuttle launch', prompt)
    video = _watch(_VIDEO, 'Shuttle launch')
    late = _watch(_OTHER, 'Other launch', marker='doc-late')
    service = Service(tmp_path)
    commands = _install(service, [_results(plan, [_link('e1', 'Shuttle launch', video['url'])]), video], ['e1', 'yes'])
    original = service.bridge.call

    async def shift(tab_id, method, params=None, **kwargs):
        result = await original(tab_id, method, params, **kwargs)
        if method == 'Runtime.evaluate' and not service.router.labels:
            result['result']['value'] = late
        return result

    service.bridge.call = shift
    with pytest.raises(ValueError, match='stale_page'):
        await execute_local(service, _route(), plan, prompt)
    assert [item[0] for item in commands].count('Page.navigate') == 2
    service.store.close()
    service.trace.close()
