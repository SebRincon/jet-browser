import asyncio

import pytest

from jet_browser.conversation import assess_navigation, execute_local
from jet_browser.routing import LocalRouter
from jet_browser.service import Service


class ScriptedWorker:
    def __init__(self, labels):
        self.labels = list(labels)
        self.requests = []

    def predict(self, model, request):
        self.requests.append(request)
        criteria = request['questions']['choice']['criteria']
        label = self.labels.pop(0)
        assert label in criteria
        return {'model': model, 'answers': {'choice': {
            'valid': True, 'label': label, 'probabilities': None, 'confidence': None,
        }}}


def _route():
    return {'id': 'route-intent', 'model': 'fake', 'operation': 'search', 'audit': [], 'grok_calls': 0}


def test_explicit_results_request_avoids_direct_article_jump():
    # A worker that would insist on destination must not override an explicit results request,
    # even when the open tab is already the article.
    worker = ScriptedWorker(['wikipedia', 'destination'])
    router = LocalRouter(worker, extractor=lambda prompt, recent: 'Elon Musk')
    article = {'id': 'tab-a', 'url': 'https://en.wikipedia.org/wiki/Elon_Musk', 'title': 'Elon Musk'}
    plan = router.prepare(
        _route(), 'Show Wikipedia search results for Elon Musk',
        {'active_tab_id': 'tab-a', 'tabs': [article]}, (),
    )
    assert plan['outcome'] == 'search_results'
    assert 'go=Go' not in plan['url']
    assert 'fulltext=1' in plan['url']
    assert 'Special%3ASearch' in plan['url'] or 'Special:Search' in plan['url']
    questions = [item['questions']['choice']['instructions'] for item in worker.requests]
    assert not any('search results page' in question for question in questions)


def test_coordinated_wording_is_not_forced_by_the_fast_path():
    worker = ScriptedWorker(['wikipedia', 'search_results', 'wikipedia', 'destination'])
    router = LocalRouter(worker, extractor=lambda prompt, recent: 'Elon Musk' if 'Elon Musk' in prompt else 'search results')
    browser = {'active_tab_id': 'tab-a', 'tabs': [
        {'id': 'tab-a', 'url': 'https://en.wikipedia.org/wiki/Elon_Musk', 'title': 'Elon Musk'},
    ]}
    listed = router.prepare(
        _route(), "Don't open the article, show me search results for Elon Musk", browser, (),
    )
    assert listed['outcome'] == 'search_results'
    assert 'fulltext=1' in listed['url']
    asked = [item['questions']['choice']['instructions'] for item in worker.requests]
    assert any('Ignore any page' in question for question in asked)
    article = router.prepare(
        _route(), 'Open the article about search results on Wikipedia', browser, (),
    )
    assert article['outcome'] == 'destination'
    assert 'go=Go' in article['url'] and 'fulltext=1' not in article['url']


def test_destination_request_keeps_article_lookup():
    worker = ScriptedWorker(['wikipedia', 'destination'])
    router = LocalRouter(worker, extractor=lambda prompt, recent: 'Elon Musk')
    plan = router.prepare(
        _route(), 'go to Elon Musk Wikipedia page',
        {'active_tab_id': 'tab-a', 'tabs': []}, (),
    )
    assert plan['outcome'] == 'destination'
    assert 'go=Go' in plan['url']


