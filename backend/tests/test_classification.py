import asyncio
import threading
from copy import deepcopy

import pytest

from jet_browser.classification import classify_page
from jet_browser.collection_plan import CollectionPlan


def plan(model="lfm_rlcd"):
    return CollectionPlan.from_request(
        {
            "request": "Classify pages",
            "title": "Site",
            "categories": [{"id": "docs", "name": "Docs", "description": "Technical guides"}],
        },
        start_url="https://example.test/",
        tab_id="t",
        model=model,
    )


class Worker:
    def __init__(self, answer=None):
        self.lock = threading.RLock()
        self.calls = []
        self.result = {
            "model": "fixture@1",
            "latency_ms": 1.0,
            "answers": {
                "category": answer or {"valid": True, "label": "docs", "probabilities": None, "confidence": None}
            },
        }

    def predict(self, model, request):
        self.calls.append((model, request))
        return deepcopy(self.result)


def test_label_only_models_preserve_null_confidence():
    w = Worker()
    r = classify_page(plan("qwen4b_semif_shared"), "Technical guide", worker=w)
    assert r["label_id"] == "docs" and r["confidence"] is None
    assert r["model"] == "fixture@1" and r["model_calls"] == 1
    assert "readout" not in w.calls[0][1]


def test_lfm_native_distribution_and_bounded_excerpt():
    w = Worker(
        {"valid": True, "label": "docs", "probabilities": {"docs": 0.7, "needs_review": 0.3}, "confidence": None}
    )
    r = classify_page(plan(), "x" * 3000, worker=w)
    assert r["label_id"] == "docs" and r["excerpt_chars"] == 1200
    assert w.calls[0][1]["readout"] == "lfm_choice_logits"
    assert len(w.calls[0][1]["questions"]["category"]["criteria"]) == 2


def test_invalid_answers_timing_and_empty_are_honest():
    w = Worker({"valid": True, "label": "invented", "probabilities": None, "confidence": None})
    assert classify_page(plan(), "text", worker=w)["label_id"] == "needs_review"
    w = Worker()
    w.result["latency_ms"] = float("nan")
    r = classify_page(plan(), "text", worker=w)
    assert r["label_id"] == "needs_review" and r["reason"] == "invalid_model_timing"
    w = Worker()
    r = classify_page(plan(), " ", worker=w)
    assert r["model_calls"] == 0 and not w.calls


def test_stop_even_on_empty_input_prevents_work():
    stop = threading.Event()
    stop.set()
    w = Worker()
    with pytest.raises(asyncio.CancelledError):
        classify_page(plan(), "", worker=w, stopped=stop)
    assert not w.calls
