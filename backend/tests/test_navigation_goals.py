import threading

import pytest

from jet_browser.navigation import (
    HOMEPAGE_URLS,
    NavigationGoal,
    homepage_request,
    second_requested_action,
    youtube_request,
)
from jet_browser.routing import LocalRouter


class RaisingWorker:
    def predict(self, model, request):
        raise AssertionError("model")


class LabelWorker:
    def __init__(self, label):
        self.label = label
        self.requests = []

    def predict(self, model, request):
        self.requests.append(request)
        return {"model": model, "answers": {"choice": {
            "valid": True, "label": self.label, "probabilities": None, "confidence": None,
        }}}


class ScriptedWorker:
    def __init__(self, labels):
        self.labels = list(labels)

    def predict(self, model, request):
        label = self.labels.pop(0)
        assert label in request["questions"]["choice"]["criteria"]
        return {"model": model, "answers": {"choice": {
            "valid": True, "label": label, "probabilities": None, "confidence": None,
        }}}


def _browser():
    return {"active_tab_id": "tab-1", "tabs": []}


def _raising_extractor(prompt, recent):
    raise AssertionError("helper")


HOMEPAGES = (
    "Open YouTube",
    "Bring me to YouTube",
    "Go to GitHub",
    "Take me to Wikipedia",
    "Open the Google homepage",
    "please open YouTube",
    "Open GitHub, please",
    "Visit YouTube",
    "Navigate to the GitHub website",
    "Open Wikipedia home page",
)

YOUTUBE = (
    ("Open NASA's YouTube channel", "channel", "NASA"),
    ("Open a NASA playlist on YouTube", "playlist", "NASA"),
    ("Find a YouTube video about Artemis", "video", "Artemis"),
    ("Show YouTube search results for NASA", "search_results", "NASA"),
)


def test_homepage_shortcuts_skip_model_and_helper():
    for prompt in HOMEPAGES:
        provider = homepage_request(prompt)
        assert provider in HOMEPAGE_URLS
        router = LocalRouter(RaisingWorker(), extractor=_raising_extractor)
        route = router.route(prompt, "fake", _browser())
        assert route["operation"] == "open_url"
        assert route["audit"][0]["rule"] == "homepage_request"
        plan = router.prepare(route, prompt, _browser())
        assert plan["url"] == HOMEPAGE_URLS[provider]
        assert plan["navigation_goal"]["kind"] == "homepage"
        assert plan["navigation_goal"]["provider"] == provider
        assert plan["navigation_goal"]["request"] == prompt


def test_stop_still_blocks_a_recognized_homepage():
    stopped = threading.Event()
    stopped.set()
    with pytest.raises(RuntimeError, match="Stopped"):
        LocalRouter(RaisingWorker(), extractor=_raising_extractor).route(
            "Open YouTube", "fake", _browser(), stopped=stopped)


def test_negative_and_compound_prompts_do_not_shortcut():
    assert homepage_request("Don't open YouTube") is None
    assert homepage_request("Open YouTube and summarize the homepage") is None
    assert homepage_request("What is on YouTube?") is None
    assert youtube_request("Don't find a YouTube video about Artemis") is None
    assert youtube_request("Find a YouTube video about Artemis and summarize it") is None
    assert youtube_request("Find a YouTube video about Artemis?") is None
    worker = LabelWorker("search")
    route = LocalRouter(worker, extractor=_raising_extractor).route(
        "Open YouTube and then summarize", "fake", _browser())
    assert route["decision"] == "grok"
    assert route["operation"] == "explain"
    assert worker.requests == []
    assert second_requested_action("Find the Wikipedia page for Ada Lovelace and Charles Babbage") is False


