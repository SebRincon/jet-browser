"""Per-conversation agent documents. Paths and preview capabilities stay server-side."""

from __future__ import annotations

import os
import re
import sqlite3
import stat
import threading
import time
import uuid
from contextlib import contextmanager
from html import escape
from html.parser import HTMLParser
from pathlib import Path

MAX_FILE_BYTES = 200_000
MAX_FILES = 500
MAX_SESSION_BYTES = 50 * 1024 * 1024
MAX_READ = 20_000
PREVIEW_TTL = 600
MAX_PREVIEW_CAPS = 128
_AREAS = {"scratch", "artifacts"}
_MEDIA = {
    ".md": "text/markdown",
    ".txt": "text/plain",
    ".json": "application/json",
    ".csv": "text/csv",
    ".html": "text/html",
}
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}")
_HEX = re.compile(r"[0-9a-f]{32}")
_TOKEN = re.compile(r"[A-Za-z0-9_-]{43}")
_CSP = (
    "sandbox; default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; "
    "img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
)
_PREVIEW_HEADERS = {
    "Content-Security-Policy": _CSP,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
}
_DROP_TAGS = {
    "script",
    "iframe",
    "object",
    "embed",
    "link",
    "meta",
    "base",
    "form",
    "svg",
    "math",
    "video",
    "audio",
    "source",
    "frame",
    "frameset",
    "noscript",
}
_ALLOW_TAGS = {
    "p",
    "br",
    "hr",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "ul",
    "ol",
    "li",
    "pre",
    "code",
    "blockquote",
    "strong",
    "em",
    "b",
    "i",
    "a",
    "table",
    "thead",
    "tbody",
    "tr",
    "th",
    "td",
    "div",
    "span",
    "img",
    "style",
}
_VOID_TAGS = {"br", "hr", "img"}


def _session_id(value):
    if not isinstance(value, str) or _HEX.fullmatch(value) is None:
        raise ValueError("Unknown conversation")
    return value


def _file_id(value):
    if not isinstance(value, str) or _HEX.fullmatch(value) is None:
        raise ValueError("Unknown workspace file")
    return value


def _validate_name(name):
    if not isinstance(name, str) or len(name) > 100 or not name.isascii():
        raise ValueError("Use an ASCII document name of at most 100 characters")
    if name.startswith(".") or ".." in name or "/" in name or "\\" in name or "\x00" in name:
        raise ValueError("Use an ASCII document name of at most 100 characters")
    if _NAME.fullmatch(name) is None:
        raise ValueError("Use an ASCII document name of at most 100 characters")
    suffix = Path(name).suffix.lower()
    if suffix not in _MEDIA or not name.endswith(suffix):
        raise ValueError("Use a .md, .txt, .json, .csv, or .html file")
    return name, _MEDIA[suffix]


def _bounds(offset, limit):
    if isinstance(offset, bool) or isinstance(limit, bool):
        raise ValueError("Offset and limit must be integers")
    if not isinstance(offset, int):
        try:
            offset = int(offset)
        except (TypeError, ValueError):
            raise ValueError("Offset and limit must be integers") from None
    if not isinstance(limit, int):
        try:
            limit = int(limit)
        except (TypeError, ValueError):
            raise ValueError("Offset and limit must be integers") from None
    if offset < 0 or limit < 1 or offset > MAX_FILE_BYTES:
        raise ValueError("Offset and limit must be in range")
    return offset, min(limit, MAX_READ)


def _reject_symlinks(path):
    path = Path(path)
    if not path.is_absolute():
        path = Path.cwd() / path
    cursor = Path(path.anchor)
    for part in path.parts[1:]:
        cursor = cursor / part
        try:
            info = cursor.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("Workspace path is unavailable")


