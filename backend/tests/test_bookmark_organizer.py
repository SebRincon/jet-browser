import csv
import io
import threading

import httpx
import pytest

from jet_browser.bookmark_organizer import TAGS, enrich, render_csv, render_html, summarize, tag_item
from jet_browser.workspace import _sanitize_html


class Worker:
    def __init__(self, invalid=False):
        self.lock = threading.RLock()
        self.calls = []
        self.invalid = invalid

    def predict(self, model, request):
        self.calls.append(request)
        return {
            "model": "pinned-test-model",
            "latency_ms": 1,
            "answers": {
                key: {
                    "valid": not self.invalid,
                    "label": "yes" if key in {"mobile", "ai", "research"} else "no",
                    "confidence": 0.9,
                    "probabilities": {"yes": 0.9, "no": 0.1}
                    if key in {"mobile", "ai", "research"}
                    else {"yes": 0.1, "no": 0.9},
                }
                for key in request["questions"]
            },
        }


def item():
    return {
        "id": "item-1",
        "url": "https://x.com/example/status/123",
        "text": "A paper on mobile AI.",
        "author": None,
        "published_at": None,
        "captured_at": 123,
        "truncated": False,
    }


def client(content="A paper investigates mobile AI."):
    def respond(request):
        assert request.url.host == "127.0.0.1"
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    return httpx.Client(transport=httpx.MockTransport(respond))


def test_independent_memberships_can_overlap():
    w = Worker()
    got = tag_item("Paper about mobile AI.", w)
    assert set(got["tags"]) == {"mobile", "ai", "research"}
    assert got["model"] == "pinned-test-model"
    assert all(len(req["questions"]) <= 4 for req in w.calls)
    assert got["model_calls"] == len(w.calls)


def test_invalid_native_answer_is_unknown_not_positive():
    got = tag_item("A paper.", Worker(invalid=True))
    assert got["tags"] == ["other"]
    assert set(got["unknown_tags"]) == set(TAGS) - {"other"}


def test_enrichment_preserves_missing_metadata_and_marks_partial():
    raw = {**item(), "truncated": True}
    got = enrich(raw, Worker(), client())
    assert got["author"] is None and got["published_at"] is None
    assert got["url"] == raw["url"] and got["text"] == raw["text"]
    assert got["summary_scope"] == "visible_excerpt"
    assert got["needs_review"]


def test_blank_summary_or_reasoning_is_not_saved_as_success():
    for output in ["", "<think>thinking</think>"]:
        with pytest.raises(ValueError):
            summarize("A post.", client(output))


def test_empty_text_remains_honest():
    w = Worker()
    got = enrich({**item(), "text": ""}, w, client())
    assert got["needs_review"] and got["tags"] == ["other"]
    assert not w.calls
    assert "No readable" in got["summary"]


def test_unsafe_content_and_links_are_escaped():
    row = {
        **item(),
        "tags": ["mobile", "research", "ai"],
        "summary": "<script>alert(1)</script>",
        "author": "<img src=x onerror=bad>",
        "url": "javascript:alert(1)",
        "needs_review": True,
        "summary_scope": "visible_excerpt",
    }
    html = render_html([row])
    assert "<script>" not in html and 'href="javascript:' not in html
    assert "&lt;script&gt;" in html
    assert "Not observed" in html
    assert "visible" in html.lower() or "partial" in html.lower()


def test_csv_formula_injection_and_multiple_tags():
    row = {
        **item(),
        "tags": ["ai", "research"],
        "summary": '  =HYPERLINK("evil")',
        "author": "@bad",
        "needs_review": False,
        "summary_scope": "captured_post",
    }
    doc = list(csv.DictReader(io.StringIO(render_csv([row]))))[0]
    assert doc["summary"].startswith("'") and doc["author"].startswith("'")
    assert "ai" in doc["tags"] and "research" in doc["tags"]


def test_report_fits_workspace_limit_and_links_survive_preview():
    row = {
        **item(),
        "tags": ["mobile", "web", "desktop", "design", "research", "ai", "tool", "opensource"],
        "summary": "A" * 400,
        "needs_review": False,
        "summary_scope": "captured_post",
    }
    html = render_html([{**row, "id": str(i)} for i in range(100)])
    assert len(html.encode()) <= 200000
    preview = _sanitize_html(html)
    assert 'id="tag-mobile"' in preview
    assert 'href="#tag-mobile"' in preview
