"""Local native choices for the shared chat; no generated browser code."""

import atexit
import json
import os
import re
import time
import uuid
from contextlib import nullcontext
from urllib.parse import urlencode, urlparse

import httpx

from jet_browser.navigation import (
    HOMEPAGE_URLS,
    NavigationGoal,
    goal_kind_for_search,
    homepage_request,
    negated_navigation,
    second_requested_action,
    unsupported_navigation,
    youtube_request,
    youtube_search_query,
)
from jev_ultrafast.local_models import NativeWorker
from jev_ultrafast.model import validate_native_choice

ROUTER_MODEL = "qwen4b_semif_shared"
ROUTING_WORKER = NativeWorker()  # Stay warm when the page executor uses another model.
atexit.register(ROUTING_WORKER.close)
OPERATIONS = {
    "search": "Find or open a named website, Wikipedia article, or YouTube video, channel, or playlist.",
    "open_url": "Open a literal URL or domain supplied by the user.",
    "page_task": "Interact with the current page: click a result/link, fill fields, select options, or continue a prior browser task.",
    "back": "Go back to the previous page.",
    "forward": "Go forward to the next page.",
    "reload": "Reload or refresh the page.",
    "new_tab": "Open/create a new blank tab.",
    "close_tab": "Close a browser tab.",
    "switch_tab": "Switch to an already open tab.",
    "list_tabs": "List the open browser tabs.",
    "summarize": "Summarize the current page or other text.",
    "explain": "Answer a factual question, explain, compare, discuss, write, research, or tell a joke.",
    "collect": "Collect and categorize information across pages of the current website into a saved local collection.",
}


def request_outcome(prompt):
    """Only unambiguous one-clause imperatives. Anything coordinated or negated asks the model."""
    text = re.sub(r'\s+', ' ', prompt.casefold()).strip().rstrip('.!')
    if re.search(r"\b(?:don't|do not|never|not)\b", text) or re.search(r'[,:;"]', text):
        return None
    if re.fullmatch(r'(?:please )?(?:show|list|display)(?: me)? (?:the )?wikipedia search results for \S(?:.*\S)?', text):
        return 'search_results'
    if re.search(r'search results|result list|results page', text):
        return None
    if re.fullmatch(r'(?:please )?(?:go to|open|find)(?: me)? (?:the )?.+ (?:wiki page|wikipedia page|wikipedia article)', text):
        return 'destination'
    if re.fullmatch(r'(?:please )?(?:open|find)(?: me)? (?:the )?(?:wikipedia )?(?:article|page) (?:for|about) \S(?:.*\S)?', text):
        return 'destination'
    return None


def grounded_text(value, sources):
    """A helper may extract user text; it cannot invent a destination or entity."""
    value = value.strip().strip('"\'`').strip()
    if not value or len(value) > 800 or value.casefold() in {"null", "none"} or "\n" in value:
        raise ValueError("The local helper could not identify a single requested value")
    if any(value.casefold() in source.casefold() for source in sources):
        return value
    # Recover harmless separator changes from the exact user substring, e.g.
    # helper "python-docs" becomes the user's "Python docs", never new words.
    parts = re.split(r'[\s-]+', value)
    if len(parts) > 1:
        pattern = r'\b' + r'[\s-]+'.join(re.escape(part) for part in parts) + r'\b'
        for source in sources:
            match = re.search(pattern, source, re.I)
            if match:
                return match.group(0)
    raise ValueError("The local helper supplied a value absent from the conversation")


def extract_query(prompt, recent_requests=()):
    sources = [prompt, *list(recent_requests)[-3:]]
    base = os.environ.get("TEXT_MODEL_BASE_URL", "http://127.0.0.1:9149/v1")
    if urlparse(base).hostname not in {"127.0.0.1", "localhost"}:
        raise ValueError("Local routing requires the local text helper")
    messages = [
        {"role": "system", "content": "Extract the search topic from the CURRENT user request. "
         "Return only a short phrase copied from the request. Do not include find/open/page/Wikipedia. "
         "Earlier user requests may resolve pronouns only. Return null if no topic is specified."},
        {"role": "user", "content": "Find me the Wikipedia page for Ada Lovelace"},
        {"role": "assistant", "content": "Ada Lovelace"},
        {"role": "user", "content": "find the official Python docs"},
        {"role": "assistant", "content": "Python docs"},
        {"role": "user", "content": "go voyager 1 wiki page"},
        {"role": "assistant", "content": "voyager 1"},
        {"role": "user", "content": "grace hopper wiki"},
        {"role": "assistant", "content": "grace hopper"},
        {"role": "user", "content": "Earlier: Find the wiki page for Alan Turing\nCurrent: Now find that same kind of page for Grace Hopper"},
        {"role": "assistant", "content": "Grace Hopper"},
        {"role": "user", "content": "Earlier: " + json.dumps(sources[1:]) + "\nCurrent: " + prompt},
    ]
    with httpx.Client(timeout=30) as client:
        result = client.post(base.rstrip('/') + '/chat/completions', json={
            "model": os.environ.get("TEXT_MODEL", "default_model"), "messages": messages,
            "max_tokens": 80, "temperature": 0, "reasoning": {"enabled": False},
        })
        result.raise_for_status()
        value = result.json()["choices"][0]["message"]["content"]
    return grounded_text(value, sources)


