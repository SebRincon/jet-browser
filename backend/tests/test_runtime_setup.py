from __future__ import annotations

import asyncio
import hashlib
import os
import stat
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from jet_browser.runtime_setup import RuntimeSetup, redirect_host_allowed

REV = "ab" * 20


def _file(name: str, payload: bytes) -> dict:
    return {
        "path": name,
        "url": f"https://huggingface.co/org/model/resolve/{REV}/{name}",
        "size": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def _manifest(*models: dict) -> dict:
    return {"schema_version": 1, "models": list(models)}


def _model(mid: str, files: list[dict], directory: str | None = None) -> dict:
    total = sum(item["size"] for item in files)
    return {
        "id": mid,
        "title": mid,
        "description": "purpose",
        "directory": directory or mid,
        "repo": "org/model",
        "revision": REV,
        "bytes": total,
        "files": files,
    }


def _setup(tmp_path: Path, manifest: dict | None) -> RuntimeSetup:
    runtime = RuntimeSetup(tmp_path / "data", tmp_path / "res", manifest=manifest)
    runtime._disk_free = lambda path: 10**12  # noqa: SLF001
    return runtime


def test_hash_file_streams(tmp_path: Path) -> None:
    path = tmp_path / "blob.bin"
    payload = b"abc" * 1000
    path.write_bytes(payload)
    assert RuntimeSetup.hash_file(path) == hashlib.sha256(payload).hexdigest()


def test_parse_login_output_strips_ansi_and_ignores_other_secrets() -> None:
    text = (
        "\x1b[31mtoken SUPERSECRETVALUE\n"
        "https://evil.example/code\n"
        "Your code: ABCD-1234\n"
        "https://accounts.x.ai/i/flow/device\n"
    )
    url, code = RuntimeSetup.parse_login_output(text)
    assert url == "https://accounts.x.ai/i/flow/device"
    assert code == "ABCD-1234"


def test_redirect_hosts() -> None:
    assert redirect_host_allowed("https://cdn-lfs.huggingface.co/repo/a?sig=1")
    assert redirect_host_allowed("https://us.cloudfront.net/signed")
    assert redirect_host_allowed("https://cas-bridge.xethub.hf.co/x")
    assert not redirect_host_allowed("http://huggingface.co/org/model/resolve/x")
    assert not redirect_host_allowed("https://user:pw@huggingface.co/x")
    assert not redirect_host_allowed("https://example.com/huggingface.co")


def test_dev_models_without_manifest_are_development(tmp_path: Path) -> None:
    for mid in ("qwen4b", "qwen08b"):
        directory = tmp_path / "data" / "models" / mid
        directory.mkdir(parents=True)
        (directory / "config.json").write_text("{}", encoding="utf-8")
        (directory / "weights.safetensors").write_bytes(b"weights")
    runtime = RuntimeSetup(tmp_path / "data", tmp_path / "res")
    status = runtime.status()
    assert status["packaged"] is False
    assert status["ready"] is True
    row = next(item for item in status["models"] if item["id"] == "qwen4b")
    assert row["status"] == "installed"
    assert row["verification"] == "development"


def test_files_without_receipt_are_not_installed(tmp_path: Path) -> None:
    payload = b"weights"
    manifest = _manifest(_model("qwen4b", [_file("weights.safetensors", payload)]))
    runtime = _setup(tmp_path, manifest)
    directory = tmp_path / "data" / "models" / "qwen4b"
    directory.mkdir(parents=True)
    (directory / "config.json").write_text("{}", encoding="utf-8")
    (directory / "weights.safetensors").write_bytes(payload)
    row = runtime.status()["models"][0]
    assert row["status"] == "available"
    assert "verification" not in row


def test_unknown_model_and_traversal(tmp_path: Path) -> None:
    bad = _model(
        "qwen4b",
        [
            {
                "path": "../outside.bin",
                "url": f"https://huggingface.co/org/model/resolve/{REV}/../outside.bin",
                "size": 1,
                "sha256": hashlib.sha256(b"x").hexdigest(),
            }
        ],
    )
    runtime = _setup(tmp_path, _manifest(bad))

    async def forbidden(self, url, destination, expected_size):
        raise AssertionError("network")

    runtime._download_file = forbidden.__get__(runtime, RuntimeSetup)  # noqa: SLF001

    with pytest.raises(ValueError):
        asyncio.run(runtime.install("missing-model"))
    with pytest.raises(ValueError):
        asyncio.run(runtime.install("qwen4b"))


def test_install_verifies_hash_writes_receipt_and_rejects_competition(tmp_path: Path) -> None:
    payload = b"safe-weights"
    other = b"other"
    manifest = _manifest(
        _model("qwen4b", [_file("model.safetensors", payload)]),
        _model("qwen08b", [_file("model.safetensors", other)]),
    )
    runtime = _setup(tmp_path, manifest)
    calls = []

    async def fake_download(self, url, destination, expected_size):
        calls.append(url)
        assert url.startswith("https://huggingface.co/")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)

    runtime._download_file = fake_download.__get__(runtime, RuntimeSetup)  # noqa: SLF001

    async def run():
        status = await runtime.install("qwen4b")
        assert status["downloading"] == "qwen4b"
        assert runtime._task is not None  # noqa: SLF001
        await runtime._task  # noqa: SLF001
        done = runtime.status()
        row = done["models"][0]
        assert row["status"] == "installed"
        assert row["verification"] == "verified"
        receipt = tmp_path / "data" / "models" / "qwen4b" / ".jet-install.json"
        assert receipt.is_file()
        assert stat.S_IMODE(receipt.stat().st_mode) == 0o600
        again = await runtime.install("qwen4b")
        assert again["models"][0]["status"] == "installed"
        assert calls == [
            f"https://huggingface.co/org/model/resolve/{REV}/model.safetensors"
        ]

    asyncio.run(run())


