"""TypeSafe makes choices; an optional small OpenAI-compatible model writes field values."""

import json
import math
import os
import time

import httpx

from .questions import NEXT_ACTION, TARGET, TEXT_VALUE

CLIENT = httpx.Client(http2=True, timeout=25)
EXTRACTIVE_TEXT = (
    'You fill one form field. Return {"text":"value"} only. '
    "The field value must come from the part of the request that describes filling or searching. "
    "Ignore instructions to open, view, or select a result after the search. "
    "Use null if no value is provided for this field."
)


def post_json(url, key, body):
    for attempt in range(3):
        try:
            response = CLIENT.post(url, json=body, headers={"Authorization": f"Bearer {key}"})
        except httpx.HTTPError:
            raise RuntimeError("Model connection failed; no action executed.") from None
        if response.status_code in {429, 529, 503} and attempt < 2:
            time.sleep(0.5 * 2**attempt)
            continue
        if response.is_error:
            raise RuntimeError(f"Model provider returned HTTP {response.status_code}; no action executed.")
        return response.json()
    raise RuntimeError("Model unavailable")


def validate_choice(answer, ids):
    try:
        probabilities = answer["probabilities"]
        numbers = [*probabilities.values(), answer["confidence"]]
        valid = (
            answer["choice"] in ids
            and set(probabilities) == set(ids)
            and all(type(n) in (int, float) and math.isfinite(n) and 0 <= n <= 1 for n in numbers)
            and abs(sum(probabilities.values()) - 1) < 0.02
            and probabilities[answer["choice"]] >= max(probabilities.values()) - 1e-6
        )
    except (KeyError, TypeError, ValueError):
        valid = False
    if not valid:
        raise ValueError("Invalid TypeSafe response; no action executed.")
    return answer


def action_space(actions):
    """One index per observed element; each operation has its own valid target choices."""
    elements, indices, targets, controls = [], {}, {}, {}
    operations = {"click": "CLICK", "fill": "TYPE_TEXT", "select": "SELECT"}
    for action in actions:
        kind = action["kind"]
        if kind not in operations:
            controls[action["id"].upper()] = action
            continue
        node = action["node"]
        if node not in indices:
            index = str(len(elements) + 1)
            indices[node] = index
            element = {
                k: action[k]
                for k in (
                    "role",
                    "value",
                    "checked",
                    "selected",
                    "expanded",
                    "form_id",
                    "form_key",
                    "submits_form",
                    "description",
                )
                if k in action
            }
            element.update(index=index, label=action["label"].split(" → ")[0], operations=[])
            if kind == "select":
                element["value"] = action.get("current_value", "")
                element["options"] = []
            elements.append(element)
        index = indices[node]
        operation = operations[kind]
        group = targets.setdefault(operation, {})
        element = elements[int(index) - 1]
        if operation not in element["operations"]:
            element["operations"].append(operation)
        target = index
        if kind == "select":
            target = f"{index}:{len(element['options']) + 1}"
            element["options"].append({"index": target, "label": action["label"], "value": action["value"]})
        group[target] = action
    return elements, targets, controls


def validate_native_choice(answer, ids):
    """Validate observed labels and native distributions, preserving absent confidence."""
    if not answer.get("valid") or answer.get("label") not in ids:
        raise ValueError("Local decision unavailable: " + str(answer.get("unsupported", "Invalid native label")))
    probabilities = answer.get("probabilities")
    confidence = answer.get("confidence")
    if probabilities is not None:
        validate_choice(
            {
                "choice": answer["label"],
                "probabilities": probabilities,
                "confidence": confidence if confidence is not None else 0,
            },
            ids,
        )
    elif confidence is not None:
        raise ValueError("Label-only decisions cannot supply confidence without a native distribution")
    return {"choice": answer["label"], "probabilities": probabilities or {}, "confidence": confidence}


