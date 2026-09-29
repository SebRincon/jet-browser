"""MCP and HTTP adapters for saved local website collections."""

import csv
import io
import math
import threading
from urllib.parse import quote, urlsplit

from aiohttp import web

from .collection_plan import CollectionPlan
from .feed_collection import FEED_SNAPSHOT, FeedCollector
from .site_collection import CollectionBlocked
from .tasks import LOCAL_MODELS

NAMES = frozenset(
    {
        "prepare_collection",
        "start_collection",
        "collection_status",
        "control_collection",
        "inspect_collection_source",
    }
)

NOTICE = "Only observed linked pages in this scope were considered; source text stays in the local collection."
FEED_NOTICE = (
    "Only observed posts from the current feed position were considered. "
    "Saved post identities survive resume; reloaded pages resume from the current view, "
    "not an assumed archive position. Source text stays local."
)
INSPECT_NOTICE = "Source content stays local."
_EXPORT_CAP = 5000
_EXPORT_PAGE = 100
_FEED_KINDS = {"feed", "x_bookmarks"}
_SNAPSHOT_KINDS = {"x_bookmarks", "feed", "unsupported"}

_MODELS = {item["id"] for item in LOCAL_MODELS}
_PREPARE_FIELDS = {
    "request",
    "title",
    "categories",
    "section_path",
    "max_pages",
    "max_seconds",
    "max_items",
    "max_scrolls",
    "source_kind",
    "model",
    "tab_id",
}
_CONTROL_ACTIONS = {"pause", "resume", "start", "stop"}
_MCP_CONTROL_ACTIONS = {"pause", "resume", "stop"}
_LIST_QUERY = {"query", "category", "offset", "limit"}
_FORMULA_LEAD = "=+-@\t\r"


def _object(args):
    if not isinstance(args, dict):
        raise ValueError("Tool arguments must be an object")


def _exact(args, allowed, required):
    extra = set(args) - set(allowed)
    if extra:
        raise ValueError("Unexpected collection arguments")
    missing = [key for key in required if key not in args]
    if missing:
        raise ValueError("Missing collection argument")


def _text(value, label, limit):
    if not isinstance(value, str):
        raise ValueError(label + " must be a string")
    text = value.strip()
    if not text or len(text) > limit:
        raise ValueError(label + " length is invalid")
    return text


def _identifier(value, label, limit):
    text = _text(value, label, limit)
    if any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for character in text):
        raise ValueError(label + " contains unsupported characters")
    return text


def _integer(value, label, low, high):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(label + " must be an integer")
    if value < low or value > high:
        raise ValueError(label + " is out of range")
    return value


def _session_id(service):
    return service.store.current_id


def _collection_id(value):
    return _identifier(value, "Collection id", 80)


def _wait_seconds(args, default):
    if "wait_seconds" not in args:
        return default
    return _integer(args["wait_seconds"], "wait_seconds", 0, 10)


def _observed_active_tab(service, requested):
    bridge = service.bridge
    active_id = bridge.active_tab_id
    if not isinstance(active_id, str) or not active_id:
        raise ValueError("No observed active tab")
    if requested is not None and requested != active_id:
        raise ValueError("Collection uses the observed active tab")
    if bridge.tab(active_id) != active_id:
        raise ValueError("Active tab could not be observed")
    listed = [item for item in bridge.tabs if isinstance(item, dict) and item.get("id") == active_id]
    if len(listed) != 1:
        raise ValueError("Active tab is not in the observed tab list")
    list_url = listed[0].get("url")
    if not isinstance(list_url, str):
        raise ValueError("Observed tab URL is inconsistent")
    return active_id, list_url


def _task_owns_browser(service):
    return bool(service.tasks.running or getattr(getattr(service, "workflows", None), "running", False))


def _chat_active(service):
    job = service.chat_job
    return job is not None and not job.done()


def _plan_source_kind(plan):
    if isinstance(plan, dict):
        value = plan.get("source_kind", "website")
    else:
        value = getattr(plan, "source_kind", "website")
    if not isinstance(value, str) or not value:
        return "website"
    return value


