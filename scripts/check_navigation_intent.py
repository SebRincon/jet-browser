"""Explicit native check for six navigation intents.

Does not run unless --run is passed. --help exits before any API call.
A run writes a new UTC-timestamped artifact and does not replace earlier results.

The bearer token is read only to authenticate and is never printed. Chat text
from any session other than this temporary QA session is not read or recorded.
Mutations are not retried. Stop runs only while this check's turn is the
current one. The original session and tab are restored only when this check
still owns them and the app is idle. If opening the QA tab fails, the original
session is restored only when that QA session is still selected, the app is
idle, and the active tab is unchanged. Cleanup errors are stored on the
artifact and do not replace the primary error.
"""

import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
API = 'http://127.0.0.1:9148'
CASES = (
    ('Find me the Wikipedia page for Elon Musk', 'article', 'Elon Musk - Wikipedia'),
    ('Show Wikipedia search results for Elon Musk', 'results', None),
    ('go to elon musks wiki page', 'article', 'Elon Musk - Wikipedia'),
    ('go space x wiki page', 'article', 'SpaceX - Wikipedia'),
    ('Now find that same kind of page for Ada Lovelace', 'article', 'Ada Lovelace - Wikipedia'),
    ('Open the Wikipedia article about Quantum physics', 'article', 'Quantum mechanics - Wikipedia'),
)
_WIKI_SUFFIX = ' - Wikipedia'


def _headers():
    token = (ROOT / '.runtime' / 'token').read_text().strip()
    return {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}


def _bounded(error):
    return str(error)[:400]


def _redact(detail, headers):
    """Remove the bearer token whether or not the HTTP body includes the scheme."""
    auth = (headers or {}).get('Authorization') or ''
    if not auth:
        return detail
    detail = detail.replace(auth, '')
    if auth.startswith('Bearer '):
        bare = auth[len('Bearer '):]
        if bare:
            detail = detail.replace(bare, '')
    return detail