def test_search_results_and_wrong_targets_do_not_prove_the_article():
    prompt = 'go to Elon Musk Wikipedia page'
    results = {
        'url': 'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Elon+Musk',
        'title': 'Elon Musk - Search results - Wikipedia', 'heading': 'Search results',
        'lead': 'Elon Musk', 'text': 'Result snippet mentioning Elon Musk',
    }
    assert assess_navigation(results, intent='destination', prompt=prompt, recent=(), query='Elon Musk',
                             provider='wikipedia') == 'search_page'
    wrong = {
        'url': 'https://en.wikipedia.org/wiki/Ada_Lovelace',
        'title': 'Ada Lovelace - Wikipedia', 'heading': 'Ada Lovelace', 'lead': 'Mathematician', 'text': 'Ada',
    }
    assert assess_navigation(wrong, intent='destination', prompt=prompt, recent=(), query='Elon Musk',
                             provider='wikipedia') == 'wrong_topic'
    shortened = {
        'url': 'https://en.wikipedia.org/wiki/Musk',
        'title': 'Musk - Wikipedia', 'heading': 'Musk', 'lead': 'A substance', 'text': 'Musk',
    }
    assert assess_navigation(shortened, intent='destination', prompt=prompt, recent=(), query='Musk',
                             provider='wikipedia') == 'shortened_query'
    lookalike = {
        'url': 'https://en.wikipedia.org.evil.test/wiki/Elon_Musk',
        'title': 'Elon Musk - Wikipedia', 'heading': 'Elon Musk', 'lead': 'Businessman', 'text': 'Elon Musk',
    }
    assert assess_navigation(lookalike, intent='destination', prompt=prompt, recent=(), query='Elon Musk',
                             provider='wikipedia') == 'lookalike_host'
    article = {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk',
        'title': 'Elon Musk - Wikipedia', 'heading': 'Elon Musk', 'lead': 'Businessman', 'text': 'Elon Musk',
    }
    assert assess_navigation(article, intent='destination', prompt=prompt, recent=(), query='Musk',
                             provider='wikipedia') == 'wikipedia_article'
    missing = {
        'url': 'https://en.wikipedia.org/wiki/Elon_musks',
        'title': 'Elon musks - Wikipedia', 'heading': 'Elon musks',
        'lead': 'Wikipedia does not have an article with this exact name.',
        'text': 'Wikipedia does not have an article with this exact name. Search for Elon musks in Wikipedia.',
        'missing_article': True,
    }
    spelled = 'go to Elon musks wiki page'
    assert assess_navigation(missing, intent='destination', prompt=spelled, recent=(), query='Elon musks',
                             provider='wikipedia') == 'missing_article'
    without_flag = {key: value for key, value in missing.items() if key != 'missing_article'}
    assert assess_navigation(without_flag, intent='destination', prompt=spelled, recent=(), query='Elon musks',
                             provider='wikipedia') == 'missing_article'
    present = {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk',
        'title': 'Elon Musk - Wikipedia', 'heading': 'Elon Musk', 'lead': 'Businessman', 'text': 'Elon Musk',
        'missing_article': False,
    }
    assert assess_navigation(present, intent='destination', prompt='go to Elon Musk wiki page', recent=(),
                             query='Elon Musk', provider='wikipedia') == 'wikipedia_article'
    shown = {
        'url': 'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Elon+Musk',
        'title': 'Elon Musk - Search results', 'heading': '', 'lead': '', 'text': 'results',
    }
    assert assess_navigation(shown, intent='search_results', prompt='show Wikipedia search results for Elon Musk',
                             recent=(), query='Elon Musk', provider='wikipedia') == 'search_results'
    encoded = {**shown, 'url': 'https://en.wikipedia.org/w/index.php?title=Special%3ASearch&search=Elon+Musk'}
    assert assess_navigation(encoded, intent='search_results', prompt='show Wikipedia search results for Elon Musk',
                             recent=(), query='Elon Musk', provider='wikipedia') == 'search_results'
    assert assess_navigation(encoded, intent='search_results', prompt='show Wikipedia search results for Elon Musk',
                             recent=(), query='Ada Lovelace', provider='wikipedia') == 'not_results'
    evil = {**encoded, 'url': 'https://en.wikipedia.org.evil.test/w/index.php?title=Special%3ASearch&search=Elon+Musk'}
    assert assess_navigation(evil, intent='search_results', prompt='show Wikipedia search results for Elon Musk',
                             recent=(), query='Elon Musk', provider='wikipedia') == 'lookalike_host'
    assert assess_navigation(
        {'url': 'https://notgoogle.com/search?q=Elon+Musk', 'title': 'Google', 'heading': '', 'lead': '', 'text': ''},
        intent='search_results', prompt='search Elon Musk', recent=(), query='Elon Musk', provider='web',
    ) == 'not_results'
    assert assess_navigation(
        {'url': 'https://notyoutube.com/results?search_query=Elon+Musk', 'title': 'YouTube', 'heading': '',
         'lead': '', 'text': ''},
        intent='search_results', prompt='search Elon Musk', recent=(), query='Elon Musk', provider='youtube',
    ) == 'not_results'
    stub = {
        'url': 'https://en.wikipedia.org/w/index.php?title=Quantum_physics&redirect=no',
        'title': 'Quantum physics - Wikipedia', 'heading': 'Quantum physics',
        'lead': 'Redirect page', 'text': 'Redirect page',
    }
    assert assess_navigation(
        stub, intent='destination', prompt='please open the wikipedia entry about quantum physics now',
        recent=('Elon Musk',), query='quantum physics extra', provider='wikipedia',
    ) == 'redirect_stub'
    tokyo = {
        'url': 'https://en.wikipedia.org/wiki/%E6%9D%B1%E4%BA%AC',
        'title': '東京 - Wikipedia', 'heading': '東京', 'lead': '首都', 'text': '東京',
    }
    assert assess_navigation(tokyo, intent='destination', prompt='open 東京 wikipedia page', recent=(),
                             query='東京', provider='wikipedia') == 'wikipedia_article'
    pronoun = {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk',
        'title': 'Elon Musk - Wikipedia', 'heading': 'Elon Musk', 'lead': 'Businessman', 'text': 'Elon Musk',
    }
    possessive = {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk',
        'title': 'Elon Musk - Wikipedia', 'heading': 'Elon Musk', 'lead': 'Businessman', 'text': 'Elon Musk',
    }
    assert assess_navigation(possessive, intent='destination', prompt='open elon musks wikipedia page',
                             recent=(), query='elon musks', provider='wikipedia') == 'wrong_topic'
    assert assess_navigation(pronoun, intent='destination', prompt='open that page',
                             recent=('go to Elon Musk Wikipedia page',), query='Elon Musk',
                             provider='wikipedia') == 'wrong_topic'
    prompt_musk = 'go to elon musk wiki page'
    given = {
        'url': 'https://en.wikipedia.org/wiki/Elon', 'title': 'Elon - Wikipedia', 'heading': 'Elon',
        'lead': 'A male given name', 'text': 'A male given name',
    }
    assert assess_navigation(given, intent='destination', prompt=prompt_musk, recent=(), query='elon',
                             provider='wikipedia') == 'shortened_query'
    family = {
        'url': 'https://en.wikipedia.org/wiki/Musk', 'title': 'Musk - Wikipedia', 'heading': 'Musk',
        'lead': 'A substance', 'text': 'A substance',
    }
    assert assess_navigation(family, intent='destination', prompt=prompt_musk, recent=(), query='musk',
                             provider='wikipedia') == 'shortened_query'
    canonical = {
        'url': 'https://en.wikipedia.org/wiki/Quantum_mechanics',
        'title': 'Quantum mechanics - Wikipedia', 'heading': 'Quantum mechanics',
        'lead': 'Fundamental theory in physics',
        'text': 'Redirected from Quantum physics. Quantum mechanics is a fundamental theory that describes the physical properties of nature at the scale of atoms and subatomic particles.',
    }
    assert assess_navigation(
        canonical, intent='destination', prompt='go to quantum mechanics wikipedia page', recent=(),
        query='quantum mechanics', provider='wikipedia',
    ) == 'wikipedia_article'
    assert assess_navigation(
        {'url': 'https://en.wikipedia.org/w/index.php?title=Quantum_physics&redirect=no',
         'title': 'Quantum physics', 'heading': 'Quantum physics', 'lead': 'Redirect page', 'text': 'Redirect page'},
        intent='destination', prompt='go to quantum physics wikipedia page', recent=(),
        query='quantum physics', provider='wikipedia',
    ) == 'redirect_stub'
    partial_results = {
        'url': 'https://en.wikipedia.org/w/index.php?title=Special%3ASearch&search=elon',
        'title': 'Search results', 'heading': '', 'lead': '', 'text': '',
    }
    assert assess_navigation(partial_results, intent='search_results', prompt=prompt_musk, recent=(),
                             query='elon', provider='wikipedia') == 'incomplete_query'
    assert assess_navigation(
        {'url': 'https://www.google.com/search-fiction?q=Elon+Musk', 'title': 'Fiction', 'heading': '',
         'lead': '', 'text': ''},
        intent='search_results', prompt='search Elon Musk', recent=(), query='Elon Musk', provider='web',
    ) == 'not_results'


