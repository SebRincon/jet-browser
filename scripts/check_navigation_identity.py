"""Controlled local SemIf subject-identity probes.

Uses the production YouTube identity question, criteria, and state keys.
Does not read a service credential, mutate a browser, or call a hosted provider.

  uv run --project backend python scripts/check_navigation_identity.py --help
  uv run --project backend python scripts/check_navigation_identity.py --run

--help and import do not load a model. --run (alias --run-only) writes a new
timestamped artifact and keeps every row, including a model-call error.
"""

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# kind, grounded subject, request, observed title, expected answer
CASES = (
    ('video', 'Artemis', 'Find a YouTube video about Artemis',
     'NASA’s Artemis II Crew Comes Home (Official Broadcast)', 'yes'),
    ('video', 'Artemis', 'Find a YouTube video about Artemis', 'NASA Artemis launch', 'yes'),
    ('video', 'Artemis', 'Find a YouTube video about Artemis', 'How to bake sourdough bread', 'no'),
    ('video', 'Artemis', 'Find a YouTube video about Artemis', 'NASA Apollo 11 Moon landing', 'no'),
    ('video', 'Artemis', 'Find a YouTube video about Artemis', '', 'unknown'),
    ('video', 'jazz piano', 'Find a YouTube video about jazz piano', 'Autumn Leaves | Solo Jazz Piano', 'yes'),
    ('video', 'jazz piano', 'Find a YouTube video about jazz piano', 'Guitar fingerstyle tutorial', 'no'),
    ('video', 'coral reefs', 'Find a YouTube video about coral reefs',
     'Life beneath the waves: coral reef ecosystems', 'yes'),
    ('channel', 'NASA', 'Open NASA’s YouTube channel', 'NASA', 'yes'),
    ('channel', 'NASA', 'Open NASA’s YouTube channel', 'SpaceX', 'no'),
    ('channel', 'NASA', 'Open NASA’s YouTube channel', 'NASA Fan Club', 'no'),
    ('playlist', 'NASA', 'Open a NASA playlist on YouTube', 'NASA Moon Tunes Playlist', 'yes'),
    ('playlist', 'NASA', 'Open a NASA playlist on YouTube', 'Cooking with Julia', 'no'),
)

_RESOURCE_URL = {
    'video': 'https://www.youtube.com/watch?v=AAAAAAAAAAA',
    'channel': 'https://www.youtube.com/@NASA',
    'playlist': 'https://www.youtube.com/playlist?list=PL0123456789ABCDEF',
}


def _probe_page(kind, title):
    """Synthetic page whose production alignment keeps the tested title. Blank title stays blank."""
    url = _RESOURCE_URL[kind]
    text = title if title else ''
    return {
        'url': url,
        'canonical_url': url,
        'heading': text,
        'title': text,
        'canonical_title': text,
    }


def _write_artifact(rows, error=None):
    stamp = datetime.now(UTC).strftime('%Y%m%dT%H%M%S%fZ')
    folder = ROOT / 'artifacts'
    folder.mkdir(exist_ok=True)
    output = folder / f'navigation-identity-semif-{stamp}.json'
    passed = sum(bool(row.get('passed')) for row in rows)
    payload = {
        'scope': 'Controlled local SemIf identity probes using production prompt, state, and criteria. '
                 'No native navigation and no hosted providers.',
        'passed': passed,
        'cases': len(CASES),
        'completed': len(rows),
        'rows': rows,
    }
    if error is not None:
        payload['error'] = f'{type(error).__name__}: {error}'
    output.write_text(json.dumps(payload, indent=2))
    print(f'{passed}/{len(rows)} {output}', flush=True)
    return output


def run_only():
    sys.path.insert(0, str(ROOT / 'backend'))
    from jet_browser.conversation import (
        _IDENTITY_CRITERIA,
        _IDENTITY_QUESTION,
        semantic_identity_state,
    )
    from jet_browser.routing import ROUTER_MODEL, LocalRouter
    from jev_ultrafast.local_models import NativeWorker

    worker = NativeWorker()
    router = LocalRouter(worker=worker)
    rows = []
    primary = None
    close_error = None
    try:
        for kind, subject, request, title, expected in CASES:
            page = _probe_page(kind, title)
            goal = {'kind': kind, 'query': subject}
            state = semantic_identity_state(request, page, goal)
            row = {
                'kind': kind,
                'subject': subject,
                'request': request,
                'title': title,
                'expected': expected,
                'state': state,
                'question': _IDENTITY_QUESTION,
                'criteria': _IDENTITY_CRITERIA,
            }
            try:
                answer, audit = router.choose(
                    ROUTER_MODEL, json.dumps(state, ensure_ascii=False), _IDENTITY_QUESTION, _IDENTITY_CRITERIA,
                )
            except Exception as exc:  # noqa: BLE001 — retain this probe, then stop
                row.update(passed=False, error=f'{type(exc).__name__}: {exc}')
                rows.append(row)
                primary = exc
                break
            row.update(answer=answer, passed=answer == expected, audit=audit)
            rows.append(row)
            print(kind, subject, json.dumps(title), answer, expected, flush=True)
    except Exception as exc:  # noqa: BLE001 — write partial rows before leaving
        primary = exc
    try:
        worker.close()
    except Exception as exc:  # noqa: BLE001 — worker shutdown must not hide the probe error
        close_error = exc
    _write_artifact(rows, primary or close_error)
    if primary is not None:
        raise primary
    if close_error is not None:
        raise close_error
    passed = sum(bool(row.get('passed')) for row in rows)
    if passed != len(CASES):
        raise SystemExit(f'{len(CASES) - passed} identity probe(s) failed; artifact retained')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--run', '--run-only', action='store_true',
                        help='Run the 13 controlled local SemIf probes. Does not read a service token.')
    args = parser.parse_args(argv)
    if not args.run:
        parser.error('Pass --run to load the local SemIf router. --help does not call a model.')
    run_only()


if __name__ == '__main__':
    main()
