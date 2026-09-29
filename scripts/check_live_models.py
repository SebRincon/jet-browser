"""Real serial native-browser checks, using only the local workshop fixture."""

import argparse
import json
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", nargs="+", default=["lfm_rlcd", "laya_mlx", "laya_typed", "qwen4b_semif_shared"])
    parser.add_argument("--replacement", action="store_true")
    parser.add_argument("--port", type=int, default=9148, help="service port of the instance under test")
    parser.add_argument("--data-root", type=Path, default=ROOT,
                        help="that instance's JET_DATA_ROOT (its .runtime/token authenticates the checks)")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts")
    args = parser.parse_args()
    # The token is read privately and never printed.
    client = httpx.Client(base_url=f"http://127.0.0.1:{args.port}", timeout=25,
                         headers={"Authorization": "Bearer " + (args.data_root / ".runtime/token").read_text().strip()})

    def tool(name, arguments):
        response = client.post('/mcp/tool', json={"name": name, "arguments": arguments})
        response.raise_for_status()
        return response.json()

    rows = []
    for model in args.models:
        tab_id = client.get('/state').json()['browser']['active_tab_id']
        url = f'http://127.0.0.1:{args.port}/fixture'
        if args.replacement:
            url += '?team=Home&email=old%40example.test'
        tool('open_url', {"url": url, "tab_id": tab_id})
        for _ in range(60):
            try:
                page = tool('read_page', {"tab_id": tab_id})
            except httpx.HTTPStatusError:
                time.sleep(.1)
                continue
            fields = [a for a in page.get('actions', []) if a.get('kind') == 'fill']
            if len(fields) == 2 and (not args.replacement or any(a.get('value') == 'Home' for a in fields)):
                break
            time.sleep(.1)
        else:
            raise RuntimeError('Fixture did not load')
        goal = ('Enter Solstice in Team name; type ash@example.test in Contact email; '
                'set Session to Afternoon; enable Updates; open Preview registration.')
        response = client.post('/tasks', json={"goal": goal, "model": model, "tab_id": tab_id})
        response.raise_for_status()
        task = response.json()
        print(model + ': started ' + task['id'], flush=True)
        for _ in range(800):
            task = client.get('/state').json()['task']
            if task['status'] not in ['loading', 'running', 'stopping']:
                break
            time.sleep(.2)
        final = tool('read_page', {"tab_id": tab_id})
        text = final.get('text', '')
        expected = ['Registration preview', 'team: Solstice', 'email: ash@example.test',
                    'session: Afternoon', 'updates: true']
        verified = task['status'] == 'done' and all(item in text for item in expected)
        rows.append({"task": task, "observed_page": final, "independently_verified": verified,
                     "replacement": args.replacement})
        print(json.dumps({"model": model, "verified": verified, "status": task['status'],
                          "elapsed_ms": task['elapsed_ms'], "load_ms": task.get('load_ms'),
                          "steps": task['steps'], "native_calls": task['native_calls'],
                          "typing_calls": task['typing_calls'], "error": task.get('error')}), flush=True)
    folder = args.output_dir
    folder.mkdir(exist_ok=True)
    output = folder / ('native-check-' + str(time.time_ns()) + '.json')
    output.write_text(json.dumps(rows, indent=2))
    print(str(output))
    if not all(row['independently_verified'] for row in rows):
        raise SystemExit('Some tasks failed; inspect retained evidence')


if __name__ == '__main__':
    main()
