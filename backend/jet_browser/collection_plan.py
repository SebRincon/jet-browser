from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass
from urllib.parse import unquote, urlsplit, urlunsplit

_ID = re.compile(r"[a-z][a-z0-9_]{0,31}\Z")
_LABEL = re.compile(r"[a-z0-9-]+\Z")
_MODELS = frozenset({"lfm_rlcd", "qwen4b_semif_shared", "laya_mlx", "laya_typed"})
_REVISION = "collection-choice-v1"
_REQ_KEYS = frozenset(
    {
        "request",
        "title",
        "categories",
        "section_path",
        "max_pages",
        "max_seconds",
        "source_kind",
        "max_items",
        "max_scrolls",
    }
)
_PLAN_KEYS = frozenset(
    {
        "schema_version",
        "taxonomy_version",
        "classifier_revision",
        "request",
        "title",
        "start_url",
        "tab_id",
        "model",
        "origin",
        "section_path",
        "categories",
        "max_pages",
        "max_seconds",
    }
)
_SOURCE_KINDS = frozenset({"website", "feed", "x_bookmarks"})
_PLAN_V2_KEYS = _PLAN_KEYS | {"source_kind", "max_items", "max_scrolls"}
_STATUS_PATH = re.compile(r"/[^/]+/status/[0-9]+\Z")


def _bad_chars(value: str) -> bool:
    return any(ord(ch) < 32 or ch == "\x7f" or ch.isspace() or ch == "\\" for ch in value)


