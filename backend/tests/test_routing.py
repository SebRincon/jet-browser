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


class TabWorker:
    """Picks the tab whose title contains `wanted`, or the escape; records option counts."""

    def __init__(self, wanted):
        self.wanted = wanted
        self.sizes = []

    def predict(self, model, request):
        criteria = request['questions']['choice']['criteria']
        self.sizes.append(len(criteria))
        label = next((key for key, text in criteria.items() if self.wanted and self.wanted in text), 'UNRESOLVED')
        return {"model": model, "answers": {"choice": {
            "valid": True, "label": label, "probabilities": None, "confidence": None}}}


def tabs(count):
    return {'active_tab_id': 't0', 'tabs': [
        {'id': f't{n}', 'title': f'Page {n:03d}', 'url': f'https://example.com/{n}'} for n in range(count)]}


@pytest.mark.parametrize('count,wanted', [(40, 'Page 037'), (15, 'Page 014'), (240, 'Page 239')])
def test_tab_selection_reaches_late_tabs_within_the_option_limit(count, wanted):
    worker = TabWorker(wanted)
    route = {'operation': 'switch_tab', 'model': 'fake', 'audit': []}
    plan = LocalRouter(worker).prepare(route, 'Switch to ' + wanted, tabs(count))
    assert plan['tab_id'] == 't' + str(int(wanted[-3:]))
    assert max(worker.sizes) <= LocalRouter.MAX_CHOICE_OPTIONS
    summary = route['audit'][-1]
    assert summary['rule'] == 'bounded_tab_selection' and summary['candidates'] == count


def test_tab_selection_final_round_decides_between_chunk_winners():
    class Duplicates(TabWorker):
        def predict(self, model, request):
            criteria = request['questions']['choice']['criteria']
            self.sizes.append(len(criteria))
            options = [key for key, text in criteria.items() if 'Docs' in text]
            # Each chunk sees one plausible "Docs" tab; the final round sees both and prefers t30.
            label = 't30' if 't30' in options and len(options) > 1 else (options[0] if options else 'UNRESOLVED')
            return {"model": model, "answers": {"choice": {
                "valid": True, "label": label, "probabilities": None, "confidence": None}}}

    browser = tabs(40)
    browser['tabs'][3]['title'] = 'Docs (old)'
    browser['tabs'][30]['title'] = 'Docs'
    worker = Duplicates(None)
    route = {'operation': 'switch_tab', 'model': 'fake', 'audit': []}
    plan = LocalRouter(worker).prepare(route, 'Switch to the docs tab', browser)
    assert plan['tab_id'] == 't30'
    assert route['audit'][-1]['rounds'] == 2 and worker.sizes[-1] == 3


def test_no_matching_tab_in_any_chunk_stays_unresolved():
    worker = TabWorker(None)
    route = {'operation': 'close_tab', 'model': 'fake', 'audit': []}
    with pytest.raises(ValueError, match='ambiguous'):
        LocalRouter(worker).prepare(route, 'Close the recipe tab', tabs(33))
    assert worker.sizes == [16, 16, 4]
