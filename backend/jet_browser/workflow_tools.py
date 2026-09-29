"""Finite MCP tools for workflows. Current session only."""

from __future__ import annotations

from . import workflow_templates
from .workflow_store import CAPABILITIES

NAMES = frozenset(
    {
        "save_workflow",
        "read_workflow",
        "run_workflow",
        "workflow_status",
        "control_workflow",
        "workflow_records",
        "patch_workflow_record",
        "workflow_sdk",
    }
)

_DEFINITION_KEYS = {
    "title",
    "source",
    "tab_id",
    "start_url",
    "source_kind",
    "model",
    "categories",
    "capabilities",
    "limits",
    "template",
}
# A template selection replaces these two fields; see workflow_templates.
_TEMPLATE_FILLED = {"source", "capabilities"}
_LIMITS = {
    "max_seconds": (1, 14400),
    "max_calls": (1, 10000),
    "max_items": (1, 5000),
}
_CALLS = (
    "feed.observe",
    "feed.scroll",
    "post.recover",
    "model.decide",
    "model.classify",
    "model.summarize",
    "model.best_tag",
    "records.put",
    "records.list",
    "records.patch",
    "run.checkpoint",
    "run.progress",
)

_SDK = """\
Prefer a built-in template (see templates) whenever one fits: call save_workflow with
definition.template {name, options} and no source or capabilities. Write custom
JavaScript only when no template can express the request, and keep it small.
Jet workflow JavaScript runs in a private JavaScriptCore process, not in the page.
jet.input is {checkpoint, categories, counts, budget}. budget is this slice's
{seconds, calls}. jet.call(name, args) is synchronous.
Use saved item flags for deduplication. feed observations include scroll geometry and status_text. end_of_feed=false means unproven, not infinite. Stop after repeated no-progress observations.
Checkpoint or finish before 180 seconds. A timed-out slice pauses and does not restart.
Calls, saved items, and elapsed time accumulate across resumes.
Allowed calls are only the workflow runtime capabilities.

feed.observe {} -> {observation_id, items:[{id,url,text,author,published_at,truncated}], loading, end_of_feed}
feed.scroll {observation_id} -> the next observation
post.recover {item_id} -> {status:"recovered", blocked:false, item, id, revision} or {status:"blocked", blocked:true, reason}. Uses an exact owned X detail tab and updates local evidence. Check blocked before classifying; if blocked, request review or keep explicit partial evidence. Supported only for source_kind x_bookmarks.
model.decide {question, choices:{id:description}, text or item_id} -> {choice, model}. At most 8 choices. Local readout only.
model.classify {item_id} -> {tags:[category ids], unknown_tags, model}. Uses this workflow's categories as independent tags.
model.summarize {item_id} -> {summary, model}. Local model. Summary must come from source evidence.
model.best_tag {item_id} -> {tag or null, model}. One best category or none; a second pass for items model.classify left untagged.
records.put {item_id, tags, summary} -> {id, revision}. Copies observed evidence and rejects unknown tags.
records.list {limit?, offset?} -> {items, total}. Local rows, at most 20 per call.
records.patch {item_id, expected_revision, patch:{tags?, summary?}} -> row. While running, only the workflow's audited local actor. Grok edits require the workflow to be paused.
run.checkpoint {state, status:review|pause|complete|continue, summary} yields immediately. The next run sees jet.input.checkpoint. No further script steps run after it. review wakes the reviewer; continue starts the next slice locally without review when the slice saved or scrolled; pause waits for the user.
run.progress {message} posts a short activity line.
"""

