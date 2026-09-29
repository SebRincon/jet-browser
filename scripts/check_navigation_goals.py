"""Explicit native check for homepage and YouTube navigation goals.

Does not run unless --run is passed. --help exits before any API call.
Importing this module does not read the bearer token or contact the app.
A run writes a new UTC-timestamped artifact and does not replace earlier results.

The bearer token is read only inside run() and is never printed. Chat text
from any session other than this temporary QA session is not read or recorded.
Mutations are not retried. Stop runs only while this check's turn is the
current one, through the shared ownership helper, including one best-effort
stop in finally if that same turn is still current. Each posted turn may be
stopped once. A different turn in the QA session is a takeover: it is not
stopped, and the tab is not closed. The original session and tab are restored
only when this check still owns them and the last posted turn is still current.
Stop and
cleanup errors are stored separately and do not replace the primary error.
A case that fails before its row is finished is still recorded as failed.

Page evidence is judged by this script's URL and heading oracle. A route
marked done is not success by itself.
"""

import argparse
import importlib.util
import json
import re
import time
import urllib.parse
import uuid
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_INTENT_PATH = ROOT / 'scripts' / 'check_navigation_intent.py'
_INTENT_SPEC = importlib.util.spec_from_file_location('check_navigation_intent', _INTENT_PATH)
intent = importlib.util.module_from_spec(_INTENT_SPEC)
_INTENT_SPEC.loader.exec_module(intent)

_headers = intent._headers
_redact = intent._redact
_owned = intent._owned
_stop_once = intent._stop_once
_stop_owned = intent._stop_owned
_cleanup = intent._cleanup
_own_routes = intent._own_routes
_local_done = intent._local_done

CASE_TIMEOUT_S = 75
_PAGE_KEYS = (
    'url', 'title', 'heading', 'lead', 'ready_state', 'canonical_url', 'youtube',
    'canonical_title', 'channel_identity', 'document_id', 'navigation_error',
)
_KINDS = frozenset({'home', 'channel', 'video', 'playlist', 'results'})
_YOUTUBE_HOSTS = frozenset({'youtube.com', 'www.youtube.com', 'm.youtube.com'})
_ALLOWED_PORTS = frozenset({None, 80, 443})
_WATCH_ID = re.compile(r'^[A-Za-z0-9_-]{11}$')
_LIST_ID = re.compile(r'^[A-Za-z0-9_-]{12,}$')
_HOME_PROVIDER = {
    'youtube.com': 'youtube',
    'github.com': 'github',
    'wikipedia.org': 'wikipedia',
    'google.com': 'google',
}
CASES = (
    {'key': 'home_youtube', 'prompt': 'Bring me to YouTube', 'kind': 'home', 'target': 'youtube.com'},
    {'key': 'home_github', 'prompt': 'Go to GitHub', 'kind': 'home', 'target': 'github.com'},
    {'key': 'home_wikipedia', 'prompt': 'Take me to Wikipedia', 'kind': 'home', 'target': 'wikipedia.org'},
    {'key': 'home_google', 'prompt': 'Open the Google homepage', 'kind': 'home', 'target': 'google.com'},
    {'key': 'channel', 'prompt': "Open NASA's YouTube channel", 'kind': 'channel', 'target': 'NASA'},
    {'key': 'video', 'prompt': 'Find a YouTube video about Artemis', 'kind': 'video', 'target': 'Artemis'},
    {'key': 'playlist', 'prompt': 'Open a NASA playlist on YouTube', 'kind': 'playlist', 'target': 'NASA'},
    {'key': 'results', 'prompt': 'Show YouTube search results for NASA', 'kind': 'results', 'target': 'NASA'},
)
CASE_KEYS = tuple(case['key'] for case in CASES)


def _bounded(error, headers):
    return _redact(str(error), headers)[:300]


def _host(parts):
    return (parts.hostname or '').rstrip('.').lower()


def _safe_parts(url):
    """Split a URL. Malformed ports and brackets are a failed check, not an exception."""
    try:
        parts = urllib.parse.urlsplit(url or '')
        port = parts.port
        username = parts.username
        password = parts.password
    except ValueError:
        return None
    if parts.scheme not in {'http', 'https'}:
        return None
    if username or password or port not in _ALLOWED_PORTS:
        return None
    if not _host(parts):
        return None
    return parts


