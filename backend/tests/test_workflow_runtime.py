import asyncio
import threading
from pathlib import Path

import pytest

from jet_browser.workflow_runtime import run_script


@pytest.fixture
def executable():
    path = Path(__file__).resolve().parents[2] / ".runtime/bin/jet-workflow"
    if not path.exists():
        pytest.skip("Build native workflow runtime first")
    return path


async def test_native_javascript_calls_only_advertised_capabilities(executable):
    calls = []

    async def count(args):
        calls.append(args)
        return {"count": args["n"] + 1}

    out = await run_script(
        executable, 'return jet.call("count", {n: jet.input.n});', {"n": 4}, {"count": count}, threading.Event()
    )
    assert out == {"count": 5} and calls == [{"n": 4}]


async def test_no_node_or_page_privileges(executable):
    out = await run_script(
        executable, "return [typeof require, typeof process, typeof fetch, typeof document];", {}, {}, threading.Event()
    )
    assert out == ["undefined"] * 4


async def test_unadvertised_capability_never_dispatches(executable):
    with pytest.raises(RuntimeError):
        await run_script(executable, 'jet.call("shell", {cmd:"whoami"});', {}, {}, threading.Event())


async def test_infinite_loop_has_hard_deadline(executable):
    with pytest.raises(TimeoutError):
        await run_script(executable, "while(true) {}", {}, {}, threading.Event(), seconds=0.2)


async def test_stop_prevents_a_second_host_call(executable):
    event = threading.Event()
    calls = []

    async def stop(args):
        calls.append(args)
        event.set()
        return True

    with pytest.raises(asyncio.CancelledError):
        await run_script(executable, 'jet.call("stop", {}); jet.call("stop", {});', {}, {"stop": stop}, event)
    assert len(calls) == 1