@pytest.mark.parametrize("prompt", [
    "Don't open YouTube",
    "Open youtube.com then tell me a joke",
    "Open github.com and answer my question",
])
def test_search_label_cannot_navigate_a_negated_or_compound_request(prompt):
    worker = LabelWorker("search")
    router = LocalRouter(worker, extractor=_raising_extractor)
    route = router.route(prompt, "fake", _browser())
    assert route["decision"] == "grok"
    assert route["operation"] == "explain"
    assert worker.requests == []
    existing = {"operation": "search", "model": "fake", "audit": []}
    with pytest.raises(ValueError, match="another action"):
        router.prepare(existing, prompt, _browser())
    with pytest.raises(ValueError, match="another action"):
        router.prepare({**existing, "operation": "open_url"}, prompt, _browser())


def test_strict_youtube_keeps_kind_and_subject_when_worker_would_misroute():
    for prompt, kind, subject in YOUTUBE:
        assert youtube_request(prompt) == (kind, subject)
        for label in ("explain", "page_task"):
            worker = LabelWorker(label)
            router = LocalRouter(worker, extractor=_raising_extractor)
            route = router.route(prompt, "fake", _browser())
            plan = router.prepare(route, prompt, _browser())
            assert worker.requests == []
            assert plan["provider"] == "youtube"
            assert plan["navigation_goal"]["kind"] == kind
            assert plan["navigation_goal"]["query"] == subject
            assert f"search_query={subject.replace(' ', '+')}" in plan["url"] or kind == "playlist"
            if kind == "playlist":
                assert plan["query"] == "NASA playlist"
                assert "search_query=NASA+playlist" in plan["url"]
            if kind == "search_results":
                assert plan["outcome"] == "search_results"
            else:
                assert plan["outcome"] == "destination"


def test_wikipedia_search_still_resolves_and_records_article_goal():
    router = LocalRouter(ScriptedWorker(["wikipedia", "destination"]), extractor=lambda prompt, recent: "Elon Musk")
    route = {"id": "route", "model": "fake", "operation": "search", "audit": []}
    plan = router.prepare(route, "go to Elon Musk Wikipedia page", _browser(), ())
    assert plan["outcome"] == "destination"
    assert "go=Go" in plan["url"]
    assert plan["navigation_goal"]["kind"] == "article"
    assert plan["navigation_goal"]["query"] == "Elon Musk"
    assert plan["navigation_goal"]["provider"] == "wikipedia"


def test_youtube_fallback_asks_the_model_and_does_not_trust_a_keyword():
    prompt = "Open the NASA video archive on YouTube"
    router = LocalRouter(
        ScriptedWorker(["youtube", "destination", "other"]),
        extractor=lambda prompt, recent: "NASA video archive",
    )
    route = {"id": "route", "model": "fake", "operation": "search", "audit": []}
    plan = router.prepare(route, prompt, _browser(), ())
    assert plan["navigation_goal"]["kind"] == "other"
    assert plan["query"] == "NASA video archive"
    assert {"rule": "youtube_kind", "answer": "unverified"} in route["audit"]
    results = LocalRouter(
        ScriptedWorker(["youtube", "search_results"]),
        extractor=lambda prompt, recent: "NASA video archive",
    )
    listed = {"id": "route", "model": "fake", "operation": "search", "audit": []}
    plan = results.prepare(listed, prompt, _browser(), ())
    assert plan["navigation_goal"]["kind"] == "search_results"
    assert not any(item.get("rule") == "youtube_kind" for item in listed["audit"])


def test_navigation_goal_rejects_an_unknown_provider():
    with pytest.raises(ValueError, match="provider"):
        NavigationGoal(provider="bing", kind="other", request="search")
    with pytest.raises(ValueError, match="tab_id"):
        NavigationGoal(provider="web", kind="explicit_url", request="https://example.com", tab_id=3)


def test_explicit_url_records_the_supplied_url():
    worker = LabelWorker("open_url")
    router = LocalRouter(worker, extractor=_raising_extractor)
    prompt = "https://example.com/docs"
    route = router.route(prompt, "fake", _browser())
    plan = router.prepare(route, prompt, _browser())
    assert plan["url"] == "https://example.com/docs"
    assert plan["navigation_goal"]["kind"] == "explicit_url"
    assert plan["navigation_goal"]["url"] == "https://example.com/docs"
    assert plan["navigation_goal"]["request"] == prompt
