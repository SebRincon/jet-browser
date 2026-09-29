"""Experimental short semantic choices over observed controls and destinations."""

import re
from copy import deepcopy

from .control_intents import read_label


def named_choices(worker, mode, state, questions):
    """Use meaningful native labels; retain a reversible map to observed identities."""
    definitions, maps = {}, {}
    for key, (instruction, options) in questions.items():
        aliases = {}
        for identity, description in options.items():
            name = str(description)
            suffix = 2
            while name in aliases:
                name = f"{description} (alternative {suffix})"
                suffix += 1
            aliases[name] = identity
        maps[key] = aliases
        definitions[key] = {"type": "choice", "instructions": instruction, "criteria": dict.fromkeys(aliases)}
    request = {"state": state, "questions": definitions}
    if mode == "lfm_rlcd":
        request["readout"] = "lfm_choice_logits"
    result = worker.predict(mode, request)
    selected = {key: maps[key][read_label(result, key, maps[key])] for key in definitions}
    return selected, result


def predict_semantic(worker, mode, request, *, gate_text=False, route=False):
    from .policy_profiles import action_result

    state = request["state"]
    goal = request["questions"]["operation"]["instructions"]["goal"]
    clauses = [s.strip() for s in re.split(r"[,;]|\s+(?:and|then)\s+", goal, flags=re.I) if s.strip()]
    if len(clauses) > 15:
        raise ValueError("Semantic field choice supports at most fifteen goal clauses")
    input_clauses = set(range(len(clauses)))
    routed = {}
    if route:
        fields = {
            e["index"]: e["label"]
            for e in state["elements"]
            if e.get("options") or "checked" in e or "TYPE_TEXT" in e["operations"]
        }
        if fields:
            for i, clause in enumerate(clauses):
                selected, _ = named_choices(
                    worker,
                    mode,
                    clause,
                    {
                        "route": (
                            "Which control does this instruction refer to?",
                            {**fields, "open": "Open a page or item", "none": "None of these"},
                        )
                    },
                )
                routed.setdefault(selected["route"], []).append(i)
    if gate_text and any("TYPE_TEXT" in e["operations"] for e in state["elements"]):
        input_clauses = set()
        for i, clause in enumerate(clauses):
            selected, _ = named_choices(
                worker,
                mode,
                clause,
                {
                    "intent": (
                        "What action is requested?",
                        {
                            "input": "Type text or search",
                            "control": "Change a filter or setting",
                            "open": "Open a page or result",
                            "other": "Keep things unchanged",
                        },
                    )
                },
            )
            if selected["intent"] == "input":
                input_clauses.add(i)
    questions, controls = {}, {}
    for e in state["elements"]:
        index = e["index"]
        if e.get("options"):
            options = {o["index"]: o["label"].split(" → ")[-1] for o in e["options"]}
            options.update(CURRENT=e.get("value", ""), KEEP="Not specified")
            instruction = f"Which {e['label']} value is requested?"
            kind = "select"
        elif "checked" in e:
            options = {"ON": "Enabled", "OFF": "Disabled", "KEEP": "Not specified"}
            instruction = f"What setting is requested for {e['label']}?"
            kind = "check"
        elif "TYPE_TEXT" in e["operations"]:
            allowed = routed.get(index, []) if route else input_clauses
            options = {f"C{i}": clause for i, clause in enumerate(clauses) if i in allowed}
            options["KEEP"] = "No text input requested"
            instruction = f"Which clause asks to type or search in the {e['label']} field?"
            kind = "text"
        else:
            continue
        key = "control_" + index
        questions[key] = (instruction, options)
        controls[key] = (kind, e)
    selections, native = {}, {}
    if route:
        for key, definition in questions.items():
            kind, element = controls[key]
            matching = routed.get(element["index"], [])
            evidence = "\n".join(clauses[i] for i in matching) if matching else goal
            answer, native = named_choices(worker, mode, evidence, {key: definition})
            selections.update(answer)
    elif questions:
        selections, native = named_choices(worker, mode, goal, questions)
    required, excluded, intents = {}, set(), []
    for key, (kind, e) in controls.items():
        index, desired = e["index"], selections[key]
        clause = None
        if kind == "select":
            selected = next((o for o in e["options"] if o["index"] == desired), None)
            if selected and str(selected["value"]) != str(e.get("value", "")):
                required[("SELECT", desired)] = selected["label"]
        elif kind == "check":
            excluded.add(index)
            checked = e["checked"] is True or e["checked"] == "true"
            if desired != "KEEP" and checked != (desired == "ON"):
                required[("CLICK", index)] = ("Enable " if desired == "ON" else "Disable ") + e["label"]
        else:
            excluded.add(index)
            if desired != "KEEP":
                clause = clauses[int(desired[1:])]
                needs_text = not e.get("value")
                if not needs_text:
                    matches, native = named_choices(
                        worker,
                        mode,
                        clause,
                        {
                            "match": (
                                f"Is {e['label']} = {e['value']!r} the requested input?",
                                {"yes": "Correct value", "no": "Different value"},
                            )
                        },
                    )
                    needs_text = matches["match"] == "no"
                if needs_text:
                    required[("TYPE_TEXT", index)] = "Enter " + e["label"]
        intents.append(
            {
                "element": index,
                "label": e["label"],
                "desired": desired,
                "clause": clause,
                "current": {k: e[k] for k in ("value", "checked") if k in e},
            }
        )
    if not required:
        required = {
            ("CLICK", e["index"]): e["label"]
            for e in state["elements"]
            if e.get("submits_form") and e.get("form_id") in state.get("pending_forms", [])
        }
    candidates = required or {
        ("CLICK", e["index"]): e["label"]
        for e in state["elements"]
        if "CLICK" in e["operations"] and e["index"] not in excluded and not e.get("submits_form")
    }
    instruction = "Which requested control should be changed next?"
    if not required:
        page = state["page"]
        candidates[("DONE", None)] = page.get("heading") or page["title"]
        for operation in ("SCROLL_DOWN", "SCROLL_UP", "WAIT", "BLOCKED"):
            if operation in request["questions"]["operation"]["criteria"]:
                candidates[(operation, None)] = {
                    "SCROLL_DOWN": "Look farther down the page",
                    "SCROLL_UP": "Look farther up the page",
                    "WAIT": "Wait for loading",
                    "BLOCKED": "None of these",
                }[operation]
        instruction = "Which page or item does the user want to open?"
    # Compare every candidate; do not merge probabilities from separate heads.
    while len(candidates) > 6:
        winners = {}
        items = list(candidates.items())
        for i in range(0, len(items), 6):
            group = dict(items[i : i + 6])
            selected, native = named_choices(worker, mode, goal, {"next_action": (instruction, group)})
            winner = selected["next_action"]
            winners[winner] = group[winner]
        candidates = winners
    selected, native = named_choices(worker, mode, goal, {"next_action": (instruction, candidates)})
    result = deepcopy(native)
    label = result["answers"]["next_action"]["label"]
    result = action_result(result, {label: selected["next_action"]})
    result["control_intents"] = intents
    return result