class LocalRouter:
    def __init__(self, worker=ROUTING_WORKER, extractor=extract_query, trace=None):
        self.worker = worker
        self.extractor = extractor
        self.trace = trace

    def choose(self, model, state, question, criteria, stopped=None):
        if stopped and stopped.is_set():
            raise RuntimeError("Stopped before local inference")
        request = {"state": state, "questions": {
            "choice": {"type": "choice", "instructions": question, "criteria": criteria},
        }}
        if model == "lfm_rlcd":
            request["readout"] = "lfm_choice_logits"
        with self.trace.span('router.choice', model=model, candidate_count=len(criteria)) if self.trace else nullcontext():
            if self.trace:
                self.worker.trace = self.trace.emit
            result = self.worker.predict(model, request)
        if stopped and stopped.is_set():
            raise RuntimeError("Stopped after local inference")
        answer = validate_native_choice(result.get("answers", {}).get("choice", {}), criteria)
        if self.trace:
            self.trace.emit('router.decision', choice=answer['choice'], confidence=answer['confidence'],
                            probabilities=answer['probabilities'], model=model,
                            inference_ms=result.get('latency_ms'))
        return answer["choice"], {
            "question": question, "answer": answer["choice"],
            "probabilities": answer["probabilities"], "confidence": answer["confidence"],
            "model": result.get("model"), "inference_ms": result.get("latency_ms"),
        }

    # SemIf's finite-choice head accepts at most 16 options, including the escape.
    MAX_CHOICE_OPTIONS = 16

    def choose_bounded(self, model, state, question, candidates, escape, stopped=None):
        """Choose among any number of candidates within the local option limit.

        Every question carries the escape option. Probabilities are normalized per
        question, so chunks are never compared with each other: each chunk yields at
        most one winner, and the winners meet again in a final round with the escape.
        Returns (choice, audits, rounds); the choice may be the escape id.
        """
        escape_id, escape_text = escape
        items = [(key, text) for key, text in candidates.items() if key != escape_id]
        size = self.MAX_CHOICE_OPTIONS - 1
        audits, rounds = [], 0
        while True:
            rounds += 1
            winners = []
            for start in range(0, len(items), size):
                chunk = dict(items[start:start + size])
                chunk[escape_id] = escape_text
                choice, audit = self.choose(model, state, question, chunk, stopped)
                audits.append(audit)
                if choice != escape_id:
                    winners.append(choice)
            if len(items) <= size or len(winners) <= 1:
                return (winners[0] if winners else escape_id), audits, rounds
            items = [(key, candidates[key]) for key in winners]

    def _selected(self, started, model, operation, audits, local=None):
        if local is None:
            local = operation not in {"summarize", "explain", "collect"}
        return {
            "id": uuid.uuid4().hex, "created_at": time.time(), "model": model,
            "decision": "local" if local else "grok", "operation": operation,
            "reason": OPERATIONS[operation], "status": "selected",
            "elapsed_ms": round((time.perf_counter() - started) * 1000),
            "audit": audits, "grok_calls": 0,
        }

    def route(self, prompt, model, browser, recent_requests=(), stopped=None):
        if stopped and stopped.is_set():
            raise RuntimeError("Stopped before local inference")
        started = time.perf_counter()
        if negated_navigation(prompt):
            return self._selected(started, model, "explain", [
                {"rule": "negated_navigation", "answer": "explain"},
            ], local=False)
        if second_requested_action(prompt):
            return self._selected(started, model, "explain", [
                {"rule": "compound_navigation", "answer": "explain"},
            ], local=False)
        provider = homepage_request(prompt)
        if provider:
            return self._selected(started, model, "open_url", [
                {"rule": "homepage_request", "answer": provider},
            ])
        youtube = youtube_request(prompt)
        if youtube:
            kind, subject = youtube
            return self._selected(started, model, "search", [
                {"rule": "youtube_request", "answer": kind, "query": subject},
            ])
        # Request dominates; history only resolves references, never adds new goals.
        state = ''
        if recent_requests:
            state = "Historical requests (reference only, never repeat): " + json.dumps(
                [s[:500] for s in list(recent_requests)[-3:]], ensure_ascii=False) + '\n\n'
        state += 'CURRENT USER REQUEST: ' + prompt
        operation, audit = self.choose(
            model, state,
            "Classify the CURRENT USER REQUEST by its requested action. Historical requests only resolve references; do not repeat them.",
            OPERATIONS, stopped,
        )
        local = operation not in {"summarize", "explain", "collect"}
        audits = [audit]
        # Concrete application controls already identify their operation. Check
        # page tasks and tab references, where "do that" can be under-specified.
        if local and operation in {'page_task', 'switch_tab'}:
            disposition, check = self.choose(model, state,
                "Can we perform the CURRENT request as a browser action, or does it ask for an answer or lack a clear referent?", {
                    "act": "The user requests a specific browser action with enough information: navigate, search, fill, click or manage tabs.",
                    "answer": "The user asks a question, summary, explanation or recall of earlier facts/values. An answer is required, not a browser action.",
                    "clarify": "The user refers to an unspecified thing or previous action, and the supplied history does not identify it.",
                }, stopped)
            audits.append(check)
            if disposition != 'act':
                operation, local = 'explain', False
        # The router sees past user requests, not complete assistant proposals.
        # A bare assent needs the full conversation before it can become an action.
        words = re.findall(r'[a-z]+', prompt.casefold())
        if words and set(words) <= {'yes', 'yeah', 'yep', 'sure', 'ok', 'okay', 'please', 'do', 'it', 'that', 'go', 'ahead'}:
            operation, local = 'explain', False
            audits.append({'rule': 'confirmation_requires_full_history', 'answer': 'grok'})
        return self._selected(started, model, operation, audits, local)

    def _attach_goal(self, plan, goal):
        plan['navigation_goal'] = goal.to_dict()
        return plan

    def _youtube_kind(self, model, state, route, stopped):
        """Finite kind question. Keyword presence is not evidence of the resource."""
        kind, audit = self.choose(model, state, "Which YouTube resource does the current request ask for?", {
            "video": "A video.",
            "channel": "A channel.",
            "playlist": "A playlist.",
            "search_results": "The search results page.",
            "other": "The request does not name one of those resources.",
        }, stopped)
        route['audit'].append(audit)
        if kind == 'other':
            route['audit'].append({'rule': 'youtube_kind', 'answer': 'unverified'})
        return kind

    def prepare(self, route, prompt, browser, recent_requests=(), stopped=None):
        """Return a validated finite plan. This method never operates the browser."""
        if stopped and stopped.is_set():
            raise RuntimeError("Stopped before local inference")
        operation = route['operation']
        model = route['model']
        plan = {"operation": operation, "tab_id": browser.get('active_tab_id')}
        state = "Earlier requests (references only, never repeat): " + json.dumps(list(recent_requests)[-3:]) + '\n\nCURRENT USER REQUEST: ' + prompt
        if operation in {'summarize', 'explain', 'collect', 'back', 'forward', 'reload', 'new_tab', 'list_tabs'}:
            return plan
        if operation in {'switch_tab', 'close_tab'}:
            choices = {t['id']: ("Current tab: " if t['id'] == plan['tab_id'] else "Tab: ")
                       + t.get('title', '') + ' ' + t.get('url', '')[:160] for t in browser.get('tabs', [])}
            if not choices:
                raise ValueError("There are no observed tabs to choose")
            tab, audits, rounds = self.choose_bounded(
                model, state, "Which observed tab does the user mean?", choices,
                ('UNRESOLVED', 'No single observed tab is identified by the request.'), stopped)
            route['audit'].extend(audits)
            route['audit'].append({'rule': 'bounded_tab_selection', 'candidates': len(choices),
                                   'questions': len(audits), 'rounds': rounds, 'answer': tab})
            if tab == 'UNRESOLVED':
                raise ValueError('The requested tab is ambiguous')
            plan['tab_id'] = tab
        elif operation == 'open_url':
            if unsupported_navigation(prompt):
                raise ValueError("This navigation request includes another action")
            provider = homepage_request(prompt)
            if provider:
                url = HOMEPAGE_URLS[provider]
                plan['url'] = url
                plan['provider'] = provider
                route['audit'].append({'rule': 'homepage_request', 'answer': provider})
                return self._attach_goal(plan, NavigationGoal(
                    provider=provider, kind='homepage', request=prompt,
                    tab_id=plan['tab_id'], url=url,
                ))
            urls = re.findall(r"(?:https?://|www\.)[^\s<>]+|\b(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:/[^\s<>]*)?", prompt)
            urls = [url.rstrip('.,;!?\'\")') for url in urls]
            if len(urls) != 1:
                raise ValueError("A single explicit destination URL is needed")
            url = urls[0]
            plan['url'] = url if url.startswith(('https://', 'http://')) else 'https://' + url
            return self._attach_goal(plan, NavigationGoal(
                provider='web', kind='explicit_url', request=prompt,
                tab_id=plan['tab_id'], url=plan['url'],
            ))
        elif operation == 'search':
            if unsupported_navigation(prompt):
                raise ValueError("This navigation request includes another action")
            youtube = youtube_request(prompt)
            if youtube:
                kind, subject = youtube
                search_query = youtube_search_query(kind, subject)
                outcome = 'search_results' if kind == 'search_results' else 'destination'
                url = 'https://www.youtube.com/results?' + urlencode({'search_query': search_query})
                plan.update(query=search_query, provider='youtube', outcome=outcome, url=url)
                route['audit'].append({'rule': 'youtube_request', 'answer': kind, 'query': subject})
                return self._attach_goal(plan, NavigationGoal(
                    provider='youtube', kind=kind, request=prompt, query=subject,
                    tab_id=plan['tab_id'], url=url,
                ))
            with self.trace.span('helper.query', model='qwen0.8b', input_chars=len(prompt)) if self.trace else nullcontext():
                query = self.extractor(prompt, recent_requests)
            query = grounded_text(query, [prompt, *recent_requests])
            if stopped and stopped.is_set():
                raise RuntimeError("Stopped after query extraction")
            active = next((t for t in browser.get('tabs', []) if t['id'] == plan['tab_id']), {})
            provider, audit = self.choose(model, state + '\nCurrent page: ' + active.get('url', ''),
                "Where does the current user want to search? Reuse the previous site only for a same-site follow-up.", {
                    "wikipedia": "Wikipedia article lookup, including a wiki page.",
                    "web": "General web search for a website, official documentation or an unspecified source.",
                    "youtube": "YouTube video search.",
                    "github": "GitHub repository search.",
                }, stopped)
            route['audit'].append(audit)
            # The open page is not evidence of what this request asked to stop on.
            outcome = request_outcome(prompt)
            if outcome:
                route['audit'].append({'rule': 'request_outcome', 'answer': outcome})
            else:
                outcome, outcome_audit = self.choose(model, state,
                    "Does the current user request itself ask for the search results page, or for the destination? "
                    "Ignore any page already open.", {
                        "destination": "Open the named page, article, or site. A results list is only a step toward it.",
                        "search_results": "Stop on the search results page. Do not jump straight to one result.",
                    }, stopped)
                route['audit'].append(outcome_audit)
            wikipedia = {'title': 'Special:Search', 'search': query}
            if outcome == 'search_results':
                wikipedia['fulltext'] = '1'
            else:
                wikipedia['go'] = 'Go'
            urls = {
                'wikipedia': 'https://en.wikipedia.org/w/index.php?' + urlencode(wikipedia),
                'web': 'https://www.google.com/search?' + urlencode({'q': query}),
                'youtube': 'https://www.youtube.com/results?' + urlencode({'search_query': query}),
                'github': 'https://github.com/search?' + urlencode({'q': query, 'type': 'repositories'}),
            }
            if provider == 'youtube' and outcome != 'search_results':
                kind = self._youtube_kind(model, state, route, stopped)
                subject = query
                if kind != 'other':
                    query = youtube_search_query(kind, subject)
                urls['youtube'] = 'https://www.youtube.com/results?' + urlencode({'search_query': query})
            elif provider == 'youtube':
                kind = 'search_results'
                subject = query
            else:
                kind = goal_kind_for_search(provider, outcome)
                subject = query
            plan.update(query=query, provider=provider, outcome=outcome, url=urls[provider])
            return self._attach_goal(plan, NavigationGoal(
                provider=provider, kind=kind, request=prompt, query=subject,
                tab_id=plan['tab_id'], url=urls[provider],
            ))
        elif operation == 'page_task':
            plan['goal'] = prompt
            action, audit = self.choose(model, state, 'Which control can perform this request?', {
                'page_task': 'Interact with controls or links inside the web page, or continue a website task.',
                'back': 'Browser history: return to the preceding page.',
                'forward': 'Browser history: undo back navigation and return to the page we backed away from.',
                'reload': 'Browser chrome: refresh the current page.',
            }, stopped)
            route['audit'].append(audit)
            plan['operation'] = action
        return plan
