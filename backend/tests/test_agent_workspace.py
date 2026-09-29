import pytest
from aiohttp import ClientSession
from aiohttp.test_utils import TestServer

from jet_browser.service import PORT, Service, create_app
from jet_browser.workspace import WorkspaceStore

SID = "a" * 32
OTHER = "b" * 32


def test_private_immutable_session_files_survive_restart_and_paginate(tmp_path):
    store = WorkspaceStore(tmp_path / "jet")
    first = store.write(SID, name="research.md", content="# Research\n" + "é" * 25000)
    second = store.write(SID, name="research.md", content="Revision two", area="scratch")
    assert first["id"] != second["id"]
    assert len(store.list(SID)) == 2 and store.list(OTHER) == []
    with pytest.raises(ValueError):
        store.read(OTHER, first["id"])
    page = store.read(SID, first["id"], limit=100)
    assert len(page["content"]) == 100 and page["next_offset"] == 100
    next_page = store.read(SID, first["id"], offset=100, limit=20000)
    assert next_page["content"] == "é" * 20000
    assert "content" not in str(store.list(SID))
    files = list((tmp_path / "jet" / "workspaces" / SID).rglob("*"))
    assert any(p.name.endswith("-research.md") for p in files)
    for path in files:
        assert path.stat().st_mode & 0o077 == 0
    store.close()
    again = WorkspaceStore(tmp_path / "jet")
    assert again.read(SID, second["id"])["content"] == "Revision two"
    again.close()


@pytest.mark.parametrize(
    "name", ["../secret.md", ".secret.md", "a/b.md", "a\\b.md", "x..md", "x.py", "/a.txt", "a\x00.txt"]
)
def test_model_cannot_choose_arbitrary_paths(tmp_path, name):
    store = WorkspaceStore(tmp_path / "jet")
    with pytest.raises(ValueError):
        store.write(SID, name=name, content="no")
    assert store.list(SID) == []
    store.close()


def test_workspace_limits_and_symlinks(tmp_path):
    store = WorkspaceStore(tmp_path / "jet")
    for kw in [{"content": "é" * 100001}, {"area": "../outside"}, {"name": "x.md", "content": None}]:
        with pytest.raises(ValueError):
            store.write(SID, **({"name": "ok.md", "content": "ok"} | kw))
    with pytest.raises(ValueError):
        store.write("../escape", name="ok.md", content="no")
    external = tmp_path / "outside"
    external.mkdir()
    (tmp_path / "jet" / "workspaces" / OTHER).symlink_to(external, target_is_directory=True)
    with pytest.raises((ValueError, OSError)):
        store.write(OTHER, name="no.md", content="no")
    assert list(external.iterdir()) == []
    f = store.write(SID, name="safe.md", content="hello")
    disk = next((tmp_path / "jet" / "workspaces" / SID).rglob(f["id"] + "-*"))
    disk.unlink()
    disk.symlink_to("/etc/hosts")
    with pytest.raises((ValueError, OSError)):
        store.read(SID, f["id"])
    store.close()