class ChoosingRouter:
    """Finite fake choices. Records the state the outcome check actually received."""

    def __init__(self, labels):
        self.labels = list(labels)
        self.states = []

    def choose(self, model, state, question, criteria, stopped=None):
        self.states.append(state)
        if stopped and stopped.is_set():
            raise RuntimeError('Stopped before local inference')
        label = self.labels.pop(0)
        assert label in criteria
        return label, {
            'question': question, 'answer': label, 'probabilities': {}, 'confidence': None,
            'model': model, 'inference_ms': 1,
        }


def _install(service, pages, labels, drift=False, drop_href=False, fail_followup=False):
    service.router = ChoosingRouter(labels)
    service.bridge.sync({'host_id': 'test', 'active_tab_id': 'tab-a', 'tabs': [
        {'id': 'tab-a', 'url': 'https://example.com', 'title': 'Example'},
    ]})
    commands = []
    navs = {'n': 0}
    reads = {'n': 0}
    initial = {
        'url': 'https://example.com', 'title': 'Example', 'ready_state': 'complete',
        'marker': ['doc-before'], 'text': 'Example', 'actions': [],
    }

    async def call(tab_id, method, params=None, **kwargs):
        commands.append((method, params))
        if method == 'Page.navigate':
            navs['n'] += 1
            if fail_followup and navs['n'] > 1:
                from jet_browser.bridge import BridgeError
                raise BridgeError('Native navigation was not acknowledged')
            return {}
        if method == 'Runtime.evaluate':
            reads['n'] += 1
            if navs['n'] == 0:
                return {'result': {'value': dict(initial)}}
            page = dict(pages[min(navs['n'] - 1, len(pages) - 1)])
            if drift and reads['n'] >= 3:
                page = {**page, 'marker': ['doc-drift'], 'url': 'https://en.wikipedia.org/wiki/Drift'}
            if drop_href and reads['n'] >= 3:
                page['actions'] = [{**action, 'href': ''} for action in page.get('actions') or []]
            return {'result': {'value': page}}
        return {'tab_id': tab_id, 'active_tab_id': tab_id}

    service.bridge.call = call
    return commands


