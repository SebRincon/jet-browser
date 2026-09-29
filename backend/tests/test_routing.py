import threading

import pytest

from jet_browser.routing import LocalRouter, grounded_text


class FakeWorker:
    def __init__(self, label):
        self.label = label
        self.requests = []

    def predict(self, model, request):
        self.requests.append(request)
        label = 'act' if 'act' in request['questions']['choice']['criteria'] else self.label
        return {"model": model, "answers": {"choice": {
            "valid": True, "label": label, "probabilities": None, "confidence": None,
        }}}


def test_route_uses_native_selected_label_and_retains_audit():
    worker = FakeWorker('search')
    route = LocalRouter(worker).route('Find a Wikipedia page', 'lfm_rlcd', {'tabs': []})
    assert route['decision'] == 'local'
    assert route['operation'] == 'search'
    assert route['grok_calls'] == 0
    assert route['audit'][0]['answer'] == 'search'
    assert worker.requests[0]['readout'] == 'lfm_choice_logits'


def test_unsupported_native_label_cannot_dispatch():
    with pytest.raises(ValueError):
        LocalRouter(FakeWorker('execute_js')).route('hello', 'laya_mlx', {'tabs': []})


def test_stop_prevents_inference():
    stopped = threading.Event()
    stopped.set()
    worker = FakeWorker('search')
    with pytest.raises(RuntimeError, match='Stopped'):
        LocalRouter(worker).route('Find a page', 'lfm_rlcd', {'tabs': []}, stopped=stopped)
    assert worker.requests == []


def test_bare_assent_uses_full_conversation_instead_of_guessing_a_page_action():
    router = LocalRouter(FakeWorker('page_task'))
    for prompt in ('Yes, do it.', 'Sure, go ahead', 'Okay'):
        result = router.route(prompt, 'fake', {}, ['What can you do?'])
        assert result['decision'] == 'grok'
        assert result['audit'][-1]['rule'] == 'confirmation_requires_full_history'


def test_query_separator_normalization_recovers_only_verbatim_user_words():
    assert grounded_text('python-docs', ['open the official Python docs']) == 'Python docs'
    with pytest.raises(ValueError, match='absent'):
        grounded_text('Python documentation', ['open the official Python docs'])