def _chmod_dir(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise ValueError("Workspace path is unavailable")
    os.chmod(path, 0o700)


@contextmanager
def _private_umask():
    previous = os.umask(0o077)
    try:
        yield
    finally:
        os.umask(previous)


class _Sanitizer(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.skip = 0
        self.stack = []

    def handle_starttag(self, tag, attrs):
        self._start(tag, attrs, False)

    def handle_startendtag(self, tag, attrs):
        self._start(tag, attrs, True)

    def _start(self, tag, attrs, closed):
        tag = tag.lower()
        if tag in _DROP_TAGS:
            if not closed and tag not in {"meta", "link", "base", "embed", "source", "frame"}:
                self.skip += 1
            return
        if self.skip or tag not in _ALLOW_TAGS:
            return
        safe = []
        for key, value in attrs:
            if value is None:
                continue
            lowered = key.lower()
            if lowered.startswith("on") or lowered in {"srcdoc", "srcset", "formaction"}:
                continue
            text = value.strip()
            probe = text.lower().replace("\x00", "").replace(" ", "").replace("\t", "")
            if probe.startswith(("javascript:", "vbscript:", "data:text/html")):
                continue
            if lowered in {"href", "src"}:
                if (
                    tag == "img"
                    and lowered == "src"
                    and text.lower().startswith("data:image/")
                    and "svg" not in text.lower().split(",", 1)[0]
                ):
                    safe.append((lowered, text))
                elif (
                    tag == "a"
                    and lowered == "href"
                    and text.lower().startswith(("#", "http://", "https://", "mailto:"))
                ):
                    safe.append((lowered, text))
                continue
            if lowered == "id" and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,79}", text):
                safe.append((lowered, text))
            elif lowered in {"alt", "title", "colspan", "rowspan", "class"}:
                safe.append((lowered, text))
            elif lowered == "style" and "url(" not in text.lower() and "@import" not in text.lower():
                safe.append((lowered, text))
        rendered = "".join(f' {escape(key, quote=True)}="{escape(val, quote=True)}"' for key, val in safe)
        self.out.append(f"<{tag}{rendered}>")
        if tag not in _VOID_TAGS and not closed:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in _DROP_TAGS:
            if self.skip:
                self.skip -= 1
            return
        if self.skip or tag not in _ALLOW_TAGS or tag in _VOID_TAGS:
            return
        if tag in self.stack:
            while self.stack:
                current = self.stack.pop()
                self.out.append(f"</{current}>")
                if current == tag:
                    break

    def handle_data(self, data):
        if self.skip:
            return
        if self.stack and self.stack[-1] == "style":
            cleaned = re.sub(r"url\s*\([^)]*\)", "", data, flags=re.I)
            cleaned = re.sub(r"@import[^;]*;?", "", cleaned, flags=re.I)
            cleaned = cleaned.replace("</", "<\\/")
            self.out.append(cleaned)
            return
        self.out.append(escape(data))

    def handle_comment(self, data):
        return

    def handle_decl(self, decl):
        return

    def handle_pi(self, data):
        return


def _sanitize_html(content):
    parser = _Sanitizer()
    try:
        parser.feed(content)
        parser.close()
    except Exception:
        return f"<pre>{escape(content)}</pre>"
    while parser.stack:
        parser.out.append(f"</{parser.stack.pop()}>")
    return "".join(parser.out)


def _document(body, title):
    safe_title = escape(title)
    return (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        f"<title>{safe_title}</title>"
        f'<meta http-equiv="Content-Security-Policy" content="{escape(_CSP, quote=True)}">'
        "<style>body{margin:0;background:#111;color:#eee;font:16px/1.45 ui-sans-serif,system-ui,sans-serif}"
        "main{padding:24px}h1{font-size:1.1rem;font-weight:650;margin:0 0 16px}"
        "pre{white-space:pre-wrap;word-break:break-word;margin:0}</style></head>"
        f"<body><main>{body}</main></body></html>"
    )


class WorkspaceStore:
    def __init__(self, root):
        self.root = Path(root)
        with _private_umask():
            _reject_symlinks(self.root)
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            _reject_symlinks(self.root)
            _chmod_dir(self.root)
            workspaces = self.root / "workspaces"
            _reject_symlinks(workspaces)
            workspaces.mkdir(exist_ok=True, mode=0o700)
            _chmod_dir(workspaces)
            self._db_path = self.root / "index.sqlite3"
            _reject_symlinks(self._db_path)
            flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
            descriptor = os.open(self._db_path, flags, 0o600)
            try:
                info = os.fstat(descriptor)
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError("Workspace path is unavailable")
            finally:
                os.close(descriptor)
            os.chmod(self._db_path, 0o600)
            self._db = sqlite3.connect(self._db_path, check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._db.execute(
                "CREATE TABLE IF NOT EXISTS files ("
                "id TEXT PRIMARY KEY, session_id TEXT NOT NULL, name TEXT NOT NULL, "
                "area TEXT NOT NULL, size INTEGER NOT NULL, created_at REAL NOT NULL, "
                "media_type TEXT NOT NULL)"
            )
            self._db.execute("CREATE INDEX IF NOT EXISTS files_session ON files(session_id, created_at DESC, id DESC)")
            self._db.execute(
                "CREATE TABLE IF NOT EXISTS previews ("
                "token TEXT PRIMARY KEY, session_id TEXT NOT NULL, file_id TEXT NOT NULL, "
                "expires_at REAL NOT NULL)"
            )
        os.chmod(self._db_path, 0o600)

    def close(self):
        with self._lock:
            self._db.close()

    def list(self, session_id):
        session_id = _session_id(session_id)
        with self._lock:
            rows = self._db.execute(
                "SELECT id, name, area, size, created_at, media_type FROM files "
                "WHERE session_id=? ORDER BY created_at DESC, id DESC LIMIT 100",
                (session_id,),
            ).fetchall()
        return [self._metadata(row) for row in rows]

    def write(self, session_id, *, name, content, area="artifacts"):
        session_id = _session_id(session_id)
        name, media_type = _validate_name(name)
        if not isinstance(area, str) or area not in _AREAS:
            raise ValueError("Choose scratch or artifacts")
        if not isinstance(content, str):
            raise ValueError("File content must be text")
        try:
            payload = content.encode("utf-8")
        except UnicodeError:
            raise ValueError("File content must be text") from None
        if len(payload) > MAX_FILE_BYTES:
            raise ValueError("File exceeds 200000 bytes")
        file_id = uuid.uuid4().hex
        created_at = time.time()
        directory = self.root / "workspaces" / session_id / area
        target = directory / f"{file_id}-{name}"
        written = False
        with self._lock, _private_umask():
            self._ensure_dir(self.root / "workspaces")
            self._ensure_dir(self.root / "workspaces" / session_id)
            self._ensure_dir(directory)
            if target.parent != directory:
                raise ValueError("Use an ASCII document name of at most 100 characters")
            self._db.execute("BEGIN IMMEDIATE")
            try:
                count, total = self._db.execute(
                    "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files WHERE session_id=?",
                    (session_id,),
                ).fetchone()
                if count >= MAX_FILES or total + len(payload) > MAX_SESSION_BYTES:
                    raise ValueError("This conversation workspace is full")
                self._create_file(target, payload)
                written = True
                self._db.execute(
                    "INSERT INTO files (id, session_id, name, area, size, created_at, media_type) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (file_id, session_id, name, area, len(payload), created_at, media_type),
                )
                self._db.execute("COMMIT")
            except Exception:
                self._db.execute("ROLLBACK")
                if written:
                    self._unlink(target)
                raise
        return {
            "id": file_id,
            "name": name,
            "area": area,
            "size": len(payload),
            "created_at": created_at,
            "media_type": media_type,
        }

    def read(self, session_id, file_id, *, offset=0, limit=MAX_READ):
        session_id = _session_id(session_id)
        file_id = _file_id(file_id)
        offset, limit = _bounds(offset, limit)
        with self._lock:
            row = self._db.execute(
                "SELECT id, name, area, size, created_at, media_type FROM files WHERE session_id=? AND id=?",
                (session_id, file_id),
            ).fetchone()
            if row is None:
                raise ValueError("Unknown workspace file")
            metadata = self._metadata(row)
            path = self._path(session_id, metadata["area"], file_id, metadata["name"])
            try:
                payload = self._read_file(path, 0, MAX_FILE_BYTES + 1)
                if len(payload) != metadata["size"] or len(payload) > MAX_FILE_BYTES:
                    raise ValueError("Workspace file changed outside the agent")
                text = payload.decode("utf-8")
            except (OSError, UnicodeError):
                raise ValueError("Workspace file is unavailable") from None
        # Offsets count Unicode characters; a page never splits a UTF-8 sequence.
        chunk = text[offset : offset + limit]
        consumed = offset + len(chunk)
        next_offset = None if consumed >= len(text) else consumed
        return {"file": metadata, "content": chunk, "next_offset": next_offset}

    def issue_preview(self, session_id, file_id):
        session_id = _session_id(session_id)
        file_id = _file_id(file_id)
        now = time.time()
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                row = self._db.execute(
                    "SELECT id FROM files WHERE session_id=? AND id=?",
                    (session_id, file_id),
                ).fetchone()
                if row is None:
                    raise ValueError("Unknown workspace file")
                self._db.execute("DELETE FROM previews WHERE expires_at<=?", (now,))
                while self._db.execute("SELECT COUNT(*) FROM previews").fetchone()[0] >= MAX_PREVIEW_CAPS:
                    oldest = self._db.execute("SELECT token FROM previews ORDER BY expires_at ASC LIMIT 1").fetchone()
                    if oldest is None:
                        break
                    self._db.execute("DELETE FROM previews WHERE token=?", (oldest["token"],))
                token = None
                for _ in range(5):
                    candidate = __import__("secrets").token_urlsafe(32)
                    if _TOKEN.fullmatch(candidate) is None:
                        continue
                    if self._db.execute("SELECT 1 FROM previews WHERE token=?", (candidate,)).fetchone():
                        continue
                    token = candidate
                    break
                if token is None:
                    raise ValueError("Preview is unavailable")
                self._db.execute(
                    "INSERT INTO previews (token, session_id, file_id, expires_at) VALUES (?, ?, ?, ?)",
                    (token, session_id, file_id, now + PREVIEW_TTL),
                )
                self._db.execute("COMMIT")
            except Exception:
                self._db.execute("ROLLBACK")
                raise
        return f"/artifacts/view/{token}"

    def preview(self, token):
        if not isinstance(token, str) or _TOKEN.fullmatch(token) is None:
            raise LookupError("missing")
        now = time.time()
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._db.execute("DELETE FROM previews WHERE expires_at<=?", (now,))
                row = self._db.execute(
                    "SELECT session_id, file_id, expires_at FROM previews WHERE token=?",
                    (token,),
                ).fetchone()
                if row is None or row["expires_at"] <= now:
                    self._db.execute("DELETE FROM previews WHERE token=?", (token,))
                    self._db.execute("COMMIT")
                    raise LookupError("missing")
                record = self._db.execute(
                    "SELECT id, name, area, size, created_at, media_type FROM files WHERE session_id=? AND id=?",
                    (row["session_id"], row["file_id"]),
                ).fetchone()
                self._db.execute("COMMIT")
            except LookupError:
                raise
            except Exception:
                self._db.execute("ROLLBACK")
                raise LookupError("missing") from None
            if record is None:
                raise LookupError("missing")
            metadata = self._metadata(record)
            path = self._path(row["session_id"], metadata["area"], metadata["id"], metadata["name"])
            try:
                payload = self._read_file(path, 0, MAX_FILE_BYTES)
            except OSError:
                raise LookupError("missing") from None
        try:
            text = payload.decode("utf-8")
        except UnicodeError:
            raise LookupError("missing") from None
        if metadata["media_type"] == "text/html":
            body = _sanitize_html(text)
            html = _document(body, "Preview")
        else:
            body = f"<h1>{escape(metadata['name'])}</h1><pre>{escape(text)}</pre>"
            html = _document(body, metadata["name"])
        return html, dict(_PREVIEW_HEADERS)

    def _metadata(self, row):
        return {
            "id": row["id"],
            "name": row["name"],
            "area": row["area"],
            "size": row["size"],
            "created_at": row["created_at"],
            "media_type": row["media_type"],
        }

    def _path(self, session_id, area, file_id, name):
        if area not in _AREAS:
            raise ValueError("Workspace file is unavailable")
        directory = self.root / "workspaces" / session_id / area
        path = directory / f"{file_id}-{name}"
        if path.parent != directory:
            raise ValueError("Workspace file is unavailable")
        return path

    def _ensure_dir(self, path):
        _reject_symlinks(path)
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        _reject_symlinks(path)
        _chmod_dir(path)

    def _create_file(self, path, payload):
        _reject_symlinks(path)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        try:
            descriptor = os.open(path, flags, 0o600)
        except OSError:
            raise ValueError("Workspace file is unavailable") from None
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("Workspace file is unavailable")
            remaining = payload
            while remaining:
                written = os.write(descriptor, remaining)
                if written <= 0:
                    raise ValueError("Workspace file is unavailable")
                remaining = remaining[written:]
            os.fsync(descriptor)
        except Exception:
            os.close(descriptor)
            self._unlink(path)
            raise
        os.close(descriptor)
        os.chmod(path, 0o600)

    def _read_file(self, path, offset, limit):
        _reject_symlinks(path)
        flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(path, flags)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise OSError("not a regular file")
            os.lseek(descriptor, offset, os.SEEK_SET)
            chunks = []
            remaining = limit
            while remaining:
                piece = os.read(descriptor, remaining)
                if not piece:
                    break
                chunks.append(piece)
                remaining -= len(piece)
            return b"".join(chunks)
        finally:
            os.close(descriptor)

    def _unlink(self, path):
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            return
        try:
            path.unlink()
        except FileNotFoundError:
            return


NAMES = {"workspace_list", "workspace_read", "workspace_write"}


def _schema(properties, required=()):
    return {"type": "object", "properties": properties, "required": list(required), "additionalProperties": False}


TOOLS = [
    {
        "name": "workspace_list",
        "description": "List document metadata for this conversation's scratch notes and artifacts. Does not return file contents.",
        "inputSchema": _schema({}),
    },
    {
        "name": "workspace_read",
        "description": "Read one existing conversation document by id when the user asked to use that document. Content is explicit document text, not a filesystem or shell.",
        "inputSchema": _schema(
            {
                "file_id": {"type": "string", "minLength": 32, "maxLength": 32, "pattern": "^[0-9a-f]{32}$"},
                "offset": {"type": "integer", "minimum": 0, "maximum": 200000},
                "limit": {"type": "integer", "minimum": 1, "maximum": 20000},
            },
            ["file_id"],
        ),
    },
    {
        "name": "workspace_write",
        "description": "Save a new scratch note or artifact for this conversation. Creates a new document and does not overwrite. Not a shell or filesystem tool.",
        "inputSchema": _schema(
            {
                "name": {"type": "string", "minLength": 1, "maxLength": 100},
                "content": {"type": "string"},
                "area": {"type": "string", "enum": ["artifacts", "scratch"]},
            },
            ["name", "content"],
        ),
    },
]


async def tool(service, name, args):
    if name not in NAMES:
        raise ValueError("Unknown workspace tool")
    if not isinstance(args, dict):
        raise ValueError("Tool arguments must be an object")
    allowed = {
        "workspace_list": set(),
        "workspace_read": {"file_id", "offset", "limit"},
        "workspace_write": {"name", "content", "area"},
    }
    required = {"workspace_list": set(), "workspace_read": {"file_id"}, "workspace_write": {"name", "content"}}
    if set(args) - allowed[name] or not required[name] <= set(args):
        raise ValueError("Unexpected workspace arguments")
    for key in ("offset", "limit"):
        if key in args and type(args[key]) is not int:
            raise ValueError("Offset and limit must be integers")
    session_id = service.store.current_id
    if name == "workspace_list":
        return {"files": service.workspace.list(session_id)}
    if name == "workspace_read":
        return service.workspace.read(
            session_id,
            args.get("file_id"),
            offset=args.get("offset", 0),
            limit=args.get("limit", MAX_READ),
        )
    if name == "workspace_write":
        saved = service.workspace.write(
            session_id,
            name=args.get("name"),
            content=args.get("content"),
            area=args.get("area", "artifacts"),
        )
        service.trace.emit("workspace.written", file_id=saved["id"], count=1, size_bytes=saved["size"])
        return saved
    raise ValueError("Unknown workspace tool")


def register_routes(app, service):
    from aiohttp import web

    async def workspace_index(_request):
        return web.json_response(
            {
                "files": service.workspace.list(service.store.current_id),
                "location": "~/.jet-browser/workspaces",
            }
        )

    async def workspace_read(request):
        payload = service.workspace.read(
            service.store.current_id,
            request.match_info["id"],
            offset=request.query.get("offset", "0"),
            limit=request.query.get("limit", "20000"),
        )
        return web.json_response(payload)

    async def workspace_preview(request):
        url = service.workspace.issue_preview(service.store.current_id, request.match_info["id"])
        return web.json_response({"url": url})

    async def public_preview(request):
        try:
            content, headers = service.workspace.preview(request.match_info["token"])
        except (LookupError, ValueError):
            raise web.HTTPNotFound()
        response = web.Response(text=content, content_type="text/html", charset="utf-8")
        for key, value in headers.items():
            response.headers[key] = value
        return response

    app.router.add_get("/workspace", workspace_index)
    app.router.add_get("/workspace/{id}", workspace_read)
    app.router.add_post("/workspace/{id}/preview", workspace_preview)
    app.router.add_get("/artifacts/view/{token}", public_preview)