def _plan(outcome='destination', query='Elon Musk'):
    return {
        'operation': 'search', 'tab_id': 'tab-a', 'provider': 'wikipedia', 'query': query, 'outcome': outcome,
        'url': 'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Elon+Musk&go=Go',
    }


def _search_page():
    return {
        'url': 'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Elon+Musk&go=Go',
        'title': 'Elon Musk - Search results - Wikipedia', 'heading': 'Search results',
        'lead': 'Snippet Elon Musk', 'text': 'Elon Musk may appear in a snippet',
        'ready_state': 'complete', 'marker': ['doc-search'],
        'actions': [{'id': 'e1', 'role': 'link', 'label': 'Elon Musk', 'kind': 'click',
                     'href': 'https://en.wikipedia.org/wiki/Elon_Musk'}],
    }


async def test_search_results_cannot_finish_an_article_request(tmp_path):
    service = Service(tmp_path)
    commands = _install(service, [_search_page()], ['reached'])
    with pytest.raises(ValueError, match='model_not_proof'):
        await execute_local(service, _route(), _plan(), 'go to Elon Musk Wikipedia page')
    assert [c[0] for c in commands].count('Page.navigate') == 1
    assert service.store.routes()[-1]['outcome']['reason'] == 'model_not_proof'
    assert 'Elon Musk Wikipedia page' in service.router.states[0]
    service.store.close()
    service.trace.close()


async def test_redirect_stub_follows_one_observed_link(tmp_path):
    stub = {
        'url': 'https://en.wikipedia.org/wiki/Quantum_physics',
        'title': 'Quantum physics - Wikipedia', 'heading': 'Quantum physics',
        'lead': 'Quantum physics redirects to Quantum mechanics', 'text': 'redirects to Quantum mechanics',
        'ready_state': 'complete', 'marker': ['doc-stub'],
        'actions': [{'id': 'e1', 'role': 'link', 'label': 'Quantum mechanics', 'kind': 'click',
                     'href': 'https://en.wikipedia.org/wiki/Quantum_mechanics'}],
    }
    article = {
        'url': 'https://en.wikipedia.org/wiki/Quantum_mechanics',
        'title': 'Quantum mechanics - Wikipedia', 'heading': 'Quantum mechanics',
        'lead': 'Fundamental theory', 'text': 'Quantum mechanics describes physical properties',
        'ready_state': 'complete', 'marker': ['doc-article'], 'actions': [],
    }
    service = Service(tmp_path)
    commands = _install(service, [stub, article], ['continue', 'e1', 'yes'])
    route = _route()
    result = await execute_local(
        service, route,
        {**_plan(query='Quantum physics'),
         'url': 'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Quantum+physics&go=Go'},
        'go to Quantum physics Wikipedia page',
    )
    assert result['verified'] is False
    assert result['assessment'] == 'local_model'
    assert result['observed_page']['url'] == 'https://en.wikipedia.org/wiki/Quantum_mechanics'
    assert 'Quantum mechanics' in result['text']
    navigated = [c[1]['url'] for c in commands if c[0] == 'Page.navigate']
    assert navigated[-1] == 'https://en.wikipedia.org/wiki/Quantum_mechanics'
    assert route['outcome']['kind'] == 'assessment'
    assert route['outcome']['reason'] == 'local_model'
    assert 'untrusted evidence' in service.router.states[0]
    assert 'Quantum physics Wikipedia page' in service.router.states[0]
    service.store.close()
    service.trace.close()