_EXAMPLE = """\
const observed = jet.call('feed.observe', {});
const items = (observed.items || []).slice(0, 10);
for (const item of items) {
  const decision = jet.call('model.decide', {
    question: 'Keep this post?',
    choices: {keep: 'Save the post', skip: 'Skip the post'},
    item_id: item.id
  });
  if (decision.choice !== 'keep') continue;
  const classified = jet.call('model.classify', {item_id: item.id});
  const summarized = jet.call('model.summarize', {item_id: item.id});
  jet.call('records.put', {
    item_id: item.id,
    tags: classified.tags || [],
    summary: summarized.summary || ''
  });
  jet.call('run.progress', {message: 'Saved an item'});
}
jet.call('run.checkpoint', {
  state: {seen: items.length},
  status: 'complete',
  summary: 'Reviewed the visible items'
});
"""


def _capability_names():
    if isinstance(CAPABILITIES, dict):
        return [str(name) for name in CAPABILITIES]
    return [str(name) for name in CAPABILITIES]


def _strict(properties, required):
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": properties,
        "required": list(required),
    }


def schemas(schema):
    build = schema if callable(schema) else _strict

    def obj(properties, required):
        made = build(properties, required)
        if isinstance(made, dict):
            made = dict(made)
            made.setdefault("type", "object")
            made["additionalProperties"] = False
        return made

    names = _capability_names()
    capability_items = {"type": "string"}
    if names:
        capability_items["enum"] = names
    limits = obj(
        {
            "max_seconds": {"type": "integer", "minimum": 1, "maximum": 14400},
            "max_calls": {"type": "integer", "minimum": 1, "maximum": 10000},
            "max_items": {"type": "integer", "minimum": 1, "maximum": 5000},
        },
        ("max_seconds", "max_calls", "max_items"),
    )
    category = obj(
        {"id": {"type": "string"}, "name": {"type": "string"}, "description": {"type": "string"}},
        ("id", "name", "description"),
    )
    option_properties = {}
    for spec in workflow_templates.TEMPLATES.values():
        for key, (kind, _default, low, high) in spec["options"].items():
            option_properties[key] = (
                {"type": "boolean"} if kind is bool else {"type": "integer", "minimum": low, "maximum": high}
            )
    template = obj(
        {
            "name": {"type": "string", "enum": sorted(workflow_templates.TEMPLATES)},
            "options": obj(option_properties, ()),
        },
        ("name",),
    )
    definition = obj(
        {
            "title": {"type": "string"},
            "source": {"type": "string", "maxLength": 32768},
            "tab_id": {"type": "string"},
            "start_url": {"type": "string"},
            "source_kind": {"type": "string"},
            "model": {"type": "string"},
            "categories": {"type": "array", "items": category},
            "capabilities": {"type": "array", "items": capability_items},
            "limits": limits,
            "template": template,
        },
        # Either source+capabilities or template; _definition enforces exactly one.
        (
            "title",
            "tab_id",
            "start_url",
            "source_kind",
            "model",
            "categories",
            "limits",
        ),
    )
    patch = obj(
        {
            "tags": {"type": "array", "items": {"type": "string"}},
            "summary": {"type": "string", "maxLength": 500},
        },
        (),
    )
    specs = [
        (
            "save_workflow",
            "Save a workflow for the current session: a built-in template with options, or custom source.",
            {
                "definition": definition,
                "workflow_id": {"type": "string"},
                "expected_revision": {"type": "integer"},
            },
            ("definition",),
        ),
        (
            "read_workflow",
            "Read authorized workflow source and definition. Pass revision for an immutable copy.",
            {"workflow_id": {"type": "string"}, "revision": {"type": "integer"}},
            ("workflow_id",),
        ),
        (
            "run_workflow",
            "Start a prepared or paused workflow in the background.",
            {"workflow_id": {"type": "string"}},
            ("workflow_id",),
        ),
        (
            "workflow_status",
            "Metadata for one workflow, or the latest workflows in this session.",
            {"workflow_id": {"type": "string"}},
            (),
        ),
        (
            "control_workflow",
            "Pause, stop, or resume the owned workflow run.",
            {
                "workflow_id": {"type": "string"},
                "action": {"type": "string", "enum": ["pause", "stop", "resume"]},
            },
            ("workflow_id", "action"),
        ),
        (
            "workflow_records",
            "Record counts, or short review excerpts when sharing is enabled.",
            {
                "workflow_id": {"type": "string"},
                "limit": {"type": "integer", "minimum": 0, "maximum": 5},
                "offset": {"type": "integer", "minimum": 0, "maximum": 0},
            },
            ("workflow_id",),
        ),
        (
            "patch_workflow_record",
            "Edit tags or summary on a paused workflow record.",
            {
                "workflow_id": {"type": "string"},
                "item_id": {"type": "string"},
                "expected_revision": {"type": "integer"},
                "patch": patch,
            },
            ("workflow_id", "item_id", "expected_revision", "patch"),
        ),
        (
            "workflow_sdk",
            "Built-in templates, runtime call reference and a short custom example.",
            {},
            (),
        ),
    ]
    tools = []
    for name, description, properties, required in specs:
        tools.append(
            {
                "name": name,
                "description": description,
                "inputSchema": obj(properties, required),
            }
        )
    return tools