def _count_field(value):
    if isinstance(value, bool) or not isinstance(value, int):
        return 0
    return value


def _budgets(plan):
    feed = _plan_source_kind(plan) in _FEED_KINDS
    budgets = {"max_seconds": plan.get("max_seconds"), "max_pages": plan.get("max_pages")}
    if feed:
        budgets["max_items"] = plan.get("max_items")
        budgets["max_scrolls"] = plan.get("max_scrolls")
    return budgets


def _resume_limits(value):
    if not isinstance(value, dict) or not value or set(value) - {"max_seconds", "max_items", "max_scrolls"}:
        raise ValueError("Unsupported collection limits")
    bounds = {"max_seconds": (1, 14400), "max_items": (1, 5000), "max_scrolls": (1, 10000)}
    for key, (low, high) in bounds.items():
        if key in value:
            _integer(value[key], key, low, high)
    return value


def _public_summary(record):
    if not isinstance(record, dict):
        raise ValueError("Collection summary is unavailable")
    plan = record.get("plan") if isinstance(record.get("plan"), dict) else {}
    categories = []
    for item in plan.get("categories") or []:
        if isinstance(item, dict):
            categories.append(
                {
                    "id": item.get("id"),
                    "name": item.get("name"),
                    "description": item.get("description"),
                }
            )
    source_kind = _plan_source_kind(plan)
    feed = source_kind in _FEED_KINDS
    scope = {
        "origin": plan.get("origin"),
        "section_path": plan.get("section_path"),
        "max_pages": plan.get("max_pages"),
        "max_seconds": plan.get("max_seconds"),
    }
    if feed:
        scope["max_items"] = plan.get("max_items")
        scope["max_scrolls"] = plan.get("max_scrolls")
    summary = {
        "id": record.get("id"),
        "status": record.get("status"),
        "reason": record.get("reason"),
        "resumable": record["status"] == "paused",
        "title": plan.get("title"),
        "source_kind": source_kind,
        "scope": scope,
        "categories": categories,
        "counters": record.get("counters") if isinstance(record.get("counters"), dict) else {},
        "notice": FEED_NOTICE if feed else NOTICE,
        "budgets": _budgets(plan),
        "source": {"tab_id": plan.get("tab_id"), "start_url": plan.get("start_url")},
    }
    if feed:
        summary["counters"] = dict(summary["counters"])
        summary["counters"]["items"] = summary["counters"].pop("pages", 0)
        raw = record.get("progress") if isinstance(record.get("progress"), dict) else {}
        summary["progress"] = {
            "scrolls": _count_field(raw.get("scrolls", 0)),
            "stalls": _count_field(raw.get("stalls", 0)),
        }
    if isinstance(record.get('supervision'), dict):
        policy = record['supervision']
        pending = policy.get('pending')
        summary['supervision'] = {k: policy.get(k) for k in ('mode', 'first_items', 'interval_seconds', 'share_samples', 'fields', 'approved')}
        summary['supervision']['pending'] = {k: pending.get(k) for k in ('id', 'status', 'reason')} if isinstance(pending, dict) else None
        summary['notice'] = 'Posts are processed locally. Authorized checkpoint samples may be reviewed by Grok.'
    return summary


def provider_collections(service):
    records = service.collections.summaries(service.store.current_id)
    if not isinstance(records, list):
        return []
    listed = []
    for record in records:
        if len(listed) >= 5:
            break
        if not isinstance(record, dict):
            continue
        summary = _public_summary(record)
        plan = record.get("plan") if isinstance(record.get("plan"), dict) else {}
        title = summary.get("title")
        if not isinstance(title, str):
            title = ""
        item = {
            "id": summary.get("id"),
            "status": summary.get("status"),
            "reason": summary.get("reason"),
            "resumable": summary.get("resumable"),
            "title": title[:120],
            "source_kind": summary.get("source_kind"),
            "counters": summary.get("counters") if isinstance(summary.get("counters"), dict) else {},
        }
        model = plan.get("model")
        if isinstance(model, str):
            item["model"] = model
        item["budgets"] = _budgets(plan)
        if 'supervision' in summary:
            item['supervision'] = summary['supervision']
        item["source"] = summary["source"]  # Historical seed, never an item permalink.
        if "progress" in summary and isinstance(summary.get("progress"), dict):
            item["progress"] = {
                "scrolls": _count_field(summary["progress"].get("scrolls", 0)),
                "stalls": _count_field(summary["progress"].get("stalls", 0)),
            }
        listed.append(item)
    return listed


