"""Read-only local routing diagnostic.

Calls LocalRouter.route only. It does not open a browser, call a browser tool,
or use a hosted provider.

The 24 probes compare the router with an expected handler label. That is
diagnostic agreement, not accuracy and not an end-to-end success rate.
Three rows stay in the raw 24 and are left out of the current-supported
denominator of 21:

- wiki_ambiguous: a local search can be reasonable before clarification, so
  that row is not a demonstrated routing error
- extract and find_in_page: desired future local workflows, not handlers
  implemented today

Usage:
  uv run --project backend python scripts/audit_local_routing.py --score artifacts/local-first-routing-audit.json
  uv run --project backend python scripts/audit_local_routing.py --run
  uv run --project backend python scripts/audit_local_routing.py --run --output artifacts/custom.json

--run loads only the local model allowlist below and writes a new timestamped
artifact. It does not replace artifacts/local-first-routing-audit.json.
--score reads an existing artifact and does not call a model.
"""

import argparse
import hashlib
import json
import statistics
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))

CASES = [
    ('yt_video', 'Open the YouTube video titled Me at the zoo.', 'local'),
    ('yt_channel', 'Take me to the official NASA YouTube channel.', 'local'),
    ('yt_results', 'Show YouTube search results for lunar eclipses.', 'local'),
    ('yt_compound', 'Go to YouTube, open the NASA channel, then explain what its newest video is about.', 'grok'),
    ('wiki_results', 'Show Wikipedia search results for Elon Musk.', 'local'),
    ('wiki_negated_results', 'Do not show search results; open the actual Wikipedia article about Ada Lovelace.', 'local'),
    ('wiki_compare', 'Open the Wikipedia pages for Mercury the planet and Mercury the element, then compare them.', 'grok'),
    ('wiki_ambiguous', 'Open the Wikipedia page for Mercury.', 'grok'),
    ('github_repo', 'Open the browser-use/jev-ultrafast repository on GitHub.', 'local'),
    ('github_readme', 'Go to github.com/browser-use/jev-ultrafast and open its README.', 'local'),
    ('github_synthesis', 'Go to github.com/browser-use/jev-ultrafast and explain how its browser loop works.', 'grok'),
    ('official', 'Find the official Blender website.', 'local'),
    ('same_site', 'Now find Ada Lovelace there.', 'local'),
    ('recall', 'Which article did you open before this one?', 'grok'),
    ('form_values', 'Fill the name with Rowan and email with rowan@example.test, then stop before submitting.', 'local'),
    ('filter', 'Select Economy and one adult, and stop when matching flights are visible.', 'local'),
    ('extract', 'Copy the support email address from this page.', 'local'),
    ('find_in_page', 'Find the paragraph about cancellations on this page.', 'local'),
    ('count', 'How many videos on this page are over ten minutes long?', 'grok'),
    ('answer', 'What is the difference between a YouTube channel and a playlist?', 'grok'),
    ('negated_navigation', 'Do not open YouTube; explain what a playlist is.', 'grok'),
    ('missing_ref', 'Open that one.', 'grok'),
    ('tab_listing', 'Show me my open tabs.', 'local'),
    ('simple_back', 'Go back to the page I was just viewing.', 'local'),
]
EXCLUDED_FROM_SUPPORTED = frozenset({'wiki_ambiguous', 'extract', 'find_in_page'})
LOCAL_MODELS = ('qwen4b_semif_shared', 'lfm_rlcd', 'laya_mlx', 'laya_typed')
REFERENCE_CASES = frozenset({'same_site', 'recall', 'simple_back'})


def agreement(rows):
    """Handler agreement. Excluded rows remain in the raw count only."""
    raw = list(rows)
    supported = [row for row in raw if row.get('case') not in EXCLUDED_FROM_SUPPORTED]
    return {
        'raw_diagnostic_agreement': sum(bool(row.get('passed')) for row in raw),
        'raw_cases': len(raw),
        'supported_case_agreement': sum(bool(row.get('passed')) for row in supported),
        'supported_cases': len(supported),
    }


def score_artifact(payload):
    grouped = {}
    for row in payload.get('cases', []):
        grouped.setdefault(row.get('model', ''), []).append(row)
    return {model: agreement(rows) for model, rows in grouped.items()}


def run_models(models, output):
    from jet_browser.routing import LocalRouter
    from jev_ultrafast.local_models import NativeWorker
    unknown = [model for model in models if model not in LOCAL_MODELS]
    if unknown:
        raise SystemExit('Model is outside the local allowlist: ' + ', '.join(unknown))
    worker = NativeWorker()
    router = LocalRouter(worker=worker)
    browser = {'active_tab_id': 'qa', 'tabs': [
        {'id': 'qa', 'title': 'Elon Musk - Wikipedia', 'url': 'https://en.wikipedia.org/wiki/Elon_Musk'},
    ]}
    source = ROOT / 'backend/jet_browser/routing.py'
    meta = {
        'date': datetime.now(UTC).date().isoformat(),
        'scope': 'Diagnostic expected-handler agreement for 24 probes. Not accuracy and not end-to-end success. '
                 'wiki_ambiguous, extract, and find_in_page are excluded from the 21-case supported denominator.',
        'routing_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'models': [],
    }
    rows = []
    try:
        for model in models:
            started = time.monotonic()
            worker.start(model)
            load = round((time.monotonic() - started) * 1000)
            for case_id, prompt, expected in CASES:
                start = time.monotonic()
                row = {'model': model, 'case': case_id, 'prompt': prompt, 'expected_handler': expected}
                recent = ['Open the Wikipedia article about Elon Musk.'] if case_id in REFERENCE_CASES else []
                try:
                    route = router.route(prompt, model, browser, recent)
                    row.update(operation=route['operation'], handler=route['decision'],
                               passed=route['decision'] == expected, audit=route['audit'])
                except Exception as error:  # noqa: BLE001 — one probe must not abort the other 23
                    row.update(passed=False, error=str(error)[:500])
                row['elapsed_ms'] = round((time.monotonic() - start) * 1000)
                rows.append(row)
            subset = [row for row in rows if row['model'] == model]
            stats = agreement(subset)
            stats.update(model=model, load_ms=load, model_id=worker.metadata.get('model'),
                         median_ms=statistics.median(row['elapsed_ms'] for row in subset),
                         errors=sum('error' in row for row in subset))
            meta['models'].append(stats)
            print(json.dumps(stats), flush=True)
    finally:
        worker.close()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({'metadata': meta, 'cases': rows}, indent=2))
    print(output, flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--score', type=Path, help='Score an existing audit artifact. Does not call a model.')
    parser.add_argument('--run', action='store_true', help='Run the local model allowlist. Writes a new artifact.')
    parser.add_argument('--output', type=Path, help='Artifact path for --run. Defaults to a UTC timestamp under artifacts/.')
    parser.add_argument('--model', action='append', choices=LOCAL_MODELS, help='Restrict --run to these allowlisted models.')
    args = parser.parse_args(argv)
    if args.score:
        report = score_artifact(json.loads(args.score.read_text()))
        for model, stats in report.items():
            print(json.dumps({'model': model, **stats}))
        return
    if args.run:
        stamp = datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')
        output = args.output or (ROOT / 'artifacts' / f'local-first-routing-audit-{stamp}.json')
        run_models(tuple(args.model) if args.model else LOCAL_MODELS, output)
        return
    parser.error('Pass --score PATH or --run')


if __name__ == '__main__':
    main()