def _args(args, allowed, required):
    if args is None:
        args = {}
    if not isinstance(args, dict):
        raise ValueError("arguments must be an object")
    extra = sorted(set(args) - set(allowed))
    if extra:
        raise ValueError("unknown field: " + extra[0])
    for key in required:
        if key not in args:
            raise ValueError(key + " is required")
    return args


def _session(service):
    sid = getattr(getattr(service, "store", None), "current_id", None)
    if not sid:
        raise RuntimeError("no current session")
    return sid


def _int_in(value, lo, hi, label):
    if isinstance(value, bool) or not isinstance(value, int) or value < lo or value > hi:
        raise ValueError(label + " is out of range")
    return value


def _definition(raw):
    if not isinstance(raw, dict):
        raise ValueError("definition must be an object")
    extra = set(raw) - _DEFINITION_KEYS
    if extra:
        raise ValueError("unknown field: " + sorted(extra)[0])
    template = raw.get("template")
    if template is not None and "source" in raw:
        raise ValueError("use either source or template, not both")
    required = _DEFINITION_KEYS - {"template"} - (_TEMPLATE_FILLED if template is not None else set())
    for key in sorted(required):
        if key not in raw:
            raise ValueError(key + " is required")
    for key in ("title", "tab_id", "start_url", "source_kind", "model"):
        if not isinstance(raw[key], str) or not raw[key].strip():
            raise ValueError(key + " is required")
    if not isinstance(raw["categories"], list):
        raise ValueError("categories must be a list")
    categories = []
    for item in raw["categories"]:
        if not isinstance(item, dict):
            raise ValueError("category must be an object")
        unknown = set(item) - {"id", "name", "description"}
        if unknown:
            raise ValueError("unknown field: " + sorted(unknown)[0])
        if not isinstance(item.get("id"), str) or not item["id"].strip():
            raise ValueError("category id is required")
        if not isinstance(item.get("description"), str):
            raise ValueError("category description is required")
        categories.append({"id": item["id"], "name": item.get("name", item["id"]), "description": item["description"]})
    limits_raw = raw["limits"]
    if not isinstance(limits_raw, dict):
        raise ValueError("limits must be an object")
    unknown = set(limits_raw) - set(_LIMITS)
    if unknown:
        raise ValueError("unknown field: " + sorted(unknown)[0])
    limits = {}
    for key, (lo, hi) in _LIMITS.items():
        if key not in limits_raw:
            raise ValueError(key + " is required")
        limits[key] = _int_in(limits_raw[key], lo, hi, key)
    if template is not None:
        source, capabilities = workflow_templates.render(template, raw["source_kind"], limits)
    else:
        source = raw["source"]
        if not isinstance(source, str) or not source.strip():
            raise ValueError("source is required")
        if not isinstance(raw["capabilities"], list):
            raise ValueError("capabilities must be a list")
        allowed = set(_capability_names())
        capabilities = []
        for name in raw["capabilities"]:
            if not isinstance(name, str) or (allowed and name not in allowed):
                raise ValueError("unknown capability")
            capabilities.append(name)
    if len(source.encode("utf-8")) > 32768:
        raise ValueError("source is too large")
    return {
        "title": raw["title"].strip(),
        "source": source,
        "tab_id": raw["tab_id"],
        "start_url": raw["start_url"],
        "source_kind": raw["source_kind"],
        "model": raw["model"],
        "categories": categories,
        "capabilities": capabilities,
        "limits": limits,
    }


