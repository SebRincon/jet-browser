"""Explicit command grounding plus native decisions for values and destinations."""

import re
from copy import deepcopy

from .instruction_parts import field_identity, kind, mentions, split_instructions
from .semantic_policy import named_choices


def route_clauses(worker, mode, goal, elements):
    fields = [e for e in elements if e.get("options") or "checked" in e or "TYPE_TEXT" in e["operations"]]
    routed, navigation = {}, []
    for clause in split_instructions(goal):
        action = kind(clause)
        if action == "open":
            navigation.append(clause)
            continue
        candidates = fields
        if action == "input":
            candidates = [e for e in fields if "TYPE_TEXT" in e["operations"]]
        elif action == "setting":
            candidates = [e for e in fields if e.get("options") or "checked" in e]
        anchors = [e for e in candidates if mentions(clause, e["label"])]
        if not anchors and action == "setting":
            anchors = [
                e
                for e in candidates
                if e.get("options")
                and any(
                    mentions(clause, name)
                    for name in [e.get("value", ""), *[o["label"].split(" → ")[-1] for o in e["options"]]]
                )
            ]
        source = "explicit_field" if len(anchors) == 1 else "native_routing"
        if anchors:
            candidates = anchors
        if len(candidates) == 1 and action in {"input", "setting", "keep"}:
            target = candidates[0]["index"]
            if source != "explicit_field":
                source = "only_compatible_control"
        elif candidates:
            selected, _ = named_choices(
                worker,
                mode,
                clause,
                {
                    "route": (
                        "Which visible field should this instruction change?",
                        {**{e["index"]: e["label"] for e in candidates}, "NONE": "No field change"},
                    )
                },
            )
            target = selected["route"]
        else:
            continue
        if target != "NONE":
            routed.setdefault(target, []).append({"clause": clause, "kind": action, "source": source})
    return routed, "\n".join(navigation) or goal


