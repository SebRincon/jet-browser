"""First-run bundled runtime: model downloads and Grok device login.

The shipped manifest is immutable. Install trusts a model only after a
receipt matches the pinned revision and digests. Status never hashes
multi-gigabyte files.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import shutil
import stat
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

CHUNK = 1024 * 1024
HEADROOM = 256 * 1024 * 1024
LOGIN_CAP = 8192
LOGIN_TIMEOUT_S = 180
MAX_REDIRECTS = 5
REQUIRED_IDS = ("qwen4b", "qwen08b")

_DEV_CATALOG = (
    ("qwen4b", "Qwen 4B", "On-device assistant"),
    ("qwen08b", "Qwen 0.8B", "Fast local assistant"),
    ("lfm350m", "LFM 350M", "Small language model"),
    ("laya-english", "Laya English", "Small local decision model"),
    ("laya-typed", "Laya Typed", "Structured local decisions"),
)

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
_REV_RE = re.compile(r"^[0-9a-f]{40}$")
_SHA_RE = re.compile(r"^[0-9a-f]{64}$")
_REPO_RE = re.compile(r"^[\w.-]+/[\w.-]+$")
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_URL_RE = re.compile(r"https://(?:auth\.x\.ai|accounts\.x\.ai)/[^\s<>\"]+")
_CODE_RE = re.compile(
    r"(?i)\bcode\b[^A-Za-z0-9]{0,16}([A-Za-z0-9][A-Za-z0-9-]{3,15})\b"
)
_RANGE_RE = re.compile(r"bytes (\d+)-(\d+)/(\d+|\*)")
_REDIRECT_HOSTS = ("huggingface.co", "hf.co", "xethub.hf.co", "cloudfront.net")
_ENV_KEEP = ("PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SYSTEMROOT")
_GROK_VERSION_RE = re.compile(r"^grok (\d+)\.(\d+)\.(\d+)\b")
# Jet always uses the newest Grok it has; this is only a floor. 1.0.41 is the first release
# whose ACP tool identity (`_meta["x.ai/tool"]`) Jet's permission check reads. An older or
# unrecognized binary is never chosen; a newer one that changes that format fails closed.
GROK_MIN_VERSION = (1, 0, 41)
GROK_UPDATE_TIMEOUT_S = 300


def redirect_host_allowed(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.username or parsed.password:
        return False
    host = (parsed.hostname or "").lower().rstrip(".")
    if not host:
        return False
    return any(host == base or host.endswith("." + base) for base in _REDIRECT_HOSTS)


class RuntimeSetup:
    def __init__(self, data_root, resource_root, port=9148, manifest=None):
        self.data_root = Path(data_root)
        self.resource_root = Path(resource_root)
        self.port = int(port)
        shipped = self.resource_root / "model-downloads.json"
        self.packaged = shipped.is_file()
        # Only package_runtime.py writes this. A checkout also has model-downloads.json,
        # so `packaged` alone would give development runs an unsigned-in Jet Grok home.
        self.bundled = (self.resource_root / "bundle-manifest.json").is_file()
        if manifest is not None:
            self._manifest = manifest
        elif self.packaged:
            self._manifest = json.loads(shipped.read_text(encoding="utf-8"))
        else:
            self._manifest = {"schema_version": 1, "models": []}
        if not isinstance(self._manifest, dict):
            self._manifest = {"schema_version": 1, "models": []}
        models = self._manifest.get("models") or []
        self._models = [m for m in models if isinstance(m, dict)]
        self._by_id = {str(m.get("id")): m for m in self._models if m.get("id")}
        self._phase: dict[str, str] = {}
        self._errors: dict[str, str] = {}
        self._task: asyncio.Task | None = None
        self._active_id: str | None = None
        self._cancel_requested = False
        self._login_proc: asyncio.subprocess.Process | None = None
        self._login_task: asyncio.Task | None = None
        self._login_status = "idle"
        self._login_deadline = 0.0
        self._verification_url: str | None = None
        self._user_code: str | None = None
        self._login_error: str | None = None
        self._grok_versions: dict[tuple, tuple | None] = {}
        self._grok_update: dict = {"status": "idle"}

    def grok_home(self) -> Path | None:
        """Grok's config, sign-in and session directory for this Jet install.

        A bundled app owns its Grok home under its data root, so the user's global
        ~/.grok MCP servers, hooks, plugins and sessions never load into Jet, and sign-in
        happens in Jet's setup. Development uses the developer's ~/.grok unless
        JET_GROK_HOME names another directory.
        """
        override = os.environ.get("JET_GROK_HOME")
        if override:
            home = Path(override).expanduser()
        elif self.bundled:
            home = self.data_root / ".runtime" / "grok-home"
        else:
            return None
        home.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(home, 0o700)
        return home

    def status(self) -> dict:
        if self._by_id:
            models = [self._view_manifest(m) for m in self._models]
        else:
            models = [self._view_dev(mid, title, desc) for mid, title, desc in _DEV_CATALOG]
        by_id = {m["id"]: m for m in models}
        ready = all(by_id.get(mid, {}).get("status") == "installed" for mid in REQUIRED_IDS)
        active = None
        if self._task is not None and not self._task.done() and self._active_id:
            active = self._active_id
        binary = self.grok_binary()
        version = self.grok_version(binary) if binary is not None else None
        grok: dict = {
            "available": binary is not None,
            "version": ".".join(map(str, version)) if version else None,
            "update": self._grok_update.get("status"),
            "authenticated": self._cached_login(),
            "login_status": self._login_status,
        }
        if grok["login_status"] == "idle" and grok["authenticated"]:
            grok["login_status"] = "cached"
        if self._login_status == "authenticated":
            grok["authenticated"] = True
        if self._verification_url:
            grok["verification_url"] = self._verification_url
        if self._user_code:
            grok["user_code"] = self._user_code
        if self._login_error:
            grok["error"] = self._login_error
        return {
            "packaged": self.packaged,
            "ready": ready,
            "models": models,
            "downloading": active,
            "grok": grok,
        }

    async def install(self, model_id: str) -> dict:
        mid = str(model_id)
        if mid not in self._by_id:
            if not self._by_id and any(mid == item[0] for item in _DEV_CATALOG):
                if self._dev_present(mid):
                    return self.status()
                raise RuntimeError("This runtime has no packaged model download")
            raise ValueError("Unknown model")
        if self._task is not None and not self._task.done():
            raise RuntimeError("Another download is already running")
        model = self._by_id[mid]
        self._validate_model(model)
        if self._receipt_ok(model):
            self._phase.pop(mid, None)
            self._errors.pop(mid, None)
            return self.status()
        need = self._remaining(model) + HEADROOM
        self.data_root.mkdir(parents=True, exist_ok=True)
        if self._disk_free(self.data_root) < need:
            raise RuntimeError("Not enough disk space")
        self._cancel_requested = False
        self._errors.pop(mid, None)
        self._phase[mid] = "downloading"
        self._active_id = mid
        self._task = asyncio.create_task(self._worker(model))
        return self.status()

    async def cancel(self) -> dict:
        self._cancel_requested = True
        task = self._task
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        if self._active_id and self._phase.get(self._active_id) in ("downloading", "verifying"):
            self._phase[self._active_id] = "cancelled"
        return self.status()

    async def login(self) -> dict:
        proc = self._login_proc
        if proc is not None and proc.returncode is None:
            return self.status()
        binary = self.grok_binary()
        if binary is None:
            self._login_status = "error"
            self._login_error = "Sign-in is unavailable"
            return self.status()
        runtime = self.data_root / ".runtime"
        runtime.mkdir(mode=0o700, exist_ok=True)
        os.chmod(runtime, 0o700)
        sock = runtime / "grok-login.sock"
        if sock.exists() or sock.is_symlink():
            sock.unlink()
        self._login_status = "pending"
        self._login_error = None
        self._verification_url = None
        self._user_code = None
        self._login_deadline = time.monotonic() + LOGIN_TIMEOUT_S
        self._login_proc = await asyncio.create_subprocess_exec(
            str(binary),
            "login",
            "--device-auth",
            "--leader-socket",
            str(sock),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=self._app_env(),
        )
        self._login_task = asyncio.create_task(self._read_login(self._login_proc))
        return self.status()

    async def close(self) -> None:
        await self.cancel()
        proc = self._login_proc
        task = self._login_task
        if proc is not None and proc.returncode is None:
            proc.kill()
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        if proc is not None and proc.returncode is None:
            try:
                await proc.wait()
            except (ProcessLookupError, OSError):
                pass

    def grok_binary(self) -> Path | None:
        """The newest usable Grok: the bundled one, or a newer one Grok's updater put in Jet's home."""
        candidates = []
        shipped = Path(os.environ.get("JET_GROK_PATH") or self.resource_root / "bin" / "grok")
        if shipped.is_file() and not shipped.is_symlink():
            candidates.append(shipped)
        home = self.grok_home()
        if home is not None:
            updated = self._updated_grok(home)
            if updated is not None:
                candidates.append(updated)
        elif not candidates:
            dev = Path.home() / ".grok" / "bin" / "grok"  # The developer's own CLI; its updater keeps it current.
            if dev.exists():
                candidates.append(dev.resolve())
        best, best_version = None, None
        for path in candidates:
            version = self.grok_version(path)
            if version is not None and version >= GROK_MIN_VERSION and (best_version is None or version > best_version):
                best, best_version = path, version
        return best

    def _updated_grok(self, home: Path) -> Path | None:
        """Grok's updater links bin/grok into downloads/; accept only that, owned by this user."""
        link = home / "bin" / "grok"
        if not link.exists():
            return None
        target = link.resolve()
        downloads = (home / "downloads").resolve()
        try:
            st = target.stat()
        except OSError:
            return None
        if target.parent != downloads or not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) & 0o022:
            return None
        if hasattr(os, "getuid") and st.st_uid != os.getuid():
            return None
        return target

    def grok_version(self, path: Path) -> tuple | None:
        try:
            st = path.stat()
        except OSError:
            return None
        key = (str(path), st.st_mtime_ns, st.st_size)
        if key not in self._grok_versions:
            import subprocess

            env = self._app_env()
            try:
                probe = subprocess.run([str(path), "--version"], capture_output=True, text=True,
                                       timeout=10, env=env, check=False)
                match = _GROK_VERSION_RE.match(probe.stdout.strip()) if probe.returncode == 0 else None
            except (OSError, subprocess.SubprocessError):
                match = None
            self._grok_versions[key] = tuple(int(part) for part in match.groups()) if match else None
        return self._grok_versions[key]

    async def update_grok(self) -> dict:
        """Install the latest Grok into Jet's own Grok home (packaged apps only).

        The bundled binary is read-only inside the signed app, so Grok's updater writes to
        <data>/.runtime/grok-home and grok_binary() then prefers the newer copy. Sessions
        keep --no-auto-update so a running turn is never swapped mid-way.
        """
        if self.grok_home() is None:
            self._grok_update = {"status": "developer_cli"}
            return self._grok_update
        binary = self.grok_binary()
        if binary is None:
            self._grok_update = {"status": "unavailable"}
            return self._grok_update
        self._grok_update = {"status": "checking"}
        try:
            proc = await asyncio.create_subprocess_exec(
                str(binary), "update", stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL, env=self._app_env())
            code = await asyncio.wait_for(proc.wait(), GROK_UPDATE_TIMEOUT_S)
        except (OSError, TimeoutError):
            if "proc" in locals() and proc.returncode is None:
                proc.kill()
                await proc.wait()
            self._grok_update = {"status": "failed"}
            return self._grok_update
        current = self.grok_binary()
        version = self.grok_version(current) if current else None
        self._grok_update = {"status": "current" if code == 0 else "failed",
                             "version": ".".join(map(str, version)) if version else None}
        return self._grok_update

    @staticmethod
    def hash_file(path: Path) -> str:
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            while True:
                block = handle.read(CHUNK)
                if not block:
                    break
                digest.update(block)
        return digest.hexdigest()

    @staticmethod
    def parse_login_output(text: str) -> tuple[str | None, str | None]:
        cleaned = _ANSI_RE.sub("", text)[:LOGIN_CAP]
        url = None
        for match in _URL_RE.finditer(cleaned):
            url = match.group(0).rstrip(").,]>\"'")
        code = None
        for line in cleaned.splitlines():
            if re.search(r"(?i)\bcode\b", line) is None:
                continue
            scrubbed = _URL_RE.sub(" ", line)
            found = _CODE_RE.search(scrubbed)
            if found:
                code = found.group(1)
        return url, code

    def _disk_free(self, path: Path) -> int:
        target = path if path.exists() else path.parent
        return int(shutil.disk_usage(target).free)

    def _app_env(self) -> dict[str, str]:
        env = {key: os.environ[key] for key in _ENV_KEEP if key in os.environ}
        home = self.grok_home()
        if home is not None:
            env["GROK_HOME"] = str(home)
        return env

    def _cached_login(self) -> bool:
        path = (self.grok_home() or Path.home() / ".grok") / "auth.json"
        try:
            st = path.lstat()
        except OSError:
            return False
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            return False
        if hasattr(os, "getuid") and st.st_uid != os.getuid():
            return False
        if stat.S_IMODE(st.st_mode) & 0o077:
            return False
        return True

    def _view_dev(self, mid: str, title: str, description: str) -> dict:
        present = self._dev_present(mid)
        total = self._dir_bytes(self.data_root / "models" / mid) if present else 0
        row = {
            "id": mid,
            "title": title,
            "description": description,
            "bytes": total,
            "status": "installed" if present else "available",
            "received": total if present else 0,
            "total": total,
        }
        if present:
            row["verification"] = "development"
        return row

    def _view_manifest(self, model: dict) -> dict:
        mid = str(model.get("id", ""))
        title = str(model.get("title") or mid)
        description = str(model.get("description") or "")
        try:
            self._validate_model(model)
        except ValueError:
            return {
                "id": mid[:80],
                "title": title[:120],
                "description": description[:240],
                "bytes": 0,
                "status": "failed",
                "received": 0,
                "total": 0,
                "error": "Invalid model manifest",
            }
        total = sum(int(f["size"]) for f in model["files"])
        received = self._bytes_on_disk(model)
        phase = self._phase.get(mid)
        if phase in ("downloading", "verifying", "failed", "cancelled"):
            status_name = phase
        elif self._receipt_ok(model):
            status_name = "installed"
            received = total
        else:
            status_name = "available"
        row = {
            "id": mid,
            "title": title,
            "description": description,
            "bytes": int(model.get("bytes") or total),
            "status": status_name,
            "received": received,
            "total": total,
        }
        if status_name == "installed":
            row["verification"] = "verified"
        if mid in self._errors and status_name == "failed":
            row["error"] = self._errors[mid]
        return row

    def _dev_present(self, mid: str) -> bool:
        if not _ID_RE.fullmatch(mid):
            return False
        directory = self.data_root / "models" / mid
        if not directory.is_dir() or directory.is_symlink():
            return False
        config = directory / "config.json"
        if not config.is_file() or config.is_symlink():
            return False
        return any(
            path.is_file() and not path.is_symlink() and path.suffix == ".safetensors"
            for path in directory.iterdir()
        )

    def _dir_bytes(self, directory: Path) -> int:
        total = 0
        if not directory.is_dir() or directory.is_symlink():
            return 0
        for path in directory.iterdir():
            if path.is_file() and not path.is_symlink():
                total += path.stat().st_size
        return total

    def _validate_model(self, model: dict) -> None:
        mid = model.get("id")
        directory = model.get("directory")
        repo = model.get("repo")
        revision = model.get("revision")
        files = model.get("files")
        if not isinstance(mid, str) or not _ID_RE.fullmatch(mid):
            raise ValueError("Invalid model id")
        if not isinstance(directory, str) or not _ID_RE.fullmatch(directory):
            raise ValueError("Invalid model directory")
        if not isinstance(repo, str) or not _REPO_RE.fullmatch(repo):
            raise ValueError("Invalid model repo")
        if not isinstance(revision, str) or not _REV_RE.fullmatch(revision):
            raise ValueError("Invalid model revision")
        if not isinstance(files, list) or not files:
            raise ValueError("Invalid model files")
        seen: set[str] = set()
        for entry in files:
            if not isinstance(entry, dict):
                raise ValueError("Invalid model file")
            rel = entry.get("path")
            url = entry.get("url")
            size = entry.get("size")
            sha = entry.get("sha256")
            if not isinstance(rel, str) or rel in seen:
                raise ValueError("Invalid model file path")
            seen.add(rel)
            self._validate_relpath(rel)
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                raise ValueError("Invalid model file size")
            if not isinstance(sha, str) or not _SHA_RE.fullmatch(sha.lower()):
                raise ValueError("Invalid model digest")
            expect = f"https://huggingface.co/{repo}/resolve/{revision}/{rel}"
            if url != expect:
                raise ValueError("Unpinned model URL")
        if "bytes" in model and model["bytes"] is not None:
            if int(model["bytes"]) != sum(int(f["size"]) for f in files):
                raise ValueError("Model size mismatch")

    @staticmethod
    def _validate_relpath(rel: str) -> None:
        if not rel or "\x00" in rel or "\\" in rel or rel.startswith(("/", "~")):
            raise ValueError("Invalid model file path")
        parts = rel.split("/")
        if any(part in ("", ".", "..") for part in parts):
            raise ValueError("Invalid model file path")

    def _model_dir(self, directory: str) -> Path:
        if not _ID_RE.fullmatch(directory):
            raise ValueError("Invalid model directory")
        root = self.data_root / "models"
        self._reject_symlink_chain(self.data_root)
        root.mkdir(parents=True, exist_ok=True)
        dest = root / directory
        if dest.is_symlink():
            raise ValueError("Refusing symlink model directory")
        return dest

    def _reject_symlink_chain(self, path: Path) -> None:
        current = Path(path.anchor)
        parts = path.parts[1:] if path.is_absolute() else path.parts
        for part in parts:
            current = current / part
            if current.is_symlink():
                raise ValueError("Refusing symlink in model path")

    def _final_path(self, model: dict, rel: str) -> Path:
        base = self._model_dir(model["directory"])
        self._validate_relpath(rel)
        dest = base.joinpath(*rel.split("/"))
        if dest.is_symlink():
            raise ValueError("Refusing symlink model file")
        parent = dest.parent
        parent.mkdir(parents=True, exist_ok=True)
        walk = base
        if walk.is_symlink():
            raise ValueError("Refusing symlink model path")
        for part in dest.relative_to(base).parts[:-1]:
            walk = walk / part
            if walk.is_symlink():
                raise ValueError("Refusing symlink model path")
        return dest

    def _bytes_on_disk(self, model: dict) -> int:
        total = 0
        try:
            base_ok = True
            self._model_dir(model["directory"])
        except (OSError, ValueError):
            base_ok = False
        if not base_ok:
            return 0
        for entry in model["files"]:
            try:
                dest = self._final_path(model, entry["path"])
            except (OSError, ValueError):
                continue
            part = dest.with_name(dest.name + ".part")
            size = int(entry["size"])
            if dest.is_file() and not dest.is_symlink():
                total += min(dest.stat().st_size, size)
            elif part.is_file() and not part.is_symlink():
                total += min(part.stat().st_size, size)
        return total

    def _remaining(self, model: dict) -> int:
        remain = 0
        for entry in model["files"]:
            size = int(entry["size"])
            have = 0
            try:
                dest = self._final_path(model, entry["path"])
            except (OSError, ValueError):
                remain += size
                continue
            part = dest.with_name(dest.name + ".part")
            if dest.is_file() and not dest.is_symlink():
                have = min(dest.stat().st_size, size)
            elif part.is_file() and not part.is_symlink():
                have = min(part.stat().st_size, size)
            remain += max(0, size - have)
        return remain

    def _receipt_ok(self, model: dict) -> bool:
        try:
            directory = self._model_dir(model["directory"])
            path = directory / ".jet-install.json"
            if not path.is_file() or path.is_symlink():
                return False
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            return False
        if data.get("id") != model["id"] or data.get("revision") != model["revision"]:
            return False
        rows = data.get("files")
        if not isinstance(rows, list):
            return False
        got = {}
        for row in rows:
            if isinstance(row, dict) and isinstance(row.get("path"), str):
                got[row["path"]] = row
        if set(got) != {f["path"] for f in model["files"]}:
            return False
        for entry in model["files"]:
            row = got[entry["path"]]
            if str(row.get("sha256", "")).lower() != entry["sha256"].lower():
                return False
            if int(row.get("size", -1)) != int(entry["size"]):
                return False
            try:
                dest = self._final_path(model, entry["path"])
                if dest.is_symlink() or dest.stat().st_size != int(entry["size"]):
                    return False
            except (OSError, ValueError):
                return False
        return True

    def _write_receipt(self, model: dict) -> None:
        directory = self._model_dir(model["directory"])
        body = {
            "id": model["id"],
            "revision": model["revision"],
            "files": [
                {
                    "path": entry["path"],
                    "size": int(entry["size"]),
                    "sha256": entry["sha256"].lower(),
                }
                for entry in model["files"]
            ],
        }
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        dest = directory / ".jet-install.json"
        tmp = directory / ".jet-install.json.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, payload)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
        os.chmod(dest, 0o600)

    async def _worker(self, model: dict) -> None:
        mid = model["id"]
        try:
            for entry in model["files"]:
                if self._cancel_requested:
                    raise asyncio.CancelledError()
                dest = self._final_path(model, entry["path"])
                part = dest.with_name(dest.name + ".part")
                expected = int(entry["size"])
                if not (dest.is_file() and not dest.is_symlink() and dest.stat().st_size == expected):
                    self._phase[mid] = "downloading"
                    await self._download_file(entry["url"], part, expected)
                    if self._cancel_requested:
                        raise asyncio.CancelledError()
                    self._phase[mid] = "verifying"
                    digest = await asyncio.to_thread(self.hash_file, part)
                    if digest.lower() != entry["sha256"].lower():
                        part.unlink(missing_ok=True)
                        raise RuntimeError("File verification failed")
                    os.chmod(part, 0o644)
                    os.replace(part, dest)
                else:
                    self._phase[mid] = "verifying"
                    digest = await asyncio.to_thread(self.hash_file, dest)
                    if digest.lower() != entry["sha256"].lower():
                        raise RuntimeError("File verification failed")
            if self._cancel_requested:
                raise asyncio.CancelledError()
            self._write_receipt(model)
            self._phase.pop(mid, None)
            self._errors.pop(mid, None)
        except asyncio.CancelledError:
            self._phase[mid] = "cancelled"
            raise
        except Exception as exc:
            self._phase[mid] = "failed"
            self._errors[mid] = _public_error(exc)

    async def _download_file(self, url: str, destination: Path, expected_size: int) -> None:
        import aiohttp

        if not redirect_host_allowed(url) or urlparse(url).hostname != "huggingface.co":
            raise RuntimeError("Refusing download URL")
        destination.parent.mkdir(parents=True, exist_ok=True)
        timeout = aiohttp.ClientTimeout(total=None, connect=30, sock_read=60)
        async with aiohttp.ClientSession(timeout=timeout, trust_env=True) as session:
            offset = 0
            if destination.is_file() and not destination.is_symlink():
                offset = destination.stat().st_size
                if offset > expected_size:
                    destination.unlink()
                    offset = 0
                elif offset == expected_size:
                    return
            headers = {"User-Agent": "jet-browser-setup"}
            if offset:
                headers["Range"] = f"bytes={offset}-"
            response, restart = await self._open_pinned(session, url, headers)
            try:
                if restart or response.status == 200:
                    offset = 0
                elif offset and response.status == 206:
                    match = _RANGE_RE.fullmatch(response.headers.get("Content-Range", "").strip())
                    if match is None or int(match.group(1)) != offset:
                        raise RuntimeError("Resume rejected")
                    total = match.group(3)
                    if total != "*" and int(total) != expected_size:
                        raise RuntimeError("Unexpected file size")
                else:
                    raise RuntimeError(f"Download failed ({response.status})")
                fd = os.open(destination, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                try:
                    os.fchmod(fd, 0o600)
                    if offset == 0:
                        os.ftruncate(fd, 0)
                    else:
                        os.lseek(fd, offset, os.SEEK_SET)
                    written = offset
                    async for chunk in response.content.iter_chunked(CHUNK):
                        if self._cancel_requested:
                            raise asyncio.CancelledError()
                        if written + len(chunk) > expected_size:
                            raise RuntimeError("Download exceeded expected size")
                        os.write(fd, chunk)
                        written += len(chunk)
                    if written != expected_size:
                        raise RuntimeError("Download incomplete")
                except Exception:
                    if not self._cancel_requested and destination.exists():
                        # Keep a partial only when the transfer can resume.
                        if isinstance(asyncio.CancelledError, type):
                            pass
                    raise
                finally:
                    os.close(fd)
                if self._cancel_requested:
                    raise asyncio.CancelledError()
                os.chmod(destination, 0o600)
            finally:
                response.release()
            if destination.is_file() and destination.stat().st_size > expected_size:
                destination.unlink(missing_ok=True)
                raise RuntimeError("Download exceeded expected size")

    async def _open_pinned(self, session, url: str, headers: dict):
        current = url
        redirects = 0
        while True:
            response = await session.get(current, headers=headers, allow_redirects=False)
            if response.status not in (301, 302, 303, 307, 308):
                return response, False
            location = response.headers.get("Location")
            response.release()
            redirects += 1
            if redirects > MAX_REDIRECTS or not location:
                raise RuntimeError("Too many redirects")
            current = urljoin(current, location)
            if not redirect_host_allowed(current):
                raise RuntimeError("Redirect refused")
            # Preserve the Range header through an allowlisted CDN redirect.

    async def _read_login(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stdout is not None
        buf = bytearray()
        try:
            while len(buf) < LOGIN_CAP:
                chunk = await self._read_login_chunk(proc, 512)
                if chunk is None:
                    return
                if not chunk:
                    break
                buf.extend(chunk[: LOGIN_CAP - len(buf)])
                url, code = self.parse_login_output(buf.decode("utf-8", "replace"))
                if url:
                    self._verification_url = url
                if code:
                    self._user_code = code
            while True:
                chunk = await self._read_login_chunk(proc, 4096)
                if chunk is None:
                    return
                if not chunk:
                    break
            rc = await proc.wait()
        except asyncio.CancelledError:
            if proc.returncode is None:
                proc.kill()
            raise
        if self._login_status == "expired":
            return
        if rc == 0:
            self._login_status = "authenticated"
            self._login_error = None
        else:
            self._login_status = "error"
            self._login_error = "Sign-in failed"

    async def _read_login_chunk(self, proc, size: int):
        assert proc.stdout is not None
        remaining = self._login_deadline - time.monotonic()
        if remaining <= 0:
            proc.kill()
            self._login_status = "expired"
            self._login_error = "Sign-in expired"
            return None
        try:
            return await asyncio.wait_for(proc.stdout.read(size), timeout=remaining)
        except asyncio.TimeoutError:
            proc.kill()
            self._login_status = "expired"
            self._login_error = "Sign-in expired"
            return None


def _public_error(exc: BaseException) -> str:
    text = str(exc).strip() or exc.__class__.__name__
    text = re.sub(r"https?://\S+", "download", text)
    return text[:180]