def oracle(page, kind, target):
    """Independent URL/title/heading check. Route status is not an input."""
    if kind not in _KINDS:
        return False
    parts = _safe_parts(page.get('url') or '')
    if parts is None:
        return False
    host = _host(parts)
    query = urllib.parse.parse_qs(parts.query, errors='ignore')
    title = page.get('title') or ''
    heading = page.get('heading') or ''
    if kind == 'home':
        provider = _HOME_PROVIDER.get(target)
        names = {target, 'www.' + target}
        home_path = parts.path in {'', '/'}
        titled = bool(title.strip()) and provider is not None and provider in title.casefold()
        return host in names and home_path and not parts.query and titled
    if host not in _YOUTUBE_HOSTS:
        return False
    if kind == 'channel':
        return parts.path.rstrip('/').lower() == '/@nasa' and heading == 'NASA'
    if kind == 'video':
        watch_ids = query.get('v') or []
        genuine = len(watch_ids) == 1 and _WATCH_ID.fullmatch(watch_ids[0]) is not None
        text = (heading + ' ' + title).casefold()
        return parts.path == '/watch' and genuine and target.casefold() in text
    if kind == 'playlist':
        lists = query.get('list') or []
        real = len(lists) == 1 and _LIST_ID.fullmatch(lists[0]) is not None
        return parts.path == '/playlist' and real and 'NASA' in heading
    if kind == 'results':
        return parts.path == '/results' and query.get('search_query') == [target] and target.casefold() in title.casefold()
    return False


def selected_cases(keys):
    chosen = set(keys)
    unknown = [key for key in keys if key not in CASE_KEYS]
    if unknown:
        raise ValueError('Unknown case ' + ', '.join(unknown))
    return [case for case in CASES if case['key'] in chosen]


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--run', action='store_true', help='Call the local app. Required. Without it, nothing is contacted.')
    parser.add_argument('--case', action='append', choices=CASE_KEYS, dest='cases', help='Case key. Repeatable. Default: all eight.')
    return parser


def _issue(error, headers):
    return {'type': type(error).__name__, 'detail': _bounded(error, headers)}


def _partial_row(case, started, routes, error, headers):
    elapsed = 0 if started is None else round((time.monotonic() - started) * 1000)
    return {
        'key': case['key'],
        'prompt': case['prompt'],
        'kind': case['kind'],
        'target': case['target'],
        'passed': False,
        'error': _issue(error, headers),
        'elapsed_ms': elapsed,
        'grok_calls': sum(int(route.get('grok_calls') or 0) for route in routes),
        'routes': routes,
    }


def artifact_path(root):
    """Timestamp plus a random suffix so two failures in one second stay distinct."""
    stamp = datetime.now(UTC).strftime('%Y%m%dT%H%M%S%fZ')
    return root / 'artifacts' / f'navigation-goals-native-{stamp}-{uuid.uuid4().hex}.json'


