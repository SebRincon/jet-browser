"""Enrich one saved ten-bookmark batch locally; publish a bounded workspace report."""

import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from jet_browser.bookmark_organizer import enrich, render_csv, render_html
from jev_ultrafast.local_models import WORKER


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--collection", required=True)
    parser.add_argument(
        "--end", type=int, required=True, help="End at 10,20,...100 saved bookmarks"
    )
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    if not all(
        re.fullmatch("[0-9a-f]{32}", v) for v in (args.session, args.collection)
    ):
        parser.error("Invalid session or collection id")
    if args.end not in range(10, 101, 10):
        parser.error("End must be a multiple of ten, at most 100")
    os.umask(0o077)
    folder = ROOT / ".runtime" / "bookmark-jobs"
    folder.mkdir(mode=0o700, exist_ok=True)
    path = folder / (args.collection + ".json")
    headers = {
        "Authorization": "Bearer " + (ROOT / ".runtime/token").read_text().strip()
    }
    with (
        httpx.Client(
            base_url="http://127.0.0.1:9148", headers=headers, timeout=60
        ) as api,
        httpx.Client(timeout=90) as local,
    ):

        def state():
            r = api.get("/state")
            r.raise_for_status()
            d = r.json()
            if d["session"]["id"] != args.session:
                raise RuntimeError("User changed conversation; stopped")
            if d["busy"] or d["chat_busy"]:
                raise RuntimeError("Jet is busy; wait for the checkpoint")
            return d

        state()
        source = []
        for offset in range(0, args.end, 50):
            r = api.get(
                f"/collections/{args.collection}",
                params={"offset": offset, "limit": min(50, args.end - offset)},
            )
            r.raise_for_status()
            source.extend(r.json()["items"])
        if len(source) != args.end:
            raise RuntimeError("Requested source batch is not saved yet")
        job = (
            json.loads(path.read_text())
            if path.exists()
            else {
                "session_id": args.session,
                "collection_id": args.collection,
                "items": [],
                "batches": [],
            }
        )
        if job["session_id"] != args.session:
            raise RuntimeError("Job belongs to another conversation")
        previous = {i["id"]: i for i in job["items"]}
        start = time.monotonic()
        done = []

        def persist():
            job["items"] = done + [
                i for i in job["items"] if i["id"] not in {j["id"] for j in done}
            ]
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(job, ensure_ascii=False))
            tmp.chmod(0o600)
            tmp.replace(path)

        try:
            for row in source:
                state()
                fingerprint = hashlib.sha256(
                    json.dumps(
                        {
                            k: row.get(k)
                            for k in ("text", "author", "published_at", "truncated")
                        },
                        sort_keys=True,
                    ).encode()
                ).hexdigest()
                existing = previous.get(row["id"])
                if existing and existing.get("source_fingerprint") == fingerprint:
                    out = existing
                else:
                    out = enrich(row, WORKER, local)
                    out["source_fingerprint"] = fingerprint
                    out["recovery"] = row.get("recovery")
                    out["tag_revision"] = "bookmark-multitag-v2"
                done.append(out)
                persist()
                print(
                    json.dumps(
                        {
                            "organized": len(done),
                            "target": args.end,
                            "tag_count": len(out["tags"]),
                        }
                    ),
                    flush=True,
                )
            job["batches"].append(
                {
                    "end": args.end,
                    "elapsed_seconds": round(time.monotonic() - start, 2),
                    "at": time.time(),
                }
            )
            persist()
            if args.publish:
                docs = {
                    "bookmarks-" + str(args.end) + ".html": render_html(done),
                    "bookmarks-" + str(args.end) + ".csv": render_csv(done),
                    "bookmarks-" + str(args.end) + ".json": json.dumps(
                        {
                            "items": [
                                {k: v for k, v in i.items() if k != "text"}
                                for i in done
                            ],
                            "batches": job["batches"],
                        },
                        ensure_ascii=False,
                        indent=2,
                    ),
                }
                files = []
                for name, content in docs.items():
                    state()
                    if len(content.encode()) > 200000:
                        raise RuntimeError("Artifact exceeds workspace limit")
                    r = api.post(
                        "/mcp/tool",
                        json={
                            "name": "workspace_write",
                            "arguments": {
                                "name": name,
                                "content": content,
                                "area": "artifacts",
                            },
                        },
                    )
                    r.raise_for_status()
                    files.append(r.json())
                job["artifacts"] = files
                persist()
                print(json.dumps({"artifacts": files}), flush=True)
        finally:
            WORKER.close()


if __name__ == "__main__":
    main()