def _hostname(url):
    if not isinstance(url, str) or not url:
        raise ValueError("Observed tab URL is inconsistent")
    host = urlsplit(url).hostname
    if not isinstance(host, str) or not host:
        raise ValueError("Observed tab URL is inconsistent")
    return host.lower()


def _x_host(url):
    host = _hostname(url)
    return host == "x.com" or host.endswith(".x.com") or host == "twitter.com" or host.endswith(".twitter.com")


def _fence_tab(service, tab_id, url):
    current_id, current_url = _observed_active_tab(service, tab_id)
    if current_id != tab_id or current_url != url or _hostname(current_url) != _hostname(url):
        raise ValueError("Observed tab changed")
    return current_id, current_url


def _feed_payload(response):
    if not isinstance(response, dict) or response.get("exceptionDetails"):
        raise ValueError("Feed snapshot is unavailable")
    value = response
    result = response.get("result")
    if isinstance(result, dict):
        nested = result.get("result", result)
        if isinstance(nested, dict) and "value" in nested:
            value = nested.get("value")
        elif "value" in result:
            value = result.get("value")
    if isinstance(value, dict) and "source_kind" not in value and isinstance(value.get("value"), dict):
        value = value.get("value")
    if not isinstance(value, dict):
        raise ValueError("Feed snapshot is unavailable")
    return value


def _finite_number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError("Feed snapshot is unavailable")
    return value


async def _evaluate_feed_snapshot(bridge, tab_id):
    result = bridge.call(
        tab_id,
        "Runtime.evaluate",
        {"expression": FEED_SNAPSHOT, "returnByValue": True, "awaitPromise": True},
    )
    if hasattr(result, "__await__"):
        result = await result
    return _feed_payload(result)


def _supported_modes(source_kind, page_url):
    if source_kind == "x_bookmarks":
        return ["x_bookmarks"]
    if source_kind == "feed":
        return ["feed"]
    if source_kind == "unsupported":
        return [] if _x_host(page_url) else ["website"]
    return ["website"]


_NAV_PATHS = {"/i/history", "/i/history/likes", "/i/bookmarks"}


def _navigation_links(payload, page_url):
    raw = payload.get("navigation", [])
    if not isinstance(raw, list):
        raise ValueError("Feed snapshot is unavailable")
    if not _x_host(page_url):
        return []
    page = urlsplit(page_url)
    if page.scheme not in {"http", "https"} or not page.hostname:
        raise ValueError("Observed tab URL is inconsistent")
    origin = f"{page.scheme}://{page.netloc}".lower()
    links = []
    for entry in raw:
        if len(links) >= 3:
            break
        if not isinstance(entry, dict) or set(entry) - {"label", "url"}:
            continue
        label, href = entry.get("label"), entry.get("url")
        if not isinstance(label, str) or len(label) > 80 or not isinstance(href, str):
            continue
        parts = urlsplit(href)
        if parts.scheme not in {"http", "https"} or not parts.hostname:
            continue
        if parts.username or parts.password or parts.query or parts.fragment:
            continue
        if f"{parts.scheme}://{parts.netloc}".lower() != origin:
            continue
        path = parts.path or "/"
        if len(path) > 1 and path.endswith("/"):
            path = path[:-1]
        if path not in _NAV_PATHS:
            continue
        links.append({"label": label, "url": f"{parts.scheme}://{parts.netloc}{path}"})
    return links


