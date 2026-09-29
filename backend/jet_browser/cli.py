"""Small developer CLI for the same finite browser control plane used by Grok."""

import argparse
import json
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(prog="jet")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("status", "tabs", "read", "stop", "metrics"):
        commands.add_parser(name)
    trace = commands.add_parser('trace', help='Inspect the current conversation’s retained trace events')
    trace.add_argument('--turn', help='Filter by turn ID')
    trace.add_argument('--follow', action='store_true', help='Stream new events until Ctrl-C')
    commands.add_parser("open").add_argument("url")
    task = commands.add_parser("task")
    task.add_argument("goal")
    task.add_argument("--model", choices=["lfm_rlcd", "laya_mlx", "laya_typed", "qwen4b_semif_shared"])
    args = parser.parse_args()
    token = (ROOT / ".runtime/token").read_text().strip()
    with httpx.Client(base_url="http://127.0.0.1:9148", headers={"Authorization": "Bearer " + token}, timeout=170) as client:
        if args.command == 'trace':
            seen = set()
            try:
                while True:
                    response = client.get('/traces', params={'turn_id': args.turn} if args.turn else {})
                    response.raise_for_status()
                    result = response.json()
                    if not args.follow:
                        print(json.dumps(result, indent=2, ensure_ascii=False))
                        return
                    for event in result['events']:
                        if event['id'] not in seen:
                            print(json.dumps(event, ensure_ascii=False), flush=True)
                    seen = {event['id'] for event in result['events']}
                    time.sleep(1)
            except KeyboardInterrupt:
                return
        if args.command == 'metrics':
            response = client.get('/metrics')
        elif args.command == "status":
            response = client.get("/state")
        else:
            names = {"tabs": "list_tabs", "read": "read_page", "open": "open_url", "task": "run_task", "stop": "stop_task"}
            payload = {}
            if args.command == "open":
                payload["url"] = args.url
            if args.command == "task":
                payload["goal"] = args.goal
                if args.model:
                    payload["model"] = args.model
            response = client.post("/mcp/tool", json={"name": names[args.command], "arguments": payload})
        print(json.dumps(response.json(), indent=2, ensure_ascii=False))
        response.raise_for_status()


if __name__ == "__main__":
    main()