def _view(row):
    if not isinstance(row, dict):
        raise RuntimeError("workflow not found")
    if "definition" in row and isinstance(row.get("definition"), dict):
        definition = row["definition"]
        return {
            "id": row.get("id"),
            "revision": row.get("revision"),
            "title": row.get("title") or definition.get("title"),
            "status": row.get("status"),
            "source": definition.get("source"),
            "definition": definition,
        }
    return {
        "id": row.get("id"),
        "revision": row.get("revision"),
        "title": row.get("title"),
        "status": row.get("status"),
        "source": row.get("source"),
        "definition": {key: row.get(key) for key in _DEFINITION_KEYS if key in row},
    }


def _excerpt(row):
    text = row.get("text") or ""
    summary = row.get("summary") or ""
    if not isinstance(text, str):
        text = ""
    if not isinstance(summary, str):
        summary = ""
    return {
        "id": row.get("id"),
        "url": row.get("url"),
        "excerpt": text[:400],
        "author": row.get("author"),
        "published_at": row.get("published_at"),
        "captured_at": row.get("captured_at"),
        "truncated": row.get("truncated"),
        "tags": row.get("tags"),
        "summary": summary[:400],
        "revision": row.get("revision"),
    }


def _patch(raw):
    if not isinstance(raw, dict):
        raise ValueError("patch must be an object")
    unknown = set(raw) - {"tags", "summary"}
    if unknown:
        raise ValueError("unknown field: " + sorted(unknown)[0])
    if not raw:
        raise ValueError("patch is empty")
    out = {}
    if "tags" in raw:
        tags = raw["tags"]
        if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
            raise ValueError("tags must be strings")
        out["tags"] = tags
    if "summary" in raw:
        if not isinstance(raw["summary"], str):
            raise ValueError("summary must be text")
        out["summary"] = raw["summary"][:500]
    return out