def _public_inspect(payload, page_url):
    source_kind = payload.get("source_kind")
    if source_kind not in _SNAPSHOT_KINDS:
        raise ValueError("Feed snapshot is unavailable")
    selected_tab = payload.get("selected_tab")
    if not isinstance(selected_tab, str) or len(selected_tab) > 80:
        raise ValueError("Feed snapshot is unavailable")
    items = payload.get("items")
    if not isinstance(items, list):
        raise ValueError("Feed snapshot is unavailable")
    loading = payload.get("loading")
    login_required = payload.get("login_required")
    if not isinstance(loading, bool) or not isinstance(login_required, bool):
        raise ValueError("Feed snapshot is unavailable")
    scroll = payload.get("scroll")
    if not isinstance(scroll, dict):
        raise ValueError("Feed snapshot is unavailable")
    public_scroll = {
        "top": _finite_number(scroll.get("top"), "top"),
        "height": _finite_number(scroll.get("height"), "height"),
        "viewport": _finite_number(scroll.get("viewport"), "viewport"),
    }
    snap_url = payload.get("url")
    if not isinstance(snap_url, str) or snap_url != page_url:
        raise ValueError("Observed tab changed")
    return {
        "source_kind": source_kind,
        "selected_tab": selected_tab,
        "visible_items": len(items),
        "loading": loading,
        "login_required": login_required,
        "scroll": public_scroll,
        "supported_modes": _supported_modes(source_kind, page_url),
        "notice": INSPECT_NOTICE,
        "navigation": _navigation_links(payload, page_url),
    }


async def _inspect(service, args):
    _exact(args, {"tab_id"}, ())
    if _task_owns_browser(service) or service.collections.running:
        raise ValueError("A browser task or collection is already running")
    requested_tab = None
    if "tab_id" in args:
        requested_tab = _text(args["tab_id"], "Tab id", 200)
    tab_id, page_url = _observed_active_tab(service, requested_tab)
    host_id = service.bridge.host_id
    _fence_tab(service, tab_id, page_url)
    payload = await _evaluate_feed_snapshot(service.bridge, tab_id)
    tab_id, page_url = _fence_tab(service, tab_id, page_url)
    if service.bridge.host_id != host_id:
        raise ValueError("Browser host changed")
    return _public_inspect(payload, page_url)


def _open_provider_card(service):
    if service.response:
        service.store.save_message(service.response)
    service.response = None


async def _prepare(service, args):
    _exact(args, _PREPARE_FIELDS, ("request", "title", "categories"))
    if _task_owns_browser(service) or service.collections.running:
        raise ValueError("A browser task or collection is already running")
    # Feed supervision needs explicit state judgments; SemIf passed the local
    # progress diagnostic. An explicit model choice is always preserved.
    default_model = "qwen4b_semif_shared" if args.get("source_kind") in ("feed", "x_bookmarks") else service.settings["local_model"]
    model = args.get("model", default_model)
    if not isinstance(model, str) or model not in _MODELS:
        raise ValueError("Choose an installed local browser model")
    requested_tab = None
    if "tab_id" in args:
        requested_tab = _text(args["tab_id"], "Tab id", 200)
    tab_id, start_url = _observed_active_tab(service, requested_tab)
    plan_args = {key: value for key, value in args.items() if key not in {"model", "tab_id"}}
    plan = CollectionPlan.from_request(plan_args, start_url=start_url, tab_id=tab_id, model=model)
    if _plan_source_kind(plan) in _FEED_KINDS:
        try:
            snapshot = await FeedCollector(service.bridge, plan, threading.Event()).read()
        except CollectionBlocked as exc:
            raise ValueError("Feed unavailable: " + exc.reason + "; open the requested feed before preparing") from exc
        if not isinstance(snapshot, dict) or snapshot.get("source_kind") != _plan_source_kind(plan):
            raise ValueError("source mismatch: open the requested feed before preparing")
    record = service.collection_store.create(_session_id(service), service.turn_id, plan)
    if plan.source_kind != 'website':
        record = service.collections.supervision.configure(_session_id(service), record['id'],
            {'share_samples': getattr(service, 'share_review_samples', False)})
    return _public_summary(record)


async def _start(service, args):
    _exact(args, {"collection_id", "wait_seconds"}, ("collection_id",))
    if _task_owns_browser(service) or service.collections.running:
        raise ValueError("A browser task or collection is already running")
    collection_id = _collection_id(args["collection_id"])
    wait_seconds = _wait_seconds(args, 10)
    _open_provider_card(service)
    session_id = _session_id(service)
    await service.collections.start(session_id, collection_id)
    record = await service.collections.wait(session_id, collection_id, wait_seconds)
    return _public_summary(record)