async def test_cancelled_and_stale_followups_do_not_navigate(tmp_path):
    service = Service(tmp_path)
    commands = _install(service, [_search_page()], ['continue', 'e1'])

    def choose(model, state, question, criteria, stopped=None):
        service.chat_stopped.set()
        return 'continue', {
            'question': question, 'answer': 'continue', 'probabilities': {}, 'confidence': None,
            'model': model, 'inference_ms': 1,
        }

    service.router.choose = choose
    with pytest.raises(asyncio.CancelledError):
        await execute_local(service, _route(), _plan(), 'go to Elon Musk Wikipedia page')
    assert [c[0] for c in commands].count('Page.navigate') == 1

    service.chat_stopped.clear()
    commands = _install(service, [_search_page()], ['continue', 'e1'], drift=True)
    with pytest.raises(ValueError, match='stale_page'):
        await execute_local(service, _route(), _plan(), 'go to Elon Musk Wikipedia page')
    assert [c[0] for c in commands].count('Page.navigate') == 1
    service.store.close()
    service.trace.close()


async def test_followups_stop_at_three_and_on_a_repeated_link(tmp_path):
    def hop(index, href):
        return {
            'url': f'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Hop_{index}',
            'title': f'Hop {index} - Search results - Wikipedia', 'heading': 'Search results',
            'lead': 'Unrelated', 'text': 'Unrelated topic',
            'ready_state': 'complete', 'marker': [f'doc-{index}'],
            'actions': [{'id': 'e1', 'role': 'link', 'label': 'next', 'kind': 'click', 'href': href}],
        }

    pages = [
        hop(0, 'https://en.wikipedia.org/wiki/Hop_1'),
        hop(1, 'https://en.wikipedia.org/wiki/Hop_2'),
        hop(2, 'https://en.wikipedia.org/wiki/Hop_3'),
        hop(3, 'https://en.wikipedia.org/wiki/Hop_4'),
    ]
    service = Service(tmp_path)
    labels = ['continue', 'e1', 'continue', 'e1', 'continue', 'e1', 'continue']
    commands = _install(service, pages, labels)
    with pytest.raises(ValueError, match='max_steps'):
        await execute_local(service, _route(), _plan(query='Elon Musk'), 'go to Elon Musk Wikipedia page')
    assert [c[0] for c in commands].count('Page.navigate') == 4

    loop_page = hop(0, 'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Hop_0')
    commands = _install(service, [loop_page], ['continue', 'e1'])
    with pytest.raises(ValueError, match='loop'):
        await execute_local(service, _route(), _plan(), 'go to Elon Musk Wikipedia page')
    assert [c[0] for c in commands].count('Page.navigate') == 1
    service.store.close()
    service.trace.close()


async def test_third_link_can_be_assessed_without_a_fourth_navigation(tmp_path):
    def hop(index, href):
        return {
            'url': f'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Hop_{index}',
            'title': f'Hop {index} - Search results - Wikipedia', 'heading': 'Search results',
            'lead': 'Unrelated', 'text': 'Unrelated topic', 'ready_state': 'complete',
            'marker': [f'doc-{index}'],
            'actions': [{'id': 'e1', 'role': 'link', 'label': 'next', 'kind': 'click', 'href': href}],
        }

    alias = {
        'url': 'https://en.wikipedia.org/wiki/Elon', 'title': 'Elon - Wikipedia', 'heading': 'Elon',
        'lead': 'A male given name', 'text': 'A male given name', 'ready_state': 'complete',
        'marker': ['doc-alias'],
        'actions': [{'id': 'e9', 'role': 'link', 'label': 'more', 'kind': 'click',
                     'href': 'https://en.wikipedia.org/wiki/More'}],
    }
    service = Service(tmp_path)
    commands = _install(service, [
        hop(0, 'https://en.wikipedia.org/wiki/Hop_1'),
        hop(1, 'https://en.wikipedia.org/wiki/Hop_2'),
        hop(2, 'https://en.wikipedia.org/wiki/Elon'),
        alias,
    ], ['continue', 'e1', 'continue', 'e1', 'continue', 'e1', 'yes'])
    route = _route()
    result = await execute_local(service, route, _plan(query='elon'), 'go to elon musk wiki page')
    assert result['verified'] is False
    assert result['assessment'] == 'local_model'
    assert route['outcome']['kind'] == 'assessment'
    assert [c[0] for c in commands].count('Page.navigate') == 4
    service.store.close()
    service.trace.close()