def call(path, body=None, headers=None):
    """One request. A transport or HTTP failure is not retried."""
    payload = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(API + path, data=payload, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raw = error.read()[:400]
        detail = _redact(raw.decode('utf-8', 'replace'), headers)
        raise RuntimeError('HTTP ' + str(error.code) + ' ' + path + ' ' + detail[:400]) from None


def _wikipedia_host(url):
    host = (urllib.parse.urlsplit(url).hostname or '').rstrip('.').lower()
    return host == 'wikipedia.org' or host.endswith('.wikipedia.org')


def _article_path(title):
    name = (title or '').removesuffix(_WIKI_SUFFIX)
    return '/wiki/' + name.replace(' ', '_')


def _page_ok(page, kind, title):
    url = page.get('url') or ''
    parts = urllib.parse.urlsplit(url)
    if not _wikipedia_host(url):
        return False
    path = urllib.parse.unquote(parts.path)
    if kind == 'article':
        return path == _article_path(title) and page.get('title') == title
    query = urllib.parse.parse_qs(parts.query)
    titles = query.get('title') or []
    special = (path == '/w/index.php' and 'Special:Search' in titles) or path == '/wiki/Special:Search'
    return special and 'Elon Musk' in (query.get('search') or []) and page.get('heading') == 'Search results'


def _turn_id(state):
    """GET /state has no top-level turn id. Prefer trace, then the newest message."""
    trace = state.get('trace') or {}
    if trace.get('turn_id'):
        return trace.get('turn_id')
    snapshot = trace.get('snapshot') or {}
    if snapshot.get('turn_id'):
        return snapshot.get('turn_id')
    messages = state.get('messages') or []
    if messages and isinstance(messages[-1], dict):
        return messages[-1].get('turn_id')
    return None


def _own_routes(state, own_turn):
    if not own_turn:
        return []
    return [route for route in state.get('routes') or [] if route.get('turn_id') == own_turn]


def _local_done(routes):
    return bool(routes) and all(
        route.get('decision') == 'local' and route.get('status') == 'done' and not route.get('grok_calls')
        for route in routes
    )


def _owned(state, qa_id, qa_tab):
    session = (state.get('session') or {}).get('id')
    browser = state.get('browser') or {}
    return session == qa_id and not state.get('busy') and browser.get('active_tab_id') == qa_tab


def _stop_owned(state, qa_id, own_turn):
    session = (state.get('session') or {}).get('id')
    return bool(state.get('busy') and session == qa_id and own_turn and _turn_id(state) == own_turn)


def _session_only_restore(state, qa_id, before):
    """Failed open: restore the prior session only if the user has not taken the UI."""
    if not qa_id or state.get('busy'):
        return False
    if (state.get('session') or {}).get('id') != qa_id:
        return False
    current = (state.get('browser') or {}).get('active_tab_id')
    previous = (before.get('browser') or {}).get('active_tab_id')
    return current == previous


def _stop_once(state, qa_id, own_turn, headers):
    if not _stop_owned(state, qa_id, own_turn):
        return
    call('/chat/stop', {}, headers)


def _cleanup(headers, qa, qa_tab, before):
    if not qa:
        return
    state = call('/state', headers=headers)
    qa_id = qa.get('id')
    if not qa_tab:
        if _session_only_restore(state, qa_id, before):
            original = (before.get('session') or {}).get('id')
            if original:
                call('/sessions/select', {'session_id': original}, headers)
        return
    if not _owned(state, qa_id, qa_tab):
        return
    call('/mcp/tool', {'name': 'browser_action', 'arguments': {'action': 'close_tab', 'tab_id': qa_tab}}, headers)
    previous = (before.get('browser') or {}).get('active_tab_id')
    if previous:
        call('/mcp/tool', {'name': 'browser_action', 'arguments': {'action': 'switch_tab', 'tab_id': previous}}, headers)
    original = (before.get('session') or {}).get('id')
    if original:
        call('/sessions/select', {'session_id': original}, headers)


def run():
    headers = _headers()
    qa = None
    qa_tab = None
    before = {}
    rows = []
    failure = None
    cleanup_error = None
    caught = None
    try:
        before = call('/state', headers=headers)
        if before.get('busy') or not (before.get('browser') or {}).get('online'):
            raise SystemExit('User active or native browser offline')
        qa = call('/sessions', {}, headers=headers)
        opened = call('/mcp/tool', {'name': 'open_url', 'arguments': {'url': API + '/fixture'}}, headers)
        qa_tab = opened.get('tab_id') if isinstance(opened, dict) else None
        if not qa_tab:
            raise RuntimeError('open_url did not return a tab')
        for prompt, kind, title in CASES:
            state = call('/state', headers=headers)
            if (state.get('session') or {}).get('id') != qa['id']:
                raise RuntimeError('User changed session; selection was left unchanged')
            if (state.get('browser') or {}).get('active_tab_id') != qa_tab:
                raise RuntimeError('Active tab left the QA tab; user selection was left unchanged')
            if state.get('busy'):
                raise RuntimeError('App is busy before chat; selection was left unchanged')
            started = time.monotonic()
            posted = call('/chat', {'message': prompt}, headers)
            own_turn = posted.get('turn_id') if isinstance(posted, dict) else None
            if not own_turn:
                raise RuntimeError('Chat response missing turn_id')
            print('Started: ' + prompt, flush=True)
            routes = []
            for _ in range(1800):
                state = call('/state', headers=headers)
                if (state.get('session') or {}).get('id') != qa['id']:
                    raise RuntimeError('User changed session; selection was left unchanged')
                if (state.get('browser') or {}).get('active_tab_id') != qa_tab:
                    _stop_once(state, qa['id'], own_turn, headers)
                    raise RuntimeError('Active tab left the QA tab; user selection was left unchanged')
                routes = _own_routes(state, own_turn)
                if any(route.get('grok_calls', 0) for route in routes):
                    _stop_once(state, qa['id'], own_turn, headers)
                    state = call('/state', headers=headers)
                    routes = _own_routes(state, own_turn)
                    break
                if not state.get('busy'):
                    break
                time.sleep(.05)
            else:
                _stop_once(state, qa['id'], own_turn, headers)
                raise RuntimeError('Timed out')
            page = call('/mcp/tool', {'name': 'read_page', 'arguments': {'tab_id': qa_tab}}, headers)
            passed = _page_ok(page, kind, title) and _local_done(routes)
            row = {
                'prompt': prompt, 'expected_kind': kind, 'expected_title': title, 'passed': passed,
                'elapsed_ms': round((time.monotonic() - started) * 1000),
                'page': {key: page.get(key) for key in ('url', 'title', 'heading', 'lead', 'ready_state')},
                'routes': routes,
            }
            rows.append(row)
            print(json.dumps({key: row[key] for key in ('prompt', 'passed', 'elapsed_ms', 'page')}, ensure_ascii=False),
                  flush=True)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        failure = {'type': type(error).__name__, 'detail': _bounded(error)}
        caught = error
    finally:
        try:
            _cleanup(headers, qa, qa_tab, before)
        except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
            cleanup_error = {'type': type(error).__name__, 'detail': _bounded(error)}
        stamp = datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')
        artifact = ROOT / 'artifacts' / f'intent-completion-native-{stamp}.json'
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_text(json.dumps({
            'session': None if not qa else qa.get('id'),
            'cases': rows,
            'error': failure,
            'cleanup_error': cleanup_error,
        }, indent=2))
        print(str(artifact), flush=True)
    if caught is not None:
        raise caught
    if cleanup_error is not None:
        raise RuntimeError(cleanup_error['detail'])
    if len(rows) != 6 or not all(row['passed'] for row in rows):
        raise SystemExit('Native checks failed; evidence retained')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--run', action='store_true', help='Call the local app. Required. Without it, nothing is contacted.')
    args = parser.parse_args(argv)
    if not args.run:
        parser.error('Pass --run to contact the local app. --help does not make an API call.')
    run()


if __name__ == '__main__':
    main()