async def _status(service, args):
    _exact(args, {"collection_id", "wait_seconds"}, ("collection_id",))
    collection_id = _collection_id(args["collection_id"])
    wait_seconds = _wait_seconds(args, 0)
    session_id = _session_id(service)
    if wait_seconds:
        record = await service.collections.wait(session_id, collection_id, wait_seconds)
    else:
        record = service.collections.summary(session_id, collection_id)
    return _public_summary(record)


async def _control(service, args):
    _exact(args, {"collection_id", "action", "limits"}, ("collection_id", "action"))
    action = args["action"]
    if not isinstance(action, str) or action not in _MCP_CONTROL_ACTIONS:
        raise ValueError("Unsupported collection action")
    limits = None
    if "limits" in args:
        if action != "resume":
            raise ValueError("Unsupported collection limits")
        limits = _resume_limits(args["limits"])
    if action in {"start", "resume"} and _task_owns_browser(service):
        raise ValueError("A browser task owns the browser")
    session_id = _session_id(service)
    collection_id = _collection_id(args["collection_id"])
    if limits is not None:
        service.collection_store.configure_limits(session_id, collection_id, limits)
    record = await service.collections.control(session_id, collection_id, action)
    return _public_summary(record)


async def tool(service, name, args):
    _object(args)
    _session_id(service)
    if name == "inspect_collection_source":
        return await _inspect(service, args)
    if name == "prepare_collection":
        return await _prepare(service, args)
    if name == "start_collection":
        return await _start(service, args)
    if name == "collection_status":
        return await _status(service, args)
    if name == "control_collection":
        return await _control(service, args)
    raise ValueError("Unknown collection tool")


def _route_collection_id(request):
    return _collection_id(request.match_info["collection_id"])


def _list_filters(request):
    keys = list(request.query.keys())
    if set(keys) - _LIST_QUERY or len(keys) != len(set(keys)):
        raise ValueError("Unexpected collection query")
    query = request.query.get("query", "")
    category = request.query.get("category", "")
    if not isinstance(query, str) or len(query) > 200:
        raise ValueError("Invalid collection query")
    if not isinstance(category, str) or len(category) > 64:
        raise ValueError("Invalid collection category")
    try:
        offset = int(request.query.get("offset", "0"))
        limit = int(request.query.get("limit", "50"))
    except (TypeError, ValueError):
        raise ValueError("Invalid collection page")
    if isinstance(offset, bool) or isinstance(limit, bool):
        raise ValueError("Invalid collection page")
    if offset < 0 or offset > 100000 or limit < 1 or limit > 50:
        raise ValueError("Invalid collection page")
    return query, category, offset, limit


def _taxonomy_label(item, categories):
    classification = item.get("classification")
    if not isinstance(classification, dict):
        return "Unlabeled"
    label_id = classification.get("label_id")
    if label_id == "needs_review":
        return "Needs review"
    for category in categories:
        if isinstance(category, dict) and category.get("id") == label_id:
            name = category.get("name")
            if isinstance(name, str) and name.strip():
                return name.strip()
    return "Unlabeled"


def _item_text(item):
    for key in ("text", "excerpt", "content"):
        value = item.get(key)
        if isinstance(value, str):
            return value
    return ""


def _item_url(item):
    for key in ("url", "source_url", "page_url"):
        value = item.get(key)
        if isinstance(value, str):
            return value
    return ""


def _load_export_items(service, session_id, collection_id):
    items = []
    offset = 0
    while len(items) < _EXPORT_CAP:
        page = service.collection_store.items(
            session_id,
            collection_id,
            offset=offset,
            limit=min(_EXPORT_PAGE, _EXPORT_CAP - len(items)),
        )
        chunk = page.get("items") if isinstance(page, dict) else None
        if not isinstance(chunk, list) or not chunk:
            break
        items.extend(item for item in chunk if isinstance(item, dict))
        offset += len(chunk)
        total = page.get("total")
        if not isinstance(total, int) or offset >= total:
            break
    return items[:_EXPORT_CAP]