async def tool(service, name, args):
    if name not in NAMES:
        raise ValueError("unknown tool")
    sid = _session(service)
    store = service.workflow_store
    workflows = service.workflows
    if name == "save_workflow":
        data = _args(args, {"definition", "workflow_id", "expected_revision"}, ("definition",))
        if getattr(workflows, "running", False):
            raise RuntimeError("pause the workflow before saving")
        definition = _definition(data["definition"])
        kwargs = {}
        if "workflow_id" in data:
            if not isinstance(data["workflow_id"], str) or not data["workflow_id"]:
                raise ValueError("workflow_id is invalid")
            kwargs["workflow_id"] = data["workflow_id"]
        if "expected_revision" in data:
            kwargs["expected_revision"] = _int_in(data["expected_revision"], 0, 10**9, "expected_revision")
        saved = store.save(sid, definition, **kwargs)
        result = {
            "id": saved.get("id"),
            "revision": saved.get("revision"),
            "status": saved.get("status"),
            "title": saved.get("title") or definition["title"],
        }
        template = data["definition"].get("template")
        if template is not None:
            result["template"] = template["name"]
            result["capabilities"] = definition["capabilities"]
            result["options"] = workflow_templates.effective_options(definition["source"])
            if definition["source_kind"] != "x_bookmarks":
                # Otherwise Grok re-saves to "enable" an option the template ignores here.
                result["note"] = "recover_truncated applies only to source_kind x_bookmarks; it is off for this source."

        return result
    if name == "read_workflow":
        data = _args(args, {"workflow_id", "revision"}, ("workflow_id",))
        wid = data["workflow_id"]
        if not isinstance(wid, str) or not wid:
            raise ValueError("workflow_id is invalid")
        if "revision" in data and data["revision"] is not None:
            revision = _int_in(data["revision"], 0, 10**9, "revision")
            row = {"id": wid, "revision": revision, "definition": store.version(sid, wid, revision)}
        else:
            row = store.get(sid, wid)
        if not row:
            raise RuntimeError("workflow not found")
        return _view(row)
    if name == "run_workflow":
        data = _args(args, {"workflow_id"}, ("workflow_id",))
        if not isinstance(data["workflow_id"], str) or not data["workflow_id"]:
            raise ValueError("workflow_id is invalid")
        return await workflows.start(sid, data["workflow_id"])
    if name == "workflow_status":
        data = _args(args, {"workflow_id"}, ())
        if "workflow_id" in data:
            if not isinstance(data["workflow_id"], str) or not data["workflow_id"]:
                raise ValueError("workflow_id is invalid")
            return workflows.summary(sid, data["workflow_id"], include_source=False)
        return {"workflows": workflows.summaries(sid)}
    if name == "control_workflow":
        data = _args(args, {"workflow_id", "action"}, ("workflow_id", "action"))
        if data["action"] not in ("pause", "stop", "resume"):
            raise ValueError("unknown workflow action")
        if not isinstance(data["workflow_id"], str) or not data["workflow_id"]:
            raise ValueError("workflow_id is invalid")
        return await workflows.control(sid, data["workflow_id"], data["action"])
    if name == "workflow_records":
        data = _args(args, {"workflow_id", "limit", "offset"}, ("workflow_id",))
        wid = data["workflow_id"]
        if not isinstance(wid, str) or not wid:
            raise ValueError("workflow_id is invalid")
        _int_in(data.get("offset", 0), 0, 0, "offset")
        if not getattr(service, "share_review_samples", False):
            listed = store.records(sid, wid, limit=0, offset=0)
            return {"total": int(listed.get("total") or 0)}
        limit = _int_in(data.get("limit", 5), 0, 5, "limit")
        total = store.records(sid, wid, limit=0)["total"]
        listed = store.records(sid, wid, limit=limit, offset=max(0, total - 5))
        items = [_excerpt(item) for item in (listed.get("items") or [])[:5]]
        return {"items": items, "total": int(listed.get("total") or 0)}
    if name == "patch_workflow_record":
        data = _args(
            args,
            {"workflow_id", "item_id", "expected_revision", "patch"},
            ("workflow_id", "item_id", "expected_revision", "patch"),
        )
        wid = data["workflow_id"]
        if not isinstance(wid, str) or not wid:
            raise ValueError("workflow_id is invalid")
        if not isinstance(data["item_id"], str) or not data["item_id"]:
            raise ValueError("item_id is invalid")
        row = store.get(sid, wid)
        if not row:
            raise RuntimeError("workflow not found")
        if row.get("status") != "paused":
            raise RuntimeError("pause the workflow before editing records")
        revision = _int_in(data["expected_revision"], 0, 10**9, "expected_revision")
        updated = store.patch_record(
            sid,
            wid,
            data["item_id"],
            _patch(data["patch"]),
            revision,
            actor="grok",
        )
        return {
            "id": updated.get("id", data["item_id"]),
            "revision": updated.get("revision"),
            "tags": updated.get("tags"),
            "summary": updated.get("summary"),
        }
    if name == "workflow_sdk":
        _args(args, set(), ())
        allowed = set(_capability_names())
        calls = [call for call in _CALLS if not allowed or call in allowed]
        return {
            "templates": workflow_templates.catalog(),
            "capabilities": calls,
            "documentation": _SDK,
            "example_source": _EXAMPLE,
        }
    raise ValueError("unknown tool")
