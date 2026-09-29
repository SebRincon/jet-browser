"""Real local chat navigation checks; stops immediately if Grok is selected."""
import json
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[1]


def main():
    with httpx.Client(base_url='http://127.0.0.1:9148', timeout=25,
                      headers={'Authorization': 'Bearer ' + (ROOT / '.runtime/token').read_text().strip()}) as client:
        def post(path, body):
            response = client.post(path, json=body)
            response.raise_for_status()
            return response.json()

        def state():
            response = client.get('/state')
            response.raise_for_status()
            return response.json()

        before = state()
        if before['provider']['status'] not in {'ready', 'error'}:
            raise RuntimeError('Wait for the current user turn')
        for _ in range(100):
            if state()['browser']['online']:
                break
            time.sleep(.1)
        else:
            raise RuntimeError('Native browser is not connected')
        session = post('/sessions', {})
        post('/mcp/tool', {'name': 'open_url', 'arguments': {'url': 'http://127.0.0.1:9148/fixture'}})
        cases = [
            ('Find me the Wikipedia page for Elon Musk', 'Elon Musk - Wikipedia'),
            ('Now find that same kind of page for Ada Lovelace', 'Ada Lovelace - Wikipedia'),
            ('Go back', 'Elon Musk - Wikipedia'),
            ('Go forward', 'Ada Lovelace - Wikipedia'),
            ('Show my open tabs', None),
        ]
        rows = []
        for prompt, expected_title in cases:
            if state()['session']['id'] != session['id']:
                raise RuntimeError('User changed conversation; leaving the browser under their control')
            old_ids = {r['id'] for r in state()['routes']}
            started = time.monotonic()
            post('/chat', {'message': prompt})
            print('Started: ' + prompt, flush=True)
            for _ in range(900):
                current = state()
                routes = [r for r in current['routes'] if r['id'] not in old_ids]
                if any(r.get('grok_calls', 0) for r in routes):
                    post('/chat/stop', {})
                    break
                if current['provider']['status'] in {'ready', 'error'}:
                    break
                time.sleep(.1)
            else:
                post('/chat/stop', {})
                raise RuntimeError('Local turn exceeded 90 seconds')
            page = post('/mcp/tool', {'name': 'read_page', 'arguments': {}})
            verified = bool(routes) and all(r.get('decision') == 'local' and r.get('status') == 'done'
                                           and not r.get('grok_calls', 0) for r in routes)
            verified = verified and (expected_title is None or page.get('title') == expected_title)
            row = {'prompt': prompt, 'expected_title': expected_title, 'routes': routes,
                   'observed_page': page, 'verified': verified,
                   'elapsed_ms': round((time.monotonic() - started) * 1000),
                   'messages': current['messages'][-2:]}
            rows.append(row)
            print(json.dumps({'verified': verified, 'title': page.get('title'),
                              'elapsed_ms': row['elapsed_ms'], 'routes': routes}), flush=True)
            if not verified:
                break
        output = ROOT / 'artifacts' / ('local-chat-' + str(time.time_ns()) + '.json')
        output.write_text(json.dumps({'session': session, 'prior_session': before['session'], 'cases': rows}, indent=2))
        print(str(output))
        if len(rows) != len(cases) or not all(r['verified'] for r in rows):
            raise SystemExit('Local chat check failed; evidence retained')


if __name__ == '__main__':
    main()