def neutralize_cell(value):
    if value is None:
        return ""
    text = value if isinstance(value, str) else str(value)
    probe = text.lstrip(" \t\r\n")
    if (text[:1] and text[:1] in "\t\r") or (probe[:1] and probe[:1] in _FORMULA_LEAD):
        return "'" + text
    return text


def _csv_document(record, items):
    plan = record.get("plan") if isinstance(record.get("plan"), dict) else {}
    categories = plan.get("categories") if isinstance(plan.get("categories"), list) else []
    buffer = io.StringIO(newline="")
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(["field", "value"])
    for label, value in (
        ("status", record.get("status")),
        ("reason", record.get("reason")),
        ("origin", plan.get("origin")),
        ("section_path", plan.get("section_path")),
        ("max_pages", plan.get("max_pages")),
        ("max_seconds", plan.get("max_seconds")),
        ("source_kind", plan.get("source_kind") or "website"),
        ("max_items", plan.get("max_items")),
        ("max_scrolls", plan.get("max_scrolls")),
    ):
        writer.writerow([label, neutralize_cell(value)])
    writer.writerow([])
    fields = (record.get('supervision') or {}).get('fields') or ['url', 'text']
    writer.writerow(['category', *fields, 'taxonomy_version'])
    for item in items:
        writer.writerow(
            [
                neutralize_cell(_taxonomy_label(item, categories)),
                *[neutralize_cell(_item_url(item) if field == 'url' else _item_text(item) if field == 'text' else item.get(field)) for field in fields],
                neutralize_cell((item.get('classification') or {}).get('taxonomy_version')),
            ]
        )
    return buffer.getvalue()


def _markdown_inline(value):
    text = "" if value is None else str(value)
    escaped = []
    for character in text:
        if character in "\r\n":
            escaped.append(" ")
        elif character in "&<>\"'`\\*_{}[]()#+!-|>":
            if character == "&":
                escaped.append("&amp;")
            elif character == "<":
                escaped.append("&lt;")
            elif character == ">":
                escaped.append("&gt;")
            elif character == '"':
                escaped.append("&quot;")
            else:
                escaped.append("\\" + character)
        else:
            escaped.append(character)
    return "".join(escaped)


def _safe_http_target(value):
    if not isinstance(value, str):
        return ""
    text = value.strip()
    parts = urlsplit(text)
    if parts.scheme not in {"http", "https"} or not parts.hostname:
        return ""
    if parts.username or parts.password:
        return ""
    if any(character in text for character in '<> "\\\t\r\n'):
        return ""
    encoded = quote(text, safe=":/?#[]@!$&'()*+,;=%-._~")
    if "<" in encoded or ">" in encoded or encoded != text:
        # Keep only an already-canonical HTTP target inside angle brackets.
        if any(character in encoded for character in '<> "\\\t\r\n'):
            return ""
    if "<" in encoded or ">" in encoded:
        return ""
    return encoded


def _markdown_document(record, items):
    plan = record.get("plan") if isinstance(record.get("plan"), dict) else {}
    categories = plan.get("categories") if isinstance(plan.get("categories"), list) else []
    lines = [
        "# Collection",
        "",
        "- Status: " + _markdown_inline(record.get("status")),
        "- Reason: " + _markdown_inline(record.get("reason")),
        "- Origin: " + _markdown_inline(plan.get("origin")),
        "- Section: " + _markdown_inline(plan.get("section_path")),
        "- Max pages: " + _markdown_inline(plan.get("max_pages")),
        "- Max seconds: " + _markdown_inline(plan.get("max_seconds")),
        "- Source: " + _markdown_inline(plan.get("source_kind") or "website"),
        "- Max items: " + _markdown_inline(plan.get("max_items")),
        "- Max scrolls: " + _markdown_inline(plan.get("max_scrolls")),
        "",
        "## Items",
        "",
    ]
    for item in items:
        lines.append("### " + _markdown_inline(_taxonomy_label(item, categories)))
        lines.append("")
        target = _safe_http_target(_item_url(item))
        if target:
            lines.append("- URL: <" + target + ">")
        else:
            lines.append("- URL: unavailable")
        for field in (record.get('supervision') or {}).get('fields', []):
            if field in {'author', 'published_at', 'captured_at'}:
                lines.append('- ' + _markdown_inline(field) + ': ' + _markdown_inline(item.get(field) or 'Not observed'))
        lines.append('- Taxonomy version: ' + _markdown_inline((item.get('classification') or {}).get('taxonomy_version')))
        lines.append("")
        lines.append("> " + _markdown_inline(_item_text(item)))
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _export_filename(collection_id, extension):
    return "collection-" + collection_id + "." + extension