def predict_anchored(worker, mode, request, *, literal_values=False, item_descriptions=False, form_safe=False):
    from .policy_profiles import action_result

    state = request["state"]
    goal = request["questions"]["operation"]["instructions"]["goal"]
    routed, destination = route_clauses(worker, mode, goal, state["elements"])
    required, excluded, intents = {}, set(), []
    for e in state["elements"]:
        index = e["index"]
        is_text = "TYPE_TEXT" in e["operations"]
        if is_text or "checked" in e:
            excluded.add(index)
        parts = routed.get(index, [])
        if not parts:
            continue
        if len(parts) > 1:
            selected, _ = named_choices(
                worker,
                mode,
                goal,
                {
                    "clause": (
                        f"Which instruction defines the requested final value of {e['label']}?",
                        {str(i): part["clause"] for i, part in enumerate(parts)},
                    )
                },
            )
            part = parts[int(selected["clause"])]
        else:
            part = parts[0]
        clause = part["clause"]
        desired = "KEEP"
        if part["kind"] == "keep":
            pass
        elif e.get("options"):
            values = {o["index"]: o["label"].split(" → ")[-1] for o in e["options"]}
            values.update(CURRENT=e.get("value", ""), NONE="No available value requested")
            if literal_values:
                explicit = {k: v for k, v in values.items() if k != "NONE" and mentions(clause, v)}
                if len(explicit) == 1:
                    values = explicit
                    part = {**part, "source": part["source"] + "+observed_value"}
            values = dict(sorted(values.items(), key=lambda item: item[1].casefold()))
            selected, _ = named_choices(
                worker, mode, clause, {"value": (f"Which value is requested for {e['label']}?", values)}
            )
            desired = selected["value"]
            option = next((o for o in e["options"] if o["index"] == desired), None)
            if option and str(option["value"]) != str(e.get("value", "")):
                required[("SELECT", desired)] = option["label"]
        elif "checked" in e:
            command = re.sub(r"^(?:and |then |please )+", "", clause, flags=re.I)
            if re.match(r"(?:disable|uncheck|turn\s+off)\b", command, re.I) or (
                literal_values and re.search(r"\b(?:turn|leave|keep)\b.*\b(?:off|disabled)\b", command, re.I)
            ):
                desired = "OFF"
            elif re.match(r"(?:enable|check|turn\s+on)\b", command, re.I) or (
                literal_values and re.search(r"\b(?:turn|leave|keep)\b.*\b(?:on|enabled)\b", command, re.I)
            ):
                desired = "ON"
            else:
                selected, _ = named_choices(
                    worker,
                    mode,
                    clause,
                    {
                        "value": (
                            f"What setting is requested for {e['label']}?",
                            {"ON": "Enabled", "OFF": "Disabled", "KEEP": "Unchanged"},
                        )
                    },
                )
                desired = selected["value"]
            checked = e["checked"] is True or e["checked"] == "true"
            if desired != "KEEP" and checked != (desired == "ON"):
                required[("CLICK", index)] = ("Enable " if desired == "ON" else "Disable ") + e["label"]
        elif is_text:
            known = state.get("completed_text", {}).get(field_identity(e))
            current = str(e.get("value", ""))
            correct = known and known["clause"] == clause and known["value"] == current
            if current and not correct:
                selected, _ = named_choices(
                    worker,
                    mode,
                    clause,
                    {
                        "match": (
                            f"Does {e['label']} = {current!r} match the requested value?",
                            {"yes": "Already correct", "no": "Needs replacement"},
                        )
                    },
                )
                correct = selected["match"] == "yes"
            if not correct:
                required[("TYPE_TEXT", index)] = "Enter " + e["label"]
                desired = "FILL"
        intents.append(
            {
                "element": index,
                "label": e["label"],
                "clause": clause if is_text else None,
                "desired": desired,
                "source": part["source"],
                "request_clause": clause,
                "current": {k: e[k] for k in ("value", "checked") if k in e},
            }
        )
    submits = {
        ("CLICK", e["index"]): e["label"]
        for e in state["elements"]
        if e.get("submits_form") and (e.get("form_key") or e.get("form_id")) in state.get("pending_forms", [])
    }
    if form_safe:
        unfinished_forms = {
            e.get("form_key") or e.get("form_id")
            for e in state["elements"]
            if any(target in {e["index"], *[o["index"] for o in e.get("options", [])]} for _, target in required)
        }
        submits = {
            pair: label
            for pair, label in submits.items()
            if not any(
                e["index"] == pair[1] and (e.get("form_key") or e.get("form_id")) in unfinished_forms
                for e in state["elements"]
            )
        }
    if submits and not any(op == "TYPE_TEXT" for op, _ in required):
        required = submits
    candidates = required or {
        ("CLICK", e["index"]): e["label"]
        for e in state["elements"]
        if "CLICK" in e["operations"] and e["index"] not in excluded
    }
    query, question = goal, "Which requested control should change next?"
    if not required:
        candidates[("DONE", None)] = state["page"].get("heading") or state["page"]["title"]
        for op, label in {
            "SCROLL_DOWN": "Look farther down",
            "SCROLL_UP": "Look farther up",
            "WAIT": "Wait for loading",
            "BLOCKED": "None of these",
        }.items():
            if op in request["questions"]["operation"]["criteria"]:
                candidates[(op, None)] = label
        query, question = destination, "Which page or item is requested?"
        if literal_values:
            exact = {}
            for pair, label in candidates.items():
                if pair[0] not in {"CLICK", "DONE"}:
                    continue
                name = re.sub(r"^(?:open|read|view|preview)\s+", "", label, flags=re.I)
                if name and mentions(destination, name):
                    exact[pair] = label
            if len(exact) == 1:
                candidates = exact
            else:
                # The current page description helps recognize a destination named by topic.
                candidates[("DONE", None)] += " — " + state["page"].get("lead", "")
                if item_descriptions:
                    for e in state["elements"]:
                        pair = ("CLICK", e["index"])
                        if pair in candidates and e.get("description"):
                            candidates[pair] += " — " + e["description"]
    while len(candidates) > 6:
        winners = {}
        items = list(candidates.items())
        for i in range(0, len(items), 6):
            group = dict(items[i : i + 6])
            selected, _ = named_choices(worker, mode, query, {"next_action": (question, group)})
            winners[selected["next_action"]] = group[selected["next_action"]]
        candidates = winners
    selected, native = named_choices(worker, mode, query, {"next_action": (question, candidates)})
    result = action_result(deepcopy(native), {native["answers"]["next_action"]["label"]: selected["next_action"]})
    result["control_intents"] = intents
    return result