def choose(
    state,
    goal,
    history,
    *,
    mode="jev_hosted",
    policy_profile="baseline",
    pending_forms=None,
    completed_text=None,
    request_cache=None,
):
    elements, targets, controls = action_space(state["actions"])
    labels = {
        "CLICK": "Click an element, button, menu option, autocomplete suggestion, or calendar day.",
        "TYPE_TEXT": "Enter or replace text in an editable field. A small LLM will supply the value from the goal.",
        "SELECT": "Select an observed dropdown value.",
    }
    operations = {key: labels[key] for key in targets}
    operations.update({key: value["label"] for key, value in controls.items()})
    operations.update(DONE="Every requirement is visibly satisfied.", BLOCKED="No supported operation can progress.")
    questions = {
        "operation": {"type": "choice", "criteria": operations, "instructions": {"goal": goal, "rules": NEXT_ACTION}}
    }
    for operation, candidates in targets.items():
        questions[operation.lower() + "_target"] = {
            "type": "choice",
            "criteria": {
                index: {
                    "element": f"[{index}] {a['label']}",
                    "current_value": a.get("current_value", a.get("value", "")),
                    **{k: a[k] for k in ("role", "checked", "selected", "expanded") if k in a},
                }
                for index, a in candidates.items()
            },
            "instructions": {"goal": goal, "operation": operation, "rules": [NEXT_ACTION, TARGET]},
        }
    body = {
        "model": os.environ.get("TYPESAFE_MODEL", "jev-latest"),
        "state": {
            "page": {k: state[k] for k in ("url", "title", "text")},
            "elements": elements,
            "recent_actions": [
                {k: h.get(k) for k in ("action", "kind", "text", "page_changed")} for h in history[-10:]
            ],
        },
        "questions": questions,
    }
    if policy_profile == "baseline":
        body["state"]["elements"] = [
            {k: v for k, v in e.items() if k not in {"form_id", "form_key", "submits_form", "description"}}
            for e in elements
        ]
    else:
        body["state"]["page"].update({k: state[k] for k in ("heading", "lead") if k in state})
        body["state"]["pending_forms"] = pending_forms or []
    if policy_profile.startswith("anchored"):
        body["state"]["completed_text"] = completed_text or {}
    started = time.perf_counter()
    if mode == "jev_hosted":
        if policy_profile != "baseline":
            raise ValueError("Experimental policies are local-only")
        result = post_json("https://api.typesafe.ai/v1/systemone", os.environ["TYPESAFE_API_KEY"], body)
        validate = validate_choice
    else:
        from .local_models import WORKER
        from .policy_profiles import predict_profile

        worker = WORKER
        if policy_profile in {"anchored_cached", "anchored_form_safe_cached"}:
            from .request_cache import RequestCache

            if request_cache is None:
                raise ValueError("Cached policy requires a per-run cache")
            worker = RequestCache(WORKER, request_cache)
        result = predict_profile(worker, mode, body, policy_profile)
        body["model"] = result["model"]
        validate = validate_native_choice
    operation_answer = validate(result["answers"].get("operation", {}), operations)
    operation = operation_answer["choice"]
    target = None
    target_answer = None
    probabilities = {}
    if operation in targets:
        # Unused target heads cannot cause an action. Validate the head selected by the operation.
        target_answer = validate(result["answers"].get(operation.lower() + "_target", {}), targets[operation])
        target = target_answer["choice"]
        choice = targets[operation][target]["id"]
        probabilities = {a["id"]: target_answer["probabilities"].get(index) for index, a in targets[operation].items()}
    else:
        choice = controls[operation]["id"] if operation in controls else operation
        probabilities[choice] = operation_answer["probabilities"].get(operation)
    return {
        "choice": choice,
        "operation": operation,
        "target": target,
        "confidence": operation_answer["confidence"],
        "probabilities": probabilities,
        "operation_probabilities": operation_answer["probabilities"],
        "target_probabilities": target_answer["probabilities"] if target_answer else {},
        "target_confidence": target_answer["confidence"] if target_answer else None,
        "raw_answers": result["answers"],
        "model": result["model"],
        "usage": result.get("usage", {}),
        "latency_ms": round((time.perf_counter() - started) * 1000),
        "request": body,
        "backend": mode,
        "context_audit": result.get("context_audit", {}),
        "native_latency_ms": result.get("latency_ms"),
        "prepare_ms": result.get("prepare_ms"),
        "native_raw": result.get("raw") if mode != "jev_hosted" else None,
        "singleton_heads": result.get("singleton_heads", []),
        "policy_profile": policy_profile,
        "policy_calls": result.get("policy_calls", 1),
        "inference_requests": result.get("inference_requests", 1),
        "control_intents": result.get("control_intents", []),
    }


