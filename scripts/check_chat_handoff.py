"""Live Grok -> local model -> native form check (uses the installed Grok login)."""

import json
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[1]


def main():
    with httpx.Client(
        base_url="http://127.0.0.1:9148", timeout=25,
        headers={"Authorization": "Bearer " + (ROOT / ".runtime/token").read_text().strip()},
    ) as client:
        def post(path, body):
            response = client.post(path, json=body)
            response.raise_for_status()
            return response.json()

        def tool(name, arguments):
            return post("/mcp/tool", {"name": name, "arguments": arguments})

        before = client.get("/state").json()
        if before["provider"]["status"] in {"connecting", "running"}:
            raise RuntimeError("Wait for the current chat turn before running this check")
        if (before.get("task") or {}).get("status") in {"loading", "running", "stopping"}:
            raise RuntimeError("Wait for the current browser task before running this check")
        tab_id = before["browser"]["active_tab_id"]
        old_tasks = {task["id"] for task in before["task_history"]}
        old_messages = {message["id"] for message in before["messages"]}
        post("/settings", {"local_model": "lfm_rlcd"})
        tool("open_url", {"url": "http://127.0.0.1:9148/fixture", "tab_id": tab_id})
        for _ in range(80):
            try:
                page = tool("read_page", {"tab_id": tab_id})
                if len([a for a in page.get("actions", []) if a.get("kind") == "fill"]) == 2:
                    break
            except httpx.HTTPStatusError:
                pass
            time.sleep(.1)
        else:
            raise RuntimeError("Local fixture did not load")

        prompt = (
            "On the current workshop page, enter Solstice in Team name; type ash@example.test "
            "in Contact email; set Session to Afternoon; enable Updates; open Preview registration. "
            "Use the local browser tool with the currently selected local model to do the form. "
            "Inspect the resulting page and summarize the actual values using Markdown."
        )
        started = time.monotonic()
        post("/chat", {"message": prompt})
        print("Started real Grok chat handoff", flush=True)
        observations = []
        previous = None
        for _ in range(600):
            state = client.get("/state").json()
            new_messages = [m for m in state["messages"] if m["id"] not in old_messages]
            task = state.get("task") or {}
            observation = {
                "provider": state["provider"]["status"],
                "assistant_chars": sum(len(m["text"]) for m in new_messages if m["role"] == "assistant"),
                "task_id": task.get("id"), "task_status": task.get("status"),
                "actions": len(task.get("actions", [])),
            }
            if observation != previous:
                observations.append({"elapsed_ms": round((time.monotonic() - started) * 1000), **observation})
                print(json.dumps(observations[-1]), flush=True)
                previous = observation
            if state["provider"]["status"] in {"ready", "error"} and new_messages:
                break
            time.sleep(.5)
        else:
            post("/chat/stop", {})
            raise RuntimeError("Grok handoff exceeded five minutes; stop requested")
        page = tool("read_page", {"tab_id": tab_id})
        tasks = [t for t in state["task_history"] if t["id"] not in old_tasks]
        expected = ["Registration preview", "team: Solstice", "email: ash@example.test",
                    "session: Afternoon", "updates: true"]
        verified = (
            state["provider"]["status"] == "ready" and len(tasks) == 1
            and tasks[0]["model"] == "lfm_rlcd" and tasks[0]["status"] == "done"
            and all(value in page.get("text", "") for value in expected)
        )
        evidence = {"prompt": prompt, "observations": observations, "messages": new_messages,
                    "tasks": tasks, "activity": state["activity"], "observed_page": page,
                    "independently_verified": verified,
                    "total_elapsed_ms": round((time.monotonic() - started) * 1000)}
        output = ROOT / "artifacts" / ("grok-handoff-" + str(time.time_ns()) + ".json")
        output.parent.mkdir(exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2))
        print(str(output), flush=True)
        if not verified:
            raise SystemExit("Handoff failed independent verification; evidence retained")


if __name__ == "__main__":
    main()