def register_routes(app, service):
    async def get_collection(request):
        collection_id = _route_collection_id(request)
        query, category, offset, limit = _list_filters(request)
        session_id = _session_id(service)
        record = service.collections.summary(session_id, collection_id)
        page = service.collection_store.items(
            session_id, collection_id, offset=offset, limit=limit, query=query, category=category
        )
        if not isinstance(page, dict):
            raise ValueError("Collection items are unavailable")
        return web.json_response({"collection": record, **page})

    async def export_collection(request):
        keys = list(request.query.keys())
        if set(keys) != {"format"} or len(keys) != 1:
            raise ValueError("Expected format=csv or format=markdown")
        export_format = request.query.get("format")
        if export_format not in {"csv", "markdown"}:
            raise ValueError("Expected format=csv or format=markdown")
        collection_id = _route_collection_id(request)
        session_id = _session_id(service)
        record = service.collections.summary(session_id, collection_id)
        items = _load_export_items(service, session_id, collection_id)
        if export_format == "csv":
            payload = {
                "content": _csv_document(record, items),
                "filename": _export_filename(collection_id, "csv"),
                "mime_type": "text/csv; charset=utf-8",
            }
        else:
            payload = {
                "content": _markdown_document(record, items),
                "filename": _export_filename(collection_id, "md"),
                "mime_type": "text/markdown; charset=utf-8",
            }
        return web.json_response(payload)

    async def post_control(request):
        body = await request.json()
        if not isinstance(body, dict) or set(body) - {"action", "limits", "review_id"} or "action" not in body:
            raise ValueError("Expected exactly an action")
        if "limits" in body and set(body) != {"action", "limits"}:
            raise ValueError("Expected exactly an action")
        action = body['action']
        if not isinstance(action, str):
            raise ValueError('Unsupported collection action')
        if action in {'approve_checkpoints', 'approve_continuous'}:
            if set(body) != {'action', 'review_id'}:
                raise ValueError('Expected review id')
            if _chat_active(service) or _task_owns_browser(service) or service.collections.running:
                raise ValueError('Wait for the active agent before continuing')
            sid, rid = _session_id(service), _route_collection_id(request)
            mode = 'checkpoints' if action == 'approve_checkpoints' else 'continuous'
            service.collections.supervision.approve(sid, rid, body['review_id'], mode=mode)
            result = await service.collections.start(sid, rid)
            return web.json_response({'collection': result})
        if 'review_id' in body:
            raise ValueError('Review id only belongs to review approval')
        if not isinstance(action, str) or action not in _CONTROL_ACTIONS:
            raise ValueError("Unsupported collection action")
        limits = None
        if "limits" in body:
            if action != "resume":
                raise ValueError("Unsupported collection limits")
            limits = _resume_limits(body["limits"])
        if action in {"start", "resume"} and (_chat_active(service) or _task_owns_browser(service)):
            raise ValueError("Stop the active conversation or browser task before starting a collection")
        session_id = _session_id(service)
        collection_id = _route_collection_id(request)
        if limits is not None:
            service.collection_store.configure_limits(session_id, collection_id, limits)
        record = await service.collections.control(session_id, collection_id, action)
        return web.json_response({"collection": record})

    app.router.add_get("/collections/{collection_id}", get_collection)
    app.router.add_get("/collections/{collection_id}/export", export_collection)
    app.router.add_post("/collections/{collection_id}/control", post_control)


def main():
    raise RuntimeError("collection_tools is imported by the Jet Browser service")


if __name__ == "__main__":
    main()