def test_hash_mismatch_fails_without_receipt(tmp_path: Path) -> None:
    payload = b"expected"
    manifest = _manifest(_model("qwen4b", [_file("model.safetensors", payload)]))
    runtime = _setup(tmp_path, manifest)

    async def fake_download(self, url, destination, expected_size):
        destination.write_bytes(b"tampered")

    runtime._download_file = fake_download.__get__(runtime, RuntimeSetup)  # noqa: SLF001

    async def run():
        await runtime.install("qwen4b")
        await runtime._task  # noqa: SLF001
        row = runtime.status()["models"][0]
        assert row["status"] == "failed"
        assert "https://" not in row.get("error", "")
        assert not (tmp_path / "data" / "models" / "qwen4b" / ".jet-install.json").exists()

    asyncio.run(run())


def test_cancel_leaves_partial_and_blocks_second_download(tmp_path: Path) -> None:
    payload = b"12345678"
    manifest = _manifest(
        _model("qwen4b", [_file("model.safetensors", payload)]),
        _model("lfm350m", [_file("model.safetensors", payload)]),
    )
    runtime = _setup(tmp_path, manifest)
    started = asyncio.Event()

    async def hang(self, url, destination, expected_size):
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"part")
        started.set()
        await asyncio.sleep(3600)

    runtime._download_file = hang.__get__(runtime, RuntimeSetup)  # noqa: SLF001

    async def run():
        await runtime.install("qwen4b")
        await started.wait()
        with pytest.raises(RuntimeError):
            await runtime.install("lfm350m")
        status = await runtime.cancel()
        row = next(item for item in status["models"] if item["id"] == "qwen4b")
        assert row["status"] == "cancelled"
        assert (tmp_path / "data" / "models" / "qwen4b" / "model.safetensors.part").is_file()
        await runtime.close()

    asyncio.run(run())


def test_disk_space_refusal(tmp_path: Path) -> None:
    payload = b"1234"
    runtime = _setup(tmp_path, _manifest(_model("qwen4b", [_file("model.safetensors", payload)])))
    runtime._disk_free = lambda path: 0  # noqa: SLF001

    async def forbidden(self, url, destination, expected_size):
        raise AssertionError("network")

    runtime._download_file = forbidden.__get__(runtime, RuntimeSetup)  # noqa: SLF001
    with pytest.raises(RuntimeError, match="disk"):
        asyncio.run(runtime.install("qwen4b"))