async def test_missing_article_is_not_completion_and_wrong_article_can_follow(tmp_path):
    notice = 'Wikipedia does not have an article with this exact name.'
    missing = {
        'url': 'https://en.wikipedia.org/wiki/Elon_musks',
        'title': 'Elon musks - Wikipedia', 'heading': 'Elon musks', 'lead': notice, 'text': notice,
        'ready_state': 'complete', 'marker': ['doc-missing'], 'missing_article': True,
        'actions': [{'id': 'e1', 'role': 'link', 'kind': 'click', 'label': 'Elon Musk',
                     'href': 'https://en.wikipedia.org/wiki/Elon_Musk'}],
    }
    article = {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk', 'title': 'Elon Musk - Wikipedia', 'heading': 'Elon Musk',
        'lead': 'Businessman', 'text': 'Elon Musk', 'ready_state': 'complete', 'marker': ['doc-article'],
        'actions': [], 'missing_article': False,
    }
    service = Service(tmp_path)
    commands = _install(service, [missing], ['reached'])
    with pytest.raises(ValueError, match='model_not_proof'):
        await execute_local(service, _route(), _plan(query='Elon musks'), 'go to Elon musks wiki page')
    assert [c[0] for c in commands].count('Page.navigate') == 1

    commands = _install(service, [missing, article], ['continue', 'e1', 'yes'])
    result = await execute_local(service, _route(), _plan(query='Elon musks'), 'go to Elon musks wiki page')
    assert result['verified'] is False
    assert result['assessment'] == 'local_model'
    assert result['observed_page']['url'] == 'https://en.wikipedia.org/wiki/Elon_Musk'
    assert result['observed_page']['heading'] != 'Elon musks'
    assert [c[1]['url'] for c in commands if c[0] == 'Page.navigate'][-1] == 'https://en.wikipedia.org/wiki/Elon_Musk'

    wrong = {
        'url': 'https://en.wikipedia.org/wiki/Ada_Lovelace',
        'title': 'Ada Lovelace - Wikipedia', 'heading': 'Ada Lovelace', 'lead': 'Mathematician', 'text': 'Ada',
        'ready_state': 'complete', 'marker': ['doc-ada'], 'missing_article': False,
        'actions': [{'id': 'e1', 'role': 'link', 'kind': 'click', 'label': 'Elon Musk',
                     'href': 'https://en.wikipedia.org/wiki/Elon_Musk'}],
    }
    commands = _install(service, [wrong], ['unknown'])
    with pytest.raises(ValueError, match='uncertain'):
        await execute_local(service, _route(), _plan(), 'go to Elon Musk wiki page')
    assert [c[0] for c in commands].count('Page.navigate') == 1

    commands = _install(service, [wrong, article], ['no', 'e1'])
    result = await execute_local(service, _route(), _plan(), 'go to Elon Musk wiki page')
    assert result['verified'] == 'title_and_url'
    assert 'assessment' not in result
    assert result['observed_page']['url'] == 'https://en.wikipedia.org/wiki/Elon_Musk'
    assert result['observed_page']['heading'] == 'Elon Musk'
    service.store.close()
    service.trace.close()


async def test_web_discovery_can_assess_a_wikipedia_article(tmp_path):
    article = {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk',
        'title': 'Elon Musk - Wikipedia', 'heading': 'Elon Musk',
        'lead': 'Businessman', 'text': 'Elon Musk', 'ready_state': 'complete', 'marker': ['doc-wiki'],
        'actions': [],
    }
    service = Service(tmp_path)
    _install(service, [article], ['yes'])
    route = _route()
    result = await execute_local(
        service, route,
        {'operation': 'search', 'tab_id': 'tab-a', 'provider': 'web', 'query': 'Elon Musk',
         'outcome': 'destination', 'url': 'https://www.google.com/search?q=Elon+Musk'},
        'go to elon musk',
    )
    assert result['verified'] is False
    assert result['assessment'] == 'local_model'
    assert result['text'] == 'Opened [Elon Musk - Wikipedia](https://en.wikipedia.org/wiki/Elon_Musk).'
    assert 'Local model assessment' not in result['text']
    assert route['outcome']['kind'] == 'assessment'
    assert assess_navigation(
        {'url': 'https://en.wikipedia.org/wiki/Elon_Musk', 'title': 'Elon Musk', 'heading': 'Elon Musk',
         'lead': '', 'text': ''},
        intent='destination', prompt='elon musk videos', recent=(), query='elon musk', provider='youtube',
    ) == 'wrong_provider'
    service.store.close()
    service.trace.close()


