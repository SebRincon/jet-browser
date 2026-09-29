"""Explicit navigation goals. Strict homepage and YouTube grammars never call a model."""

import re
from dataclasses import asdict, dataclass
from typing import Optional

KINDS = frozenset({
    "homepage", "search_results", "article", "video", "channel",
    "playlist", "explicit_url", "other",
})
PROVIDERS = frozenset({"youtube", "wikipedia", "github", "google", "web"})

HOMEPAGE_URLS = {
    "youtube": "https://www.youtube.com/",
    "wikipedia": "https://www.wikipedia.org/",
    "github": "https://github.com/",
    "google": "https://www.google.com/",
}

_FOLLOWUP = (
    "tell|answer|find|search|open|navigate|watch|subscribe|summarize|summarise|"
    "compare|fill|click|explain|research|discuss|write|translate|download|describe|joke"
)
# Coordinator must introduce another imperative. "Ada and Charles" stays a subject.
_SECOND_ACTION = re.compile(
    rf"\b(?:and(?:\s+then)?|then)\s+(?:(?:please|just)\s+)?(?:{_FOLLOWUP})\w*\b",
    re.I,
)
_NAV_VERB = r"open|go|bring|take|visit|navigate|find|search|show"
_HOME = re.compile(
    r"(?:please[, ]+)?"
    r"(?:open|bring me to|go to|take me to|visit|navigate to)"
    r"(?: the)? (youtube|wikipedia|github|google)"
    r"(?: (?:homepage|home page|website))?"
    r"(?:[, ]+please)?",
    re.I,
)
_YT = (
    ("channel", re.compile(
        r"(?:please[, ]+)?(?:open|go to|show(?: me)?|find|bring me to|take me to) "
        r"(?:the |a |an )?(.+?)(?:['’]s)? youtube channel(?:[, ]+please)?", re.I)),
    ("playlist", re.compile(
        r"(?:please[, ]+)?(?:open|find|show(?: me)?) "
        r"(?:the |a |an )?(.+?) playlist on youtube(?:[, ]+please)?", re.I)),
    ("playlist", re.compile(
        r"(?:please[, ]+)?(?:open|find|show(?: me)?) "
        r"(?:the |a |an )?youtube playlist (?:about|for|on) (.+?)(?:[, ]+please)?", re.I)),
    ("video", re.compile(
        r"(?:please[, ]+)?(?:find|open|show(?: me)?) "
        r"(?:a |the )?youtube video (?:about|on|for) (.+?)(?:[, ]+please)?", re.I)),
    ("search_results", re.compile(
        r"(?:please[, ]+)?(?:show|find|open) youtube search results for (.+?)(?:[, ]+please)?", re.I)),
)


def _flat(prompt):
    return re.sub(r"\s+", " ", prompt).strip().rstrip(".!")


def _subject(value):
    value = value.strip().strip("\"'`").strip()
    value = re.sub(r"['’]s$", "", value).strip()
    if not value or re.search(r"\b(?:and|then)\b|[?]", value, re.I):
        return None
    return value


@dataclass(frozen=True)
class NavigationGoal:
    provider: str
    kind: str
    request: str
    query: str = ""
    tab_id: Optional[str] = None
    url: Optional[str] = None

    def __post_init__(self):
        if self.provider not in PROVIDERS:
            raise ValueError("navigation provider is not supported")
        if self.kind not in KINDS:
            raise ValueError("navigation kind is not supported")
        if not isinstance(self.request, str) or not self.request.strip():
            raise ValueError("navigation request is required")
        if not isinstance(self.query, str):
            raise ValueError("navigation query must be text")
        if self.tab_id is not None and not isinstance(self.tab_id, str):
            raise ValueError("navigation tab_id must be text")
        if self.url is not None and not isinstance(self.url, str):
            raise ValueError("navigation url must be text")

    def to_dict(self):
        return asdict(self)


def homepage_request(prompt):
    """Registry provider for one anchored homepage request, else None."""
    text = _flat(prompt)
    if "?" in text or re.search(r"\b(?:don't|do not|never|not|research|why|what|how)\b", text, re.I):
        return None
    if re.search(r"\b(?:and|then)\b", text, re.I):
        return None
    match = re.fullmatch(_HOME, text)
    if not match:
        return None
    return match.group(1).casefold()


def youtube_request(prompt):
    """(kind, verbatim subject) for one simple YouTube resource request, else None."""
    text = _flat(prompt)
    if "?" in prompt or re.search(r"\b(?:don't|do not|never)\b", text, re.I):
        return None
    if _SECOND_ACTION.search(text) or re.search(r"\b(?:and|then)\b", text, re.I):
        return None
    for kind, pattern in _YT:
        match = re.fullmatch(pattern, text)
        if not match:
            continue
        subject = _subject(match.group(1))
        if subject and subject.casefold() in prompt.casefold():
            return kind, subject
    return None


def second_requested_action(prompt):
    """True when a navigation line also asks for another action."""
    return _SECOND_ACTION.search(_flat(prompt)) is not None


def negated_navigation(prompt):
    """A negated open/go/find/show request. An explicit results request stays routable."""
    text = _flat(prompt)
    if re.search(r"\b(?:don't|do not|never)\b", text, re.I) is None:
        return False
    if re.search(rf"\b(?:{_NAV_VERB})\b", text, re.I) is None:
        return False
    if re.search(r"\b(?:show|display|list)\b.{0,80}\bsearch results\b", text, re.I):
        return False
    return True


def unsupported_navigation(prompt):
    return negated_navigation(prompt) or second_requested_action(prompt)


def youtube_search_query(kind, subject):
    """URL query. Playlist discovery adds the word playlist without replacing the subject."""
    if kind == "playlist" and "playlist" not in subject.casefold():
        return subject + " playlist"
    return subject


def goal_kind_for_search(provider, outcome):
    if provider == "wikipedia" and outcome == "destination":
        return "article"
    if outcome == "search_results":
        return "search_results"
    return "other"