def field_context(goal, action, page, history):
    return {
        "goal": goal,
        "field": {k: action.get(k) for k in ("label", "role", "value")},
        "page": {"title": page["title"], "text": page["text"][:6000]},
        "recent_actions": [{k: h.get(k) for k in ("action", "text")} for h in history[-6:]],
    }


def extractive_value(content, goal):
    """Accept native plain/quoted text only when it is present in the user's goal."""
    try:
        output = json.loads(content)
    except ValueError:
        output = content.strip()
    if isinstance(output, dict):
        if set(output) != {"text"}:
            raise ValueError("Unexpected text-helper fields")
        output = output["text"]
    if (
        not isinstance(output, str)
        or not output.strip()
        or len(output) > 2000
        or output.casefold() not in goal.casefold()
    ):
        raise ValueError("Text helper supplied no value grounded in the user's request; nothing typed.")
    return output


def field_text(context, *, profile="baseline"):
    if profile not in {"baseline", "extractive", "examples", "examples_v2"}:
        raise ValueError("Unknown text profile")
    key = os.environ.get("TEXT_MODEL_API_KEY")
    if not key:
        raise ValueError("TYPE_TEXT needs TEXT_MODEL_API_KEY; no text is hardcoded or guessed by the executor.")
    base = os.environ.get("TEXT_MODEL_BASE_URL", "https://api.deepseek.com/v1").rstrip("/")
    model = os.environ.get("TEXT_MODEL", "deepseek-chat")
    reasoning = {"thinking": {"type": "disabled"}} if "api.deepseek.com/" in base else {"reasoning": {"effort": "low"}}
    if os.environ.get("TEXT_MODEL_REASONING") == "none":
        reasoning = {"reasoning": {"enabled": False}}
    started = time.perf_counter()
    body = {
        "model": model,
        "max_tokens": 1024,
        "response_format": {"type": "json_object"},
        **reasoning,
        "messages": [
            {"role": "system", "content": EXTRACTIVE_TEXT if profile == "extractive" else TEXT_VALUE},
            {
                "role": "user",
                "content": json.dumps(
                    {"request": context.get("field_request", context["goal"]), "field": context["field"]["label"]}
                    if profile == "extractive"
                    else context
                ),
            },
        ],
    }
    if profile in {"examples", "examples_v2"}:
        from .typing_examples import messages

        body.pop("response_format")
        body.update(messages=messages(context, version=2 if profile == "examples_v2" else 1), max_tokens=128)
    result = post_json(base + "/chat/completions", key, body)
    audit = {
        "model": os.environ.get("TEXT_MODEL_LABEL", model),
        "requested_model": model,
        "text_profile": profile,
        "latency_ms": round((time.perf_counter() - started) * 1000),
        "usage": result.get("usage", {}),
        "request": body,
        "response": result,
    }
    try:
        content = result["choices"][0]["message"]["content"]
        if profile in {"examples", "examples_v2"}:
            from .typing_examples import grounded_value

            value = grounded_value(content, context["goal"])
        elif profile == "extractive":
            value = extractive_value(content, context["goal"])
        else:
            output = json.loads(content)
            value = output["text"]
            if set(output) != {"text"} or not isinstance(value, str) or not value.strip() or len(value) > 2000:
                raise ValueError()
    except (ValueError, KeyError, TypeError, IndexError):
        error = ValueError("Text helper returned no valid field value; nothing typed.")
        error.helper = {**audit, "error": str(error)}
        raise error from None
    return value, audit