async def test_tools_auth_private_previews_and_session_context(tmp_path):
    s = Service(tmp_path)
    text = '<script>window.BAD=1</script><img src="https://evil.test"><h1>Private artifact</h1>'
    f = await s.tool("workspace_write", {"name": "demo.html", "content": text})
    # Contract: write result is metadata (either flat or explicitly file-wrapped).
    f = f.get("file", f)
    fid = f["id"]
    assert "Private artifact" not in str(s.state()["workspace"])
    async with TestServer(create_app(s)) as server, ClientSession() as c:
        host = {"Host": f"127.0.0.1:{PORT}"}
        auth = host | {"Authorization": "Bearer " + s.token}
        path = "/workspace/" + fid
        assert (await c.get(server.make_url("/workspace"), headers=host)).status == 401
        assert (await c.get(server.make_url(path), headers=host)).status == 401
        read = await c.get(server.make_url(path), headers=auth)
        assert (await read.json())["content"] == text
        issue = await c.post(server.make_url(path + "/preview"), headers=auth, json={})
        assert issue.status == 200
        relative = (await issue.json())["url"]
        assert s.token not in relative and fid not in relative
        preview = await c.get(server.make_url(relative), headers=host)
        assert preview.status == 200 and "Private artifact" in await preview.text()
        csp = preview.headers["Content-Security-Policy"]
        assert "sandbox" in csp and "default-src 'none'" in csp and "script-src 'none'" in csp
        assert preview.headers["Referrer-Policy"] == "no-referrer"
        assert "no-store" in preview.headers["Cache-Control"]
        assert (await c.get(server.make_url(relative), headers=host | {"Origin": "https://evil.test"})).status == 403
        assert (await c.get(server.make_url("/artifacts/view/unknown"), headers=host)).status == 404
        metrics = str(s.trace.metrics())
        assert relative.split("/")[-1] not in metrics
        history = await s.tool("conversation_history", {})
        assert "Private artifact" not in str(history)
        await s.select_session()
        assert (await c.get(server.make_url(path), headers=auth)).status == 400
        assert s.state()["workspace"]["files"] == []


def test_html_document_meta_does_not_hide_body_and_preview_expires(tmp_path, monkeypatch):
    from jet_browser import workspace

    s = WorkspaceStore(tmp_path / "jet")
    f = s.write(
        SID,
        name="page.html",
        content='<!doctype html><html><head><meta charset="utf-8"><title>X</title></head><body><h1>Visible result</h1></body></html>',
    )
    now = workspace.time.time()
    cap = s.issue_preview(SID, f["id"]).split("/")[-1]
    assert "<h1>Visible result</h1>" in s.preview(cap)[0]
    monkeypatch.setattr(workspace.time, "time", lambda: now + 601)
    with pytest.raises(LookupError):
        s.preview(cap)
    s.close()


async def test_chat_and_documents_work_while_background_loop_retains_browser(tmp_path):
    import asyncio

    s = Service(tmp_path)
    gate = asyncio.Event()
    s.collections.job = asyncio.create_task(gate.wait())
    calls = []

    async def fake_grok(text):
        calls.append(text)
        await s.tool("workspace_write", {"name": "note.md", "content": "# While organizing"})
        with pytest.raises(ValueError, match="collection owns"):
            await s.tool("open_url", {"url": "https://example.test"})
        s.message("assistant", "Saved your note.", source="grok")

    s._grok_turn = fake_grok
    assert s.state()["busy"] and not s.state()["chat_busy"]
    await s.chat("Save a note while organizing")
    await s.chat_job
    assert calls == ["Save a note while organizing"]
    assert s.collections.running and len(s.workspace.list(s.store.current_id)) == 1
    with pytest.raises(ValueError):
        await s.select_session()
    for name, args in [
        ("workspace_list", {"path": "/etc"}),
        ("workspace_write", {"name": "note.md", "content": "a", "path": "/etc"}),
        ("workspace_read", {"file_id": "0" * 32, "offset": 1.2}),
    ]:
        with pytest.raises(ValueError):
            await s.tool(name, args)
    gate.set()
    await s.collections.job
    s.workspace.close()
    s.collection_store.close()
    s.store.close()
    s.trace.close()


async def test_job_narration_is_folded_but_completed_answers_are_preserved(tmp_path):
    import asyncio

    s = Service(tmp_path)
    s.turn_id = "turn"
    s.response = s.message("assistant", "I will write the document.", source="grok")
    previous = s.response
    gate = asyncio.Event()
    s.chat_job = asyncio.create_task(gate.wait())
    await s.tool("workspace_write", {"name": "note.md", "content": "hello"})
    assert previous["phase"] == "progress" and s.response is None
    assert s.store.messages()[-1]["phase"] == "progress"
    gate.set()
    await s.chat_job
    s.response = s.message("assistant", "Saved your note.", source="grok")
    await s.tool("workspace_list", {})
    assert "phase" not in s.response
    s.workspace.close()
    s.collection_store.close()
    s.store.close()
    s.trace.close()