def test_cached_login_is_owner_only(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    home = tmp_path / "home"
    auth = home / ".grok"
    auth.mkdir(parents=True)
    secret = auth / "auth.json"
    secret.write_text("{\"token\":\"nope\"}", encoding="utf-8")
    os.chmod(secret, 0o600)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setattr(Path, "home", staticmethod(lambda: home))
    runtime = RuntimeSetup(tmp_path / "data", tmp_path / "res")
    assert runtime.status()["grok"]["authenticated"] is True
    os.chmod(secret, 0o644)
    assert runtime.status()["grok"]["authenticated"] is False


def test_packaged_app_owns_its_grok_home_and_ignores_global_login(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    home = tmp_path / "home"
    (home / ".grok").mkdir(parents=True)
    global_auth = home / ".grok" / "auth.json"
    global_auth.write_text("{}", encoding="utf-8")
    os.chmod(global_auth, 0o600)
    monkeypatch.setattr(Path, "home", staticmethod(lambda: home))
    monkeypatch.delenv("JET_GROK_HOME", raising=False)
    (tmp_path / "res").mkdir()
    (tmp_path / "res" / "model-downloads.json").write_text('{"schema_version": 1, "models": []}', encoding="utf-8")
    (tmp_path / "res" / "bundle-manifest.json").write_text("{}", encoding="utf-8")
    runtime = RuntimeSetup(tmp_path / "data", tmp_path / "res")
    assert runtime.packaged and runtime.bundled
    jet_home = runtime.grok_home()
    assert jet_home == tmp_path / "data" / ".runtime" / "grok-home"
    assert stat.S_IMODE(jet_home.stat().st_mode) == 0o700
    # The developer's global sign-in does not count for the packaged app.
    assert runtime.status()["grok"]["authenticated"] is False
    assert runtime._app_env()["GROK_HOME"] == str(jet_home)
    own = jet_home / "auth.json"
    own.write_text("{}", encoding="utf-8")
    os.chmod(own, 0o600)
    assert runtime.status()["grok"]["authenticated"] is True
    monkeypatch.setenv("JET_GROK_HOME", str(tmp_path / "custom"))
    assert runtime.grok_home() == tmp_path / "custom"


def test_development_keeps_the_developer_grok_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("JET_GROK_HOME", raising=False)
    # A checkout ships model-downloads.json too; only the bundle manifest marks a packaged app.
    (tmp_path / "res").mkdir()
    (tmp_path / "res" / "model-downloads.json").write_text('{"schema_version": 1, "models": []}', encoding="utf-8")
    runtime = RuntimeSetup(tmp_path / "data", tmp_path / "res")
    assert runtime.grok_home() is None and "GROK_HOME" not in runtime._app_env()


def _fake_grok(path: Path, version: str, update_to: str | None = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    update = ""
    if update_to:
        name = f"grok-{update_to}-macos-aarch64"
        update = (
            'if [ "$1" = "update" ]; then\n'
            '  mkdir -p "$GROK_HOME/downloads" "$GROK_HOME/bin"\n'
            f"  printf '#!/bin/sh\\necho \"grok {update_to} (new) [stable]\"\\n' > \"$GROK_HOME/downloads/{name}\"\n"
            f'  chmod 755 "$GROK_HOME/downloads/{name}"\n'
            f'  ln -sf ../downloads/{name} "$GROK_HOME/bin/grok"\n'
            "  exit 0\n"
            "fi\n"
        )
    path.write_text(f'#!/bin/sh\n{update}echo "grok {version} (abc) [stable]"\n', encoding="utf-8")
    os.chmod(path, 0o755)
    return path


def _bundled(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, version: str, update_to: str | None = None) -> RuntimeSetup:
    monkeypatch.delenv("JET_GROK_HOME", raising=False)
    monkeypatch.delenv("JET_GROK_PATH", raising=False)
    res = tmp_path / "res"
    (res / "bin").mkdir(parents=True)
    (res / "model-downloads.json").write_text('{"schema_version": 1, "models": []}', encoding="utf-8")
    (res / "bundle-manifest.json").write_text("{}", encoding="utf-8")
    _fake_grok(res / "bin" / "grok", version, update_to)
    return RuntimeSetup(tmp_path / "data", res)


def test_newest_usable_grok_wins_and_the_floor_holds(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    runtime = _bundled(tmp_path, monkeypatch, "1.0.44")
    assert runtime.grok_binary() == tmp_path / "res" / "bin" / "grok"
    home = runtime.grok_home()
    newer = _fake_grok(home / "downloads" / "grok-1.0.50-macos-aarch64", "1.0.50")
    (home / "bin").mkdir()
    (home / "bin" / "grok").symlink_to("../downloads/grok-1.0.50-macos-aarch64")
    assert runtime.grok_binary() == newer.resolve()
    assert runtime.status()["grok"]["version"] == "1.0.50"
    # An updated copy older than the bundle loses; a link outside downloads/ is ignored.
    _fake_grok(newer, "1.0.42")
    assert runtime.grok_binary() == tmp_path / "res" / "bin" / "grok"
    outside = _fake_grok(tmp_path / "elsewhere" / "grok", "9.9.9")
    (home / "bin" / "grok").unlink()
    (home / "bin" / "grok").symlink_to(outside)
    assert runtime.grok_binary() == tmp_path / "res" / "bin" / "grok"
    _fake_grok(tmp_path / "res" / "bin" / "grok", "1.0.30")
    assert runtime.grok_binary() is None  # Below the ACP floor.


def test_update_installs_the_latest_grok_into_jets_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    runtime = _bundled(tmp_path, monkeypatch, "1.0.44", update_to="1.0.60")
    result = asyncio.run(runtime.update_grok())
    assert result == {"status": "current", "version": "1.0.60"}
    chosen = runtime.grok_binary()
    assert chosen.parent == (runtime.grok_home() / "downloads").resolve() and chosen.name.startswith("grok-1.0.60")
    assert runtime.status()["grok"]["update"] == "current"
