"""Generic typing demonstrations; no fixture fields or benchmark target values."""

import json
import re

from .model import extractive_value

EXAMPLES = [
    ({"field": "Label", "request": "Enter Autumn draft in Label"}, "Autumn draft"),
    ({"field": "Query", "request": "Search for solar panels"}, "solar panels"),
    ({"field": "Email", "request": "Replace Email with pat@example.test"}, "pat@example.test"),
    ({"field": "Notes", "request": "Do not change Notes"}, "NONE"),
    ({"field": "Address", "request": "Open the Cedar brochure"}, "NONE"),
]


def messages(context, *, version=1):
    result = [
        {
            "role": "system",
            "content": (
                "Extract the value to type into the specified field. Return only the value, without the field name, "
                "command, explanation, or JSON. If the request gives no value for this field, return NONE."
            ),
        }
    ]
    examples = EXAMPLES
    if version == 2:
        examples = EXAMPLES + [
            ({"field": "Keyword", "request": "Search for marigold in Keyword"}, "marigold"),
            ({"field": "Caption", "request": 'Type "Morning, and Evening" into Caption'}, "Morning, and Evening"),
        ]
    for question, answer in examples:
        result += [{"role": "user", "content": json.dumps(question)}, {"role": "assistant", "content": answer}]
    result.append(
        {
            "role": "user",
            "content": json.dumps(
                {"field": context["field"]["label"], "request": context.get("field_request", context["goal"])}
            ),
        }
    )
    return result


def grounded_value(content, goal):
    if content.strip() == "NONE":
        raise ValueError("No input value requested")
    value = extractive_value(content, goal)
    # Preserve the user's spelling/case rather than the helper's capitalization.
    match = re.search(re.escape(value), goal, re.I)
    return match.group() if match else value
