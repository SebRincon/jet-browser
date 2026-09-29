"""Conservative handling of explicit commands; ambiguous language stays model work."""

import re

INPUT = {"enter", "type", "fill", "replace", "search", "find"}
OPEN = {"open", "read", "view", "visit", "preview", "navigate", "show"}
SETTING = {"set", "select", "choose", "use", "enable", "disable", "turn", "check", "uncheck", "keep", "leave"}
VERBS = "|".join(sorted(INPUT | OPEN | SETTING | {"do", "without"}))


def quoted_mask(text):
    mask, quote = [], None
    for i, char in enumerate(text):
        escaped = i > 0 and text[i - 1] == "\\"
        apostrophe = char == "'" and i > 0 and i + 1 < len(text) and text[i - 1].isalnum() and text[i + 1].isalnum()
        if char in {'"', "'"} and not escaped and not apostrophe:
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
        mask.append(bool(quote) or char in {'"', "'"} and not apostrophe)
    return mask


def split_instructions(goal):
    mask = quoted_mask(goal)
    pattern = rf"(?:[;,.]\s*|\s+(?:and|then)\s+)(?=(?:and\s+|then\s+|please\s+)*(?:{VERBS})\b)"
    chunks, start = [], 0
    for match in re.finditer(pattern, goal, re.I):
        if not any(mask[match.start() : match.end()]):
            chunks.append(goal[start : match.start()].strip())
            start = match.end()
    chunks.append(goal[start:].strip())
    return [x for x in chunks if x]


def kind(clause):
    prefix = re.sub(r"^(?:(?:please|and|then)\s+)+", "", clause.strip(), flags=re.I)
    if re.match(
        r"(?:do not|don't|without)\s+(?:type|typing|enter|entering|fill|filling|change|changing)\b", prefix, re.I
    ):
        return "keep"
    verb = prefix.split(maxsplit=1)[0].casefold().rstrip(".,:;") if prefix else ""
    if verb in {"keep", "leave"} and re.search(r"\b(unchanged|current|existing)\b", prefix, re.I):
        return "keep"
    return "input" if verb in INPUT else "open" if verb in OPEN else "setting" if verb in SETTING else "unknown"


def mentions(text, phrase):
    mask = quoted_mask(text)
    unquoted = "".join(" " if hidden else char for char, hidden in zip(text, mask))
    pattern = r"(?<!\w)" + r"\s+".join(re.escape(x) for x in phrase.split()) + r"(?!\w)"
    return bool(phrase.strip() and re.search(pattern, unquoted, re.I))


def field_identity(element):
    return str(element.get("form_key") or element.get("form_id") or element["index"]) + ":" + element["label"]