async def test_alias_and_wrong_link_are_assessment_not_proof(tmp_path):
    spacex = {
        'url': 'https://www.spacex.com/', 'title': 'SpaceX', 'heading': 'SpaceX',
        'lead': 'Launch provider', 'text': 'SpaceX', 'ready_state': 'complete', 'marker': ['doc-spacex'],
        'actions': [],
    }
    service = Service(tmp_path)
    _install(service, [spacex], ['reached'])
    route = _route()
    result = await execute_local(
        service, route,
        {'operation': 'search', 'tab_id': 'tab-a', 'provider': 'web', 'query': 'space x', 'outcome': 'destination',
         'url': 'https://www.google.com/search?q=space+x'},
        'go to space x', ('earlier note about launches',),
    )
    assert result['verified'] is False
    assert result['assessment'] == 'local_model'
    assert route['outcome']['kind'] == 'assessment'
    assert 'go to space x' in service.router.states[0]
    assert 'earlier note about launches' in service.router.states[0]

    stub = {
        'url': 'https://en.wikipedia.org/wiki/Quantum_physics',
        'title': 'Quantum physics - Wikipedia', 'heading': 'Quantum physics',
        'lead': 'Redirect page', 'text': 'Redirect page', 'ready_state': 'complete', 'marker': ['doc-stub'],
        'actions': [{'id': 'e1', 'role': 'link', 'label': 'Donate', 'kind': 'click',
                     'href': 'https://en.wikipedia.org/wiki/Donate'}],
    }
    donate = {
        'url': 'https://en.wikipedia.org/wiki/Donate', 'title': 'Donate - Wikipedia', 'heading': 'Donate',
        'lead': 'Fundraising', 'text': 'Unrelated fundraising page', 'ready_state': 'complete',
        'marker': ['doc-donate'], 'actions': [],
    }
    commands = _install(service, [stub, donate], ['continue', 'e1', 'yes'])
    route = _route()
    result = await execute_local(
        service, route, {**_plan(query='Quantum physics'),
                         'url': 'https://en.wikipedia.org/w/index.php?title=Special:Search&search=Quantum+physics&go=Go'},
        'go to Quantum physics Wikipedia page',
    )
    assert result['verified'] is False
    assert result['assessment'] == 'local_model'
    assert result.get('verified') != 'redirect_target'
    assert [c[1]['url'] for c in commands if c[0] == 'Page.navigate'][-1] == 'https://en.wikipedia.org/wiki/Donate'
    service.store.close()
    service.trace.close()


