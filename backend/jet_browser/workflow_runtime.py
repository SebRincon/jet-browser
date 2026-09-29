"""One native JavaScriptCore process per workflow, with explicit host capabilities."""

from __future__ import annotations

import asyncio
import json
import time
from contextlib import suppress

_LIMIT = 200_000


async def run_script(executable, source, input_value, capabilities, stopped, *, seconds=60, max_calls=100):
    if not isinstance(source, str) or len(source.encode()) > 32000:
        raise ValueError("Workflow source exceeds 32KB")
    if not 0 < seconds <= 180 or type(max_calls) is not int or not 1 <= max_calls <= 1000:
        raise ValueError("Invalid workflow limits")
    request = json.dumps({"source": source, "input": input_value}, allow_nan=False).encode() + b"\n"
    if len(request) > _LIMIT:
        raise ValueError("Workflow input exceeds 200KB")
    if stopped.is_set():
        raise asyncio.CancelledError()
    process = await asyncio.create_subprocess_exec(
        str(executable),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
        limit=_LIMIT + 1,
        env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"},
    )
    deadline = time.monotonic() + seconds

    async def guarded(awaitable):
        task = asyncio.ensure_future(awaitable)
        try:
            while True:
                if stopped.is_set():
                    raise asyncio.CancelledError()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Workflow time limit reached")
                done, _ = await asyncio.wait({task}, timeout=min(0.05, remaining))
                if done:
                    return task.result()
        finally:
            if not task.done():
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task

    try:
        process.stdin.write(request)
        await guarded(process.stdin.drain())
        count = 0
        while True:
            line = await guarded(process.stdout.readline())
            if not line or len(line) > _LIMIT:
                raise RuntimeError("Invalid workflow response")
            message = json.loads(line)
            if not isinstance(message, dict):
                raise RuntimeError("Invalid workflow response")
            kind = message.get("type")
            if kind == "done":
                await guarded(process.wait())
                if process.returncode != 0:
                    raise RuntimeError("Workflow process failed")
                return message.get("result")
            if kind == "error":
                raise RuntimeError(str(message.get("error", "Workflow failed"))[:500])
            count += 1
            if kind != "call" or type(message.get("id")) is not int or message["id"] != count or count > max_calls:
                raise RuntimeError("Invalid workflow call sequence or budget")
            method = message.get("method")
            if not isinstance(method, str) or method not in capabilities:
                raise RuntimeError("Workflow capability is not enabled")
            if stopped.is_set():
                raise asyncio.CancelledError()
            result = await guarded(capabilities[method](message.get("args")))
            response = json.dumps({"id": count, "result": result}, allow_nan=False).encode() + b"\n"
            if len(response) > _LIMIT:
                raise RuntimeError("Workflow result exceeds 200KB")
            if stopped.is_set():
                raise asyncio.CancelledError()
            process.stdin.write(response)
            await guarded(process.stdin.drain())
    finally:
        if process.returncode is None:
            with suppress(ProcessLookupError):
                process.kill()
        await process.wait()
