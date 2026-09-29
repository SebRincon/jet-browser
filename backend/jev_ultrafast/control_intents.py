"""Ask native models for requested form values, then compare with observed values."""

import re


def read_label(result, key, allowed):
    answer = result.get("answers", {}).get(key, {})
    if not answer.get("valid") or answer.get("label") not in allowed:
        raise ValueError(f"No valid native answer for {key}; no action executed")
    return answer["label"]


def control_intents(worker, mode, request, *, calibrated=False, clause_text=False, classify_clauses=False):
    state = request["state"]
    goal = request["questions"]["operation"]["instructions"]["goal"]
    clauses = [s.strip() for s in re.split(r"[,;]|\s+(?:and|then)\s+", goal, flags=re.I) if s.strip()]
    input_clauses = set(range(len(clauses)))
    if classify_clauses and any("TYPE_TEXT" in e["operations"] for e in state["elements"]):
        classification = {
            "state": "User request: " + goal,
            "questions": {
                f"C{i}": {
                    "type": "choice",
                    "criteria": {
                        "INPUT": "Enter text or search for a location/query.",
                        "CONTROL": "Set a category, filter, checkbox or other option.",
                        "OPEN": "Open or view a named result, item, page or article.",
                        "OTHER": "Another action.",
                    },
                    "instructions": f"What action does this clause request? {clause}",
                }
                for i, clause in enumerate(clauses)
            },
        }
        if mode == "lfm_rlcd":
            classification["readout"] = "lfm_choice_logits"
        kinds = worker.predict(mode, classification)
        input_clauses = {
            i
            for i in range(len(clauses))
            if read_label(kinds, f"C{i}", {"INPUT", "CONTROL", "OPEN", "OTHER"}) == "INPUT"
        }
    questions, controls = {}, {}
    for element in state["elements"]:
        index = element["index"]
        if element.get("options"):
            criteria = {o["index"]: o["label"].split(" → ")[-1] for o in element["options"]}
            criteria["CURRENT"] = "Keep current selection: " + str(element.get("value", ""))
            criteria["KEEP"] = "The user does not request a value for this control."
            instructions = f"Which value does the user request for {element['label']}?"
            kind = "select"
        elif "checked" in element and "CLICK" in element["operations"]:
            criteria = {"ON": "Enabled / checked", "OFF": "Disabled / unchecked", "KEEP": "Not requested"}
            instructions = f"What state does the user request for {element['label']}?"
            kind = "check"
        elif "TYPE_TEXT" in element["operations"]:
            criteria = {
                "FILL": "The field needs a new value from the user's request.",
                "KEEP": "Its value is already correct, or the user did not request it.",
            }
            instructions = (
                f"Field: {element['label']}. Current value: {element.get('value', '')!r}. "
                "Does the user supply a new value for THIS field? Keep it if already correct. "
                "A named result to open is not automatically a value to type."
            )
            if clause_text:
                if len(clauses) > 15:
                    raise ValueError("Goal has more than 15 clauses; use the original policy")
                criteria = {f"C{i}": clause for i, clause in enumerate(clauses) if i in input_clauses}
                criteria["KEEP"] = "No clause asks to fill or search using this field."
                instructions = (
                    f"Field: {element['label']}. Which clause explicitly supplies its search/input value? "
                    "Ignore clauses that only ask to open a result or change other controls."
                )
            kind = "text"
        else:
            continue
        key = "control_" + index
        questions[key] = {"type": "choice", "criteria": criteria, "instructions": instructions}
        controls[key] = (kind, element)
    if not questions:
        return set(), set(), []
    native_request = {"state": "User request: " + goal, "questions": questions}
    if mode == "lfm_rlcd":
        native_request["readout"] = "lfm_choice_calibrated" if calibrated else "lfm_choice_logits"
    result = worker.predict(mode, native_request)
    required, excluded, intents = set(), set(), []
    for key, (kind, element) in controls.items():
        answer = result["answers"][key]
        choice = answer.get("label")
        if not answer.get("valid") or choice not in questions[key]["criteria"]:
            raise ValueError("Requested form value could not be determined")
        index = element["index"]
        clause = None
        if kind == "select":
            excluded.update(("SELECT", o["index"]) for o in element["options"])
            selected = next((o for o in element["options"] if o["index"] == choice), None)
            if selected and str(selected["value"]) != str(element.get("value", "")):
                required.add(("SELECT", choice))
        elif kind == "check":
            excluded.add(("CLICK", index))
            checked = element["checked"] is True or element["checked"] == "true"
            if choice != "KEEP" and (choice == "ON") != checked:
                required.add(("CLICK", index))
        else:
            excluded.add(("TYPE_TEXT", index))
            needs_text = choice == "FILL"
            if clause_text and choice != "KEEP":
                clause = clauses[int(choice[1:])]
                needs_text = not element.get("value")
                if not needs_text:
                    match = worker.predict(
                        mode,
                        {
                            **native_request,
                            "state": clause,
                            "questions": {
                                "matches": {
                                    "type": "choice",
                                    "criteria": {"yes": "Already correct", "no": "Needs replacement"},
                                    "instructions": (
                                        f"Field {element['label']} currently contains {element['value']!r}. "
                                        "Does it match the value requested in the clause?"
                                    ),
                                }
                            },
                        },
                    )
                    needs_text = read_label(match, "matches", {"yes", "no"}) == "no"
            if needs_text:
                required.add(("TYPE_TEXT", index))
            elif classify_clauses and element.get("role") != "combobox" and "expanded" not in element:
                excluded.add(("CLICK", index))
        intents.append(
            {
                "element": index,
                "label": element["label"],
                "desired": choice,
                "clause": clause,
                "current": {k: element[k] for k in ("value", "checked") if k in element},
            }
        )
    return required, excluded, intents