def _text(value: object, lo: int, hi: int, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or not lo <= len(value) <= hi:
        raise ValueError(label)
    return value


def _pint(value: object, lo: int, hi: int, label: str) -> int:
    if type(value) is not int or not lo <= value <= hi:
        raise ValueError(label)
    return value


def _decoded(segment: str) -> str:
    current = segment
    for _ in range(3):
        nxt = unquote(current)
        if nxt == current:
            break
        current = nxt
    return current


def _dot_segments(path: str) -> bool:
    for segment in path.split("/"):
        if segment == "":
            continue
        decoded = _decoded(segment)
        if segment in {".", ".."} or decoded in {".", ".."} or "/" in decoded or "\\" in decoded:
            return True
    return False


def _normalize_host(host: str) -> str:
    if ":" in host:
        try:
            return f"[{ipaddress.IPv6Address(host).compressed}]"
        except ValueError as exc:
            raise ValueError("url") from exc
    try:
        ip4 = ipaddress.IPv4Address(host)
    except ValueError:
        ip4 = None
    if ip4 is not None:
        if str(ip4) != host:
            raise ValueError("url")
        return host
    if not host or len(host) > 253 or host.startswith(".") or host.endswith(".") or ".." in host:
        raise ValueError("url")
    for label in host.split("."):
        if not 1 <= len(label) <= 63 or label.startswith("-") or label.endswith("-"):
            raise ValueError("url")
        if _LABEL.fullmatch(label) is None:
            raise ValueError("url")
    return host


def canonical_url(value: object) -> str:
    if not isinstance(value, str) or value == "" or len(value) > 6000 or _bad_chars(value):
        raise ValueError("url")
    parts = urlsplit(value)
    if parts.netloc.endswith(":"):
        raise ValueError("url")
    scheme = parts.scheme.lower()
    if scheme not in {"http", "https"} or parts.username is not None or parts.password is not None:
        raise ValueError("url")
    if "@" in parts.netloc or not parts.hostname:
        raise ValueError("url")
    try:
        port = parts.port
    except ValueError as exc:
        raise ValueError("url") from exc
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("url")
    if (scheme == "http" and port == 80) or (scheme == "https" and port == 443):
        port = None
    host = _normalize_host(parts.hostname)
    if _dot_segments(parts.path):
        raise ValueError("url")
    netloc = host if port is None else f"{host}:{port}"
    return urlunsplit((scheme, netloc, parts.path or "/", parts.query, ""))


def origin_of(url: object) -> str:
    parts = urlsplit(canonical_url(url))
    return f"{parts.scheme}://{parts.netloc}"


def section_path(value: object) -> str:
    if not isinstance(value, str) or not value.startswith("/") or _bad_chars(value):
        raise ValueError("section_path")
    if any(ch in value for ch in "?#"):
        raise ValueError("section_path")
    if _dot_segments(value):
        raise ValueError("section_path")
    if value == "/":
        return "/"
    if "//" in value:
        raise ValueError("section_path")
    trimmed = value.rstrip("/")
    if not trimmed.startswith("/") or trimmed == "" or _dot_segments(trimmed):
        raise ValueError("section_path")
    return trimmed


def in_scope(url: object, origin: object, section: object) -> bool:
    if not isinstance(origin, str):
        raise ValueError("origin")
    root = section_path(section)
    try:
        normal = canonical_url(url)
    except ValueError:
        return False
    if origin_of(normal) != origin:
        return False
    path = urlsplit(normal).path or "/"
    return root == "/" or path == root or path.startswith(root + "/")


def _x_library_url(url: str) -> bool:
    parts = urlsplit(url)
    host = parts.hostname or ""
    labels = host.split(".")
    base = host if len(labels) < 2 else ".".join(labels[-2:])
    if base not in {"x.com", "twitter.com"}:
        return False
    path = parts.path or "/"
    return any(path == stem or path.startswith(stem + "/") for stem in ("/i/history", "/i/bookmarks"))


@dataclass(frozen=True, slots=True)
class Category:
    id: str
    name: str
    description: str

    @classmethod
    def from_dict(cls, obj: object) -> Category:
        if not isinstance(obj, dict) or set(obj) != {"id", "name", "description"}:
            raise ValueError("category")
        ident = obj["id"]
        if not isinstance(ident, str) or _ID.fullmatch(ident) is None or ident == "needs_review":
            raise ValueError("category.id")
        return cls(
            ident, _text(obj["name"], 1, 80, "category.name"), _text(obj["description"], 1, 400, "category.description")
        )

    def to_dict(self) -> dict[str, str]:
        return {"id": self.id, "name": self.name, "description": self.description}


def _categories(value: object) -> tuple[Category, ...]:
    if not isinstance(value, list) or not 1 <= len(value) <= 8:
        raise ValueError("categories")
    items = tuple(Category.from_dict(item) for item in value)
    if len({item.id for item in items}) != len(items):
        raise ValueError("categories")
    return items


def _model(value: object) -> str:
    if not isinstance(value, str) or value not in _MODELS:
        raise ValueError("model")
    return value


def _tab(value: object) -> str:
    return _text(value, 1, 200, "tab_id")


@dataclass(frozen=True, slots=True)
class CollectionPlan:
    request: str
    title: str
    start_url: str
    tab_id: str
    model: str
    origin: str
    section_path: str
    categories: tuple[Category, ...]
    max_pages: int
    max_seconds: int
    schema_version: int = 1
    taxonomy_version: int = 1
    classifier_revision: str = _REVISION
    source_kind: str = "website"
    max_items: int = 100
    max_scrolls: int = 30

    @classmethod
    def from_request(cls, args: object, *, start_url: object, tab_id: object, model: object) -> CollectionPlan:
        if (
            not isinstance(args, dict)
            or not set(args) <= _REQ_KEYS
            or not {"request", "title", "categories"} <= set(args)
        ):
            raise ValueError("args")
        source_kind = args.get("source_kind", "website")
        if not isinstance(source_kind, str) or source_kind not in _SOURCE_KINDS:
            raise ValueError("source_kind")
        if source_kind == "website" and ("max_items" in args or "max_scrolls" in args):
            raise ValueError("max_items" if "max_items" in args else "max_scrolls")
        section = section_path(args.get("section_path", "/"))
        url = canonical_url(start_url)
        origin = origin_of(url)
        if not in_scope(url, origin, section):
            raise ValueError("start_url")
        if source_kind == "website" and _x_library_url(url):
            raise ValueError("use inspect_collection_source and x_bookmarks adapter")
        if source_kind == "website":
            max_items = 100
            max_scrolls = 30
            schema_version = 1
            max_seconds = _pint(args.get("max_seconds", 90), 1, 120, "max_seconds")
        else:
            max_items = _pint(args.get("max_items", 5000), 1, 5000, "max_items")
            max_scrolls = _pint(args.get("max_scrolls", 2000), 1, 10000, "max_scrolls")
            schema_version = 2
            max_seconds = _pint(args.get("max_seconds", 1800), 1, 14400, "max_seconds")
        return cls(
            request=_text(args["request"], 1, 6000, "request"),
            title=_text(args["title"], 1, 120, "title"),
            start_url=url,
            tab_id=_tab(tab_id),
            model=_model(model),
            origin=origin,
            section_path=section,
            categories=_categories(args["categories"]),
            max_pages=_pint(args.get("max_pages", 10), 1, 50, "max_pages"),
            max_seconds=max_seconds,
            schema_version=schema_version,
            source_kind=source_kind,
            max_items=max_items,
            max_scrolls=max_scrolls,
        )

    @classmethod
    def from_dict(cls, obj: object) -> CollectionPlan:
        if not isinstance(obj, dict):
            raise ValueError("plan")
        keys = set(obj)
        if keys == _PLAN_KEYS:
            if obj["schema_version"] != 1 or type(obj["schema_version"]) is not int:
                raise ValueError("schema_version")
            source_kind = "website"
            max_items = 100
            max_scrolls = 30
            schema_version = 1
        elif keys == _PLAN_V2_KEYS:
            if obj["schema_version"] != 2 or type(obj["schema_version"]) is not int:
                raise ValueError("schema_version")
            source_kind = obj["source_kind"]
            if not isinstance(source_kind, str) or source_kind not in {"feed", "x_bookmarks"}:
                raise ValueError("source_kind")
            max_items = _pint(obj["max_items"], 1, 5000, "max_items")
            max_scrolls = _pint(obj["max_scrolls"], 1, 10000, "max_scrolls")
            schema_version = 2
        else:
            raise ValueError("plan")
        if type(obj["taxonomy_version"]) is not int or not 1 <= obj["taxonomy_version"] <= 1000:
            raise ValueError("taxonomy_version")
        if obj["classifier_revision"] != _REVISION:
            raise ValueError("classifier_revision")
        url = canonical_url(obj["start_url"])
        if url != obj["start_url"]:
            raise ValueError("start_url")
        section = section_path(obj["section_path"])
        if section != obj["section_path"]:
            raise ValueError("section_path")
        origin = origin_of(url)
        if origin != obj["origin"] or not in_scope(url, origin, section):
            raise ValueError("origin")
        return cls(
            request=_text(obj["request"], 1, 6000, "request"),
            title=_text(obj["title"], 1, 120, "title"),
            start_url=url,
            tab_id=_tab(obj["tab_id"]),
            model=_model(obj["model"]),
            origin=origin,
            section_path=section,
            categories=_categories(obj["categories"]),
            max_pages=_pint(obj["max_pages"], 1, 50, "max_pages"),
            max_seconds=_pint(obj["max_seconds"], 1, 120 if source_kind == "website" else 14400, "max_seconds"),
            schema_version=schema_version,
            taxonomy_version=obj["taxonomy_version"],
            classifier_revision=_REVISION,
            source_kind=source_kind,
            max_items=max_items,
            max_scrolls=max_scrolls,
        )

    def to_dict(self) -> dict[str, object]:
        data: dict[str, object] = {
            "schema_version": 1 if self.source_kind == "website" else 2,
            "taxonomy_version": self.taxonomy_version,
            "classifier_revision": self.classifier_revision,
            "request": self.request,
            "title": self.title,
            "start_url": self.start_url,
            "tab_id": self.tab_id,
            "model": self.model,
            "origin": self.origin,
            "section_path": self.section_path,
            "categories": [item.to_dict() for item in self.categories],
            "max_pages": self.max_pages,
            "max_seconds": self.max_seconds,
        }
        if self.source_kind != "website":
            data["source_kind"] = self.source_kind
            data["max_items"] = self.max_items
            data["max_scrolls"] = self.max_scrolls
        return data

    def in_scope(self, url: object) -> bool:
        if self.source_kind != "website":
            try:
                return canonical_url(url) == self.start_url
            except ValueError:
                return False
        return in_scope(url, self.origin, self.section_path)

    def item_in_scope(self, url: object) -> bool:
        if self.source_kind == "website":
            return self.in_scope(url)
        try:
            normal = canonical_url(url)
        except ValueError:
            return False
        if origin_of(normal) != self.origin:
            return False
        if self.source_kind == "feed":
            return True
        parts = urlsplit(normal)
        if parts.query:
            return False
        return _STATUS_PATH.fullmatch(parts.path or "/") is not None
