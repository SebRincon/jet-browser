"""Reviewer repairs on a paused or completed workflow: exact-post recovery and local re-tagging.

Grok decides what to fix; code does the fixing. Recovery opens the exact X post in an
owned tab (guarded Show more, never repeated) and stores only observed text. Tags and
summaries come from the local model on stored evidence. Every change is audited, a user
Stop aborts, and the results Grok sees are metadata, not post text.
"""

from __future__ import annotations

from .workflow_capabilities import WorkflowCapabilities

# Browser recoveries one agent turn may request; each post at most once per turn.
RECOVERY_BUDGET = 20
RETAG_BATCH = 20


def _stopped_run(service, sid, wid):
    row = service.workflow_store.get(sid, wid)
    if not row:
        raise RuntimeError("workflow not found")
    if getattr(service.workflows, "running", False) or row.get("status") not in ("paused", "completed"):
        raise RuntimeError("pause the workflow before repairing records")
    return row


def _capability(service, sid, wid, **flags):
    # local_worker is a test seam; production uses the shared local model worker.
    return WorkflowCapabilities(service, service.workflow_store, sid, wid, service.chat_stopped,
                                lambda *_args: None, worker=getattr(service, "local_worker", None), **flags)


async def _local_tags(cap, item_id):
    classified = await cap.model_classify({"item_id": item_id})
    tags = list(classified.get("tags") or [])
    if not tags:
        best = await cap.model_best_tag({"item_id": item_id})
        if best.get("tag"):
            tags = [best["tag"]]
    return tags


async def _local_summary(cap, row, item_id):
    if "model.summarize" not in (row.get("definition") or {}).get("capabilities", []):
        return None
    summary = (await cap.model_summarize({"item_id": item_id})).get("summary")
    return summary[:1000] if isinstance(summary, str) and summary else None


async def recover(service, sid, wid, item_id):
    row = _stopped_run(service, sid, wid)
    if (row.get("definition") or {}).get("source_kind") != "x_bookmarks":
        raise ValueError("post recovery requires an X Bookmarks workflow")
    if service.tasks.running or service.collections.running or service.recovery_active:
        raise RuntimeError("another job owns the browser")
    store = service.workflow_store
    before = store.get_record(sid, wid, item_id)
    ledger = service.__dict__.setdefault("workflow_repairs", {})
    attempted = ledger.setdefault((wid, service.turn_id), set())
    if item_id in attempted:
        raise RuntimeError("this post was already attempted in this turn; browser actions are not retried")
    if len(attempted) >= RECOVERY_BUDGET:
        raise RuntimeError("the recovery budget for this turn is used; browser actions are not retried")
    attempted.add(item_id)
    service.recovery_active = True
    cap = _capability(service, sid, wid, repair=True)
    try:
        await cap.open()
        result = await cap.post_recover({"item_id": item_id})
        if result.get("blocked"):
            service.trace.emit("workflow.repair", task_id=wid, status="blocked", reason=result.get("reason"))
            return {"item_id": item_id, "status": "blocked", "reason": result.get("reason")}
        tags = await _local_tags(cap, item_id)
        patch = {"tags": tags}
        summary = await _local_summary(cap, row, item_id)
        if summary:
            patch["summary"] = summary
        fresh = store.get_record(sid, wid, item_id)
        saved = store.patch_record(sid, wid, item_id, patch, fresh["revision"], actor="local")
        service.trace.emit("workflow.repair", task_id=wid, status="recovered",
                           count=len(saved["text"]) - len(before["text"]))
        return {"item_id": item_id, "status": "recovered", "added_chars": len(saved["text"]) - len(before["text"]),
                "truncated": bool(saved["truncated"]), "tags": saved["tags"], "has_summary": bool(saved["summary"])}
    finally:
        cap.close()
        service.recovery_active = False


async def retag(service, sid, wid, item_ids, summarize=False):
    row = _stopped_run(service, sid, wid)
    if (not isinstance(item_ids, list) or not 1 <= len(item_ids) <= RETAG_BATCH
            or len(set(item_ids)) != len(item_ids) or not all(isinstance(i, str) for i in item_ids)):
        raise ValueError(f"item_ids must list 1 to {RETAG_BATCH} distinct record ids")
    store = service.workflow_store
    records = [store.get_record(sid, wid, item_id) for item_id in item_ids]  # Unknown ids fail first.
    cap = _capability(service, sid, wid, browserless=True)
    cap.definition = row["definition"]
    results = []
    for record in records:
        tags = await _local_tags(cap, record["id"])
        patch = {"tags": tags}
        if summarize:
            summary = await _local_summary(cap, row, record["id"])
            if summary:
                patch["summary"] = summary
        saved = store.patch_record(sid, wid, record["id"], patch, record["revision"], actor="local")
        results.append({"item_id": record["id"], "tags": saved["tags"],
                        "changed": saved["revision"] != record["revision"]})
    service.trace.emit("workflow.repair", task_id=wid, status="retagged", count=len(results))
    return {"records": results}


def flagged(store, sid, wid, needs):
    """Record ids and flags matching a need; metadata only, never post text."""
    total = store.records(sid, wid, limit=0)["total"]
    rows = []
    for offset in range(0, total, 100):
        rows.extend(store.records(sid, wid, limit=100, offset=offset)["items"])
    if needs == "untagged":
        rows = [r for r in rows if not r.get("tags")]
    elif needs == "truncated":
        rows = [r for r in rows if r.get("truncated")]
    return total, rows