def run(keys):
    headers = _headers()
    qa = None
    tab = None
    own = None
    before = {}
    rows = []
    failure = None
    stop_error = None
    cleanup_error = None
    caught = None
    lost = False
    stopped_turns = set()
    cases = selected_cases(keys)

    def request_stop(state):
        nonlocal stop_error
        if lost or not qa or not own or own in stopped_turns:
            return
        if not _stop_owned(state, qa.get('id'), own):
            return
        stopped_turns.add(own)
        try:
            _stop_once(state, qa.get('id'), own, headers)
        except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
            if stop_error is None:
                stop_error = _issue(error, headers)

    def _still_current(state):
        session_ok = (state.get('session') or {}).get('id') == (qa or {}).get('id')
        tab_ok = (state.get('browser') or {}).get('active_tab_id') == tab
        return bool(session_ok and tab_ok and own and intent._turn_id(state) == own)

    def _restore_owned():
        intent.call('/mcp/tool', {
            'name': 'browser_action', 'arguments': {'action': 'close_tab', 'tab_id': tab},
        }, headers)
        previous = (before.get('browser') or {}).get('active_tab_id')
        if previous:
            intent.call('/mcp/tool', {
                'name': 'browser_action', 'arguments': {'action': 'switch_tab', 'tab_id': previous},
            }, headers)
        original = (before.get('session') or {}).get('id')
        if original:
            intent.call('/sessions/select', {'session_id': original}, headers)

    def finish():
        """Stop this turn once if it is still current, then restore only while it remains current."""
        if not qa or lost:
            return
        if not own or not tab:
            _cleanup(headers, qa, tab, before)
            return
        state = intent.call('/state', headers=headers)
        if not _still_current(state):
            if (state.get('browser') or {}).get('active_tab_id') != tab and intent._turn_id(state) == own:
                request_stop(state)
            return
        request_stop(state)
        if state.get('busy'):
            state = intent.call('/state', headers=headers)
            if not _still_current(state) or not _owned(state, qa.get('id'), tab):
                return
        elif not _owned(state, qa.get('id'), tab):
            return
        _restore_owned()

    try:
        before = intent.call('/state', headers=headers)
        if before.get('busy') or not (before.get('browser') or {}).get('online'):
            raise RuntimeError('App busy/offline')
        qa = intent.call('/sessions', {}, headers)
        opened = intent.call('/mcp/tool', {'name': 'open_url', 'arguments': {'url': intent.API + '/fixture'}}, headers)
        tab = opened.get('tab_id') if isinstance(opened, dict) else None
        if not tab:
            raise RuntimeError('open_url did not return a tab')
        for case in cases:
            started = None
            routes = []
            appended = False
            try:
                state = intent.call('/state', headers=headers)
                if not _owned(state, qa['id'], tab):
                    raise RuntimeError('Lost QA context')
                if own is not None and intent._turn_id(state) != own:
                    lost = True
                    raise RuntimeError('User changed turn')
                started = time.monotonic()
                posted = intent.call('/chat', {'message': case['prompt']}, headers)
                own = posted.get('turn_id') if isinstance(posted, dict) else None
                if not own:
                    raise RuntimeError('No turn id')
                print('Started: ' + case['prompt'], flush=True)
                deadline = started + CASE_TIMEOUT_S
                while time.monotonic() < deadline:
                    state = intent.call('/state', headers=headers)
                    if (state.get('session') or {}).get('id') != qa['id']:
                        lost = True
                        raise RuntimeError('User changed session')
                    if (state.get('browser') or {}).get('active_tab_id') != tab:
                        request_stop(state)
                        raise RuntimeError('User changed tab')
                    if intent._turn_id(state) != own:
                        lost = True
                        raise RuntimeError('User changed turn')
                    routes = _own_routes(state, own)
                    if any(route.get('grok_calls') for route in routes):
                        request_stop(state)
                        state = intent.call('/state', headers=headers)
                        if intent._turn_id(state) != own:
                            lost = True
                            raise RuntimeError('User changed turn')
                        routes = _own_routes(state, own)
                        break
                    if not state.get('busy'):
                        break
                    time.sleep(0.08)
                else:
                    request_stop(state)
                    raise RuntimeError('Timeout')
                page = intent.call('/mcp/tool', {'name': 'read_page', 'arguments': {'tab_id': tab}}, headers)
                row = {
                    'key': case['key'],
                    'prompt': case['prompt'],
                    'kind': case['kind'],
                    'target': case['target'],
                    'passed': bool(oracle(page, case['kind'], case['target']) and _local_done(routes)),
                    'elapsed_ms': round((time.monotonic() - started) * 1000),
                    'grok_calls': sum(int(route.get('grok_calls') or 0) for route in routes),
                    'page': {key: page.get(key) for key in _PAGE_KEYS},
                    'routes': routes,
                }
                rows.append(row)
                appended = True
                visible = {key: value for key, value in row.items() if key != 'routes'}
                print(json.dumps(visible, ensure_ascii=False), flush=True)
            except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
                if not appended:
                    rows.append(_partial_row(case, started, routes, error, headers))
                failure = _issue(error, headers)
                caught = error
                break
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        failure = _issue(error, headers)
        caught = error
    finally:
        try:
            finish()
        except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
            cleanup_error = _issue(error, headers)
        artifact = artifact_path(ROOT)
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_text(json.dumps({
            'session': None if not qa else qa.get('id'),
            'cases': rows,
            'error': failure,
            'stop_error': stop_error,
            'cleanup_error': cleanup_error,
        }, indent=2))
        print(str(artifact), flush=True)
    if caught is not None:
        raise caught
    if stop_error is not None:
        raise RuntimeError(stop_error['detail'])
    if cleanup_error is not None:
        raise RuntimeError(cleanup_error['detail'])
    if len(rows) != len(cases) or not all(row['passed'] for row in rows):
        raise SystemExit('Navigation goal checks failed; evidence retained')


def main(argv=None):
    parser = parse_args()
    args = parser.parse_args(argv)
    if not args.run:
        parser.error('Pass --run to contact the local app. --help does not make an API call.')
    run(CASE_KEYS if args.cases is None else args.cases)


if __name__ == '__main__':
    main()
