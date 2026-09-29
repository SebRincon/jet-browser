import asyncio
import json
import os
import sys
import tempfile
import time
from dataclasses import replace
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(root / "backend"), str(root / "backend/tests")]

from jet_browser.collection_runner import CollectionManager
from jet_browser.collection_store import CollectionStore
from jet_browser.tracing import TraceStore
from jev_ultrafast.local_models import WORKER
from test_feed_dom import browser, plan


async def run(args):
    with tempfile.TemporaryDirectory(
        prefix="jet-live-feed-", dir="/private/tmp"
    ) as tmp:
        root = Path(tmp)
        gen = browser.__wrapped__(root)
        b = await anext(gen)
        store = CollectionStore(root)
        trace = TraceStore(root)
        try:
            await b.js(
                "document.querySelector('#feed').innerHTML=Array.from({length:40},(_,i)=>'<article><a href=/demo/status/'+(3000+i)+'><time>Today</time></a><div data-testid=tweetText>A software release adds improvements to the Python programming language. Release '+i+'</div></article>').join('')"
            )
            p = replace(
                plan(), model="qwen4b_semif_shared", max_scrolls=14, max_seconds=90
            )
            manager = CollectionManager(store, b, trace=trace)
            r = store.create("fixture-session", "fixture-turn", p)
            if args.supervised:
                manager.supervision.configure('fixture-session', r['id'], {'share_samples': False})
            start = time.monotonic()
            with trace.bind(session_id="fixture-session", turn_id="fixture-turn"):
                await manager.start("fixture-session", r["id"])
            while manager.running:
                await manager.wait("fixture-session", r["id"], 10)
            result = manager.summary("fixture-session", r["id"])
            requests = WORKER.records
            reviews = [
                x["result"]["answers"]["decision"]["label"]
                for x in requests
                if "decision" in x["request"]["questions"]
            ]
            evidence = {
                "fixture": "isolated Chromium feed, synthetic posts only",
                "actual_model": requests[-1]["result"].get("model")
                if requests
                else None,
                "wall_ms": round((time.monotonic() - start) * 1000, 1),
                "status": result["status"],
                "reason": result["reason"],
                "counters": result["counters"],
                "scrolls": result["progress"]["scrolls"],
                "local_review_decisions": reviews,
                "unique_items": len(store.seen_urls("fixture-session", r["id"])),
                "grok_calls": 0,
            }
            evidence['supervised'] = args.supervised
            evidence['checkpoint'] = ((result.get('supervision') or {}).get('pending') or {}).get('reason')
            evidence['sample_count'] = len((result.get('review') or {}).get('samples', []))
            evidence["passed"] = (
                result['reason'] == 'supervisor_review'
                and result['counters']['pages'] == 10
                and evidence['checkpoint'] == 'first_batch'
                and evidence['sample_count'] == 5
            ) if args.supervised else (
                result["reason"] == "scroll_budget"
                and result["progress"]["scrolls"] == 14
                and result["counters"]["pages"] >= 13
                and reviews == ["scroll", "scroll"]
            )
            Path(args.output).write_text(json.dumps(evidence, indent=2))
            print(json.dumps(evidence), flush=True)
            if not evidence["passed"]:
                raise RuntimeError(
                    "Feed diagnostic did not meet its acceptance checks; retained outcome above"
                )
        finally:
            WORKER.close()
            store.close()
            trace.close()
            await gen.aclose()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Explicit local SemIf + isolated Chromium feed diagnostic; uses no account or remote model."
    )
    parser.add_argument(
        "--chromium", required=True, help="Chromium headless-shell executable"
    )
    parser.add_argument("--supervised", action="store_true", help="Verify the first-ten checkpoint using the real local model")
    parser.add_argument("--output", default="/private/tmp/jet-live-feed-proof.json")
    args = parser.parse_args()
    os.environ["JET_TEST_CHROMIUM"] = str(Path(args.chromium).expanduser())
    asyncio.run(run(args))