async def test_late_result_stays_inside_the_semif_choice_limit(tmp_path):
    headers = ['Main page', 'Contents', 'Current events', 'Random article', 'About Wikipedia',
               'Contact us', 'Donate', 'Help', 'Contributions', 'Log in', 'Create account',
               'Talk', 'Read', 'View history', 'What links here', 'Related changes', 'Upload file',
               'Special pages', 'Printable version', 'Page information', 'Wikidata item',
               'Cite this page', 'Short URL', 'Category', 'Portal']
    actions = []
    for index, label in enumerate(headers):
        actions.append({'id': f'h{index}', 'role': 'link', 'kind': 'click', 'label': label,
                        'href': f'https://en.wikipedia.org/wiki/Special:Header_{index}'})
    actions.append({'id': 'late', 'role': 'link', 'kind': 'click', 'label': 'Elon Musk',
                    'href': 'https://en.wikipedia.org/wiki/Elon_Musk'})
    for index in range(20):
        actions.append({'id': f'x{index}', 'role': 'link', 'kind': 'click', 'label': 'See also',
                        'href': f'https://en.wikipedia.org/wiki/See_{index}'})
    page = {**_search_page(), 'actions': actions}
    article = {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk', 'title': 'Elon Musk - Wikipedia',
        'heading': 'Elon Musk', 'lead': 'Businessman', 'text': 'Elon Musk',
        'ready_state': 'complete', 'marker': ['doc-article'], 'actions': [],
    }
    service = Service(tmp_path)
    sizes = []

    class Limited(ChoosingRouter):
        def choose(self, model, state, question, criteria, stopped=None):
            if 'NONE' in criteria:
                sizes.append(len(criteria))
                assert 2 <= len(criteria) <= 16
                label = 'late' if 'late' in criteria else 'NONE'
                return label, {
                    'question': question, 'answer': label, 'probabilities': {}, 'confidence': None,
                    'model': model, 'inference_ms': 1,
                }
            return super().choose(model, state, question, criteria, stopped)

    commands = _install(service, [page, article], ['continue'])
    service.router = Limited(['continue'])
    result = await execute_local(service, _route(), _plan(), 'go to Elon Musk wiki page')
    assert result['observed_page']['url'] == 'https://en.wikipedia.org/wiki/Elon_Musk'
    assert result['verified'] == 'title_and_url'
    assert sizes and max(sizes) <= 16
    assert [c[1]['url'] for c in commands if c[0] == 'Page.navigate'][-1] == 'https://en.wikipedia.org/wiki/Elon_Musk'
    service.store.close()
    service.trace.close()


async def test_none_advances_to_the_next_link_batch(tmp_path):
    actions = []
    for index in range(15):
        actions.append({'id': f'd{index}', 'role': 'link', 'kind': 'click', 'label': 'Elon Musk mention',
                        'href': f'https://en.wikipedia.org/wiki/Note_{index}'})
    actions.append({'id': 'target', 'role': 'link', 'kind': 'click', 'label': 'Elon Musk',
                    'href': 'https://en.wikipedia.org/wiki/Elon_Musk'})
    page = {**_search_page(), 'actions': actions}
    article = {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk', 'title': 'Elon Musk - Wikipedia',
        'heading': 'Elon Musk', 'lead': 'Businessman', 'text': 'Elon Musk',
        'ready_state': 'complete', 'marker': ['doc-article'], 'actions': [],
    }
    service = Service(tmp_path)
    sizes = []

    class Batches(ChoosingRouter):
        def choose(self, model, state, question, criteria, stopped=None):
            if 'NONE' not in criteria:
                return super().choose(model, state, question, criteria, stopped)
            sizes.append(len(criteria))
            assert 2 <= len(criteria) <= 16
            label = 'target' if 'target' in criteria else 'NONE'
            assert label != 'target' or sizes[-1] <= 16
            return label, {
                'question': question, 'answer': label, 'probabilities': {}, 'confidence': None,
                'model': model, 'inference_ms': 1,
            }

    commands = _install(service, [page, article], ['continue'])
    service.router = Batches(['continue'])
    route = _route()
    result = await execute_local(service, route, _plan(), 'go to Elon Musk wiki page')
    assert sizes == [16, 2]
    assert route['link_selection']['batches'] == 2
    assert result['observed_page']['url'] == 'https://en.wikipedia.org/wiki/Elon_Musk'
    assert [c[1]['url'] for c in commands if c[0] == 'Page.navigate'][-1] == 'https://en.wikipedia.org/wiki/Elon_Musk'
    service.store.close()
    service.trace.close()


async def test_stale_href_and_failed_acknowledgement_do_not_retry(tmp_path):
    from jet_browser.bridge import BridgeError
    service = Service(tmp_path)
    commands = _install(service, [_search_page()], ['continue', 'e1'], drop_href=True)
    with pytest.raises(ValueError, match='stale_href'):
        await execute_local(service, _route(), _plan(), 'go to Elon Musk Wikipedia page')
    assert [c[0] for c in commands].count('Page.navigate') == 1

    commands = _install(service, [_search_page(), {
        'url': 'https://en.wikipedia.org/wiki/Elon_Musk', 'title': 'Elon Musk - Wikipedia', 'heading': 'Elon Musk',
        'lead': 'Businessman', 'text': 'Elon Musk', 'ready_state': 'complete', 'marker': ['doc-article'],
        'actions': [],
    }], ['continue', 'e1'], fail_followup=True)
    with pytest.raises(BridgeError, match='not acknowledged'):
        await execute_local(service, _route(), _plan(), 'go to Elon Musk Wikipedia page')
    assert [c[0] for c in commands].count('Page.navigate') == 2
    service.store.close()
    service.trace.close()
