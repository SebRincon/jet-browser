"""Structural destination checks for homepage, explicit URL, and YouTube resources.

A matching navigation is not completion. Semantic identity stays a separate assessment.
"""

import re
from urllib.parse import parse_qs, unquote, urlparse

from .navigation import HOMEPAGE_URLS

_YOUTUBE_HOSTS = frozenset({'youtube.com', 'www.youtube.com', 'm.youtube.com'})
_VIDEO_ID = re.compile(r'^[A-Za-z0-9_-]{11}$')
_PLAYLIST_ID = re.compile(r'^[A-Za-z0-9_-]{12,}$')
_CHANNEL_ID = re.compile(r'^[A-Za-z0-9_-]{10,}$')
_HANDLE = re.compile(r'^[\w.-]{2,}$', re.UNICODE)
_TRACKING = frozenset({
    'si', 'feature', 'pp', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content',
    'ab_channel', 'embeds_referring_euri', 'source_ve_path', 'ucbcb', 'bpctr',
})
_SHELL_TITLES = frozenset({'loading', 'just a moment', ''})
_CONSENT_TITLES = frozenset({
    'before you continue', 'before you continue to youtube', 'before you continue to google',
})
_LOGIN_TITLES = frozenset({'sign in', 'sign in to continue', 'log in', 'login'})
_UNAVAILABLE_TITLES = frozenset({
    "this page isn't available", 'this page is not available', 'video unavailable',
    'page not found', '404',
})


def _host(url):
    return (urlparse(url or '').hostname or '').casefold().rstrip('.')


def _parsed(url):
    try:
        return urlparse(url or '')
    except ValueError:
        return None


def _credentials(parsed):
    return bool(parsed.username or parsed.password)


def registry_hosts(provider):
    """Exact hosts for one registry homepage, including the public mobile YouTube host."""
    url = HOMEPAGE_URLS.get(provider or '')
    if not url:
        return frozenset()
    host = _host(url)
    allowed = {host}
    if host.startswith('www.'):
        allowed.add(host[4:])
    if provider == 'youtube':
        allowed.add('m.youtube.com')
    return frozenset(allowed)


def allowed_provider_host(url, provider):
    """True for a genuine registry or YouTube host. Consent, lookalikes, and credentials fail."""
    parsed = _parsed(url)
    if parsed is None or _credentials(parsed) or parsed.scheme not in {'http', 'https'}:
        return False
    host = _host(url)
    if provider == 'youtube':
        return host in _YOUTUBE_HOSTS
    return host in registry_hosts(provider)


def _params(url):
    return {key: values[-1] for key, values in parse_qs(
        urlparse(url or '').query, keep_blank_values=False).items()}


def _path(url):
    parsed = _parsed(url)
    if parsed is None:
        return '/'
    return unquote(parsed.path or '/') or '/'


def youtube_resource(url):
    """(kind, key) for a real YouTube resource, else None. watch?list= stays a video."""
    if not allowed_provider_host(url, 'youtube'):
        return None
    path = _path(url).rstrip('/') or '/'
    params = _params(url)
    if path == '/watch' and _VIDEO_ID.fullmatch(params.get('v', '')):
        return ('video', params['v'])
    short = re.fullmatch(r'/shorts/([A-Za-z0-9_-]{11})', path)
    if short:
        return ('video', short.group(1))
    handle = re.fullmatch(r'/@([^/]+)', path)
    if handle and _HANDLE.fullmatch(handle.group(1)):
        return ('channel', handle.group(1).casefold())
    channel = re.fullmatch(r'/channel/([^/]+)', path)
    if channel and _CHANNEL_ID.fullmatch(channel.group(1)):
        return ('channel', channel.group(1))
    legacy = re.fullmatch(r'/(?:c|user)/([^/]+)', path)
    if legacy and _HANDLE.fullmatch(legacy.group(1)):
        return ('channel', legacy.group(1).casefold())
    if path == '/playlist' and _PLAYLIST_ID.fullmatch(params.get('list', '')):
        return ('playlist', params['list'])
    if path == '/results':
        return ('search_results', params.get('search_query', '').casefold())
    if path == '/':
        return ('homepage', '/')
    return None


def same_youtube_resource(left, right):
    resource = youtube_resource(left)
    return resource is not None and resource == youtube_resource(right) and resource[0] in {
        'video', 'channel', 'playlist',
    }


def _safe_port(parsed):
    try:
        return parsed.port
    except ValueError:
        return 'invalid'


def _norm(value):
    return re.sub(r'\s+', ' ', str(value or '')).strip().casefold()


def _visible_label(page):
    heading = _norm(page.get('heading'))
    title = _norm(page.get('title'))
    title = re.sub(r'\s+-\s+youtube$', '', title).strip()
    return heading or title


def blocked_reason(page):
    """Visible consent, login, or unavailable UI. Ordinary YouTube chrome is not a block."""
    if _norm(page.get('navigation_error')):
        return 'unavailable'
    host = _host(page.get('url'))
    if host in {'consent.youtube.com', 'consent.google.com'}:
        return 'consent'
    if host == 'accounts.google.com':
        return 'login'
    label = _visible_label(page)
    if label in _CONSENT_TITLES:
        return 'consent'
    if label in _LOGIN_TITLES:
        return 'login'
    if label in _UNAVAILABLE_TITLES:
        return 'unavailable'
    return None


def lookalike_host(url, provider):
    host = _host(url)
    if not host or allowed_provider_host(url, provider):
        return False
    needle = 'youtube' if provider == 'youtube' else provider
    return needle in host


def _query_items(url, drop_tracking):
    items = []
    for key, values in parse_qs(urlparse(url or '').query, keep_blank_values=False).items():
        if drop_tracking and key.casefold() in _TRACKING:
            continue
        for value in values:
            items.append((key, value))
    return tuple(sorted(items))


def explicit_url_matches(actual, target):
    """Same destination. http may upgrade to https. YouTube drops only documented tracking keys."""
    actual_url, target_url = _parsed(actual), _parsed(target)
    if (actual_url is None or target_url is None or _credentials(actual_url) or _credentials(target_url)
            or actual_url.scheme not in {'http', 'https'} or target_url.scheme not in {'http', 'https'}):
        return False
    if actual_url.scheme != target_url.scheme and not (target_url.scheme == 'http' and actual_url.scheme == 'https'):
        return False
    actual_port, target_port = _safe_port(actual_url), _safe_port(target_url)
    if actual_port == 'invalid' or target_port == 'invalid':
        return False
    if actual_port != target_port and (actual_port or target_port):
        defaults = {('http', None), ('http', 80), ('https', None), ('https', 443)}
        if (actual_url.scheme, actual_port) not in defaults or (target_url.scheme, target_port) not in defaults:
            return False
    if actual_url.fragment != target_url.fragment:
        return False
    if same_youtube_resource(actual, target):
        return _query_items(actual, True) == _query_items(target, True)
    if _host(actual) != _host(target):
        return False
    if (_path(actual).rstrip('/') or '/') != (_path(target).rstrip('/') or '/'):
        return False
    return _query_items(actual, False) == _query_items(target, False)


def homepage_ready(page, provider):
    if blocked_reason(page) or not allowed_provider_host(page.get('url'), provider):
        return False
    if (_path(page.get('url')).rstrip('/') or '/') != '/' or _params(page.get('url')):
        return False
    if page.get('ready_state') not in {None, 'interactive', 'complete'}:
        return False
    title = _norm(page.get('title'))
    body = _norm(page.get('text'))
    if title in _SHELL_TITLES or len(title) < 2 or len(body) < 40:
        return False
    return True


def _core_title(value):
    return re.sub(r'\s+-\s+youtube$', '', _norm(value)).strip()


def _channel_identity(page):
    raw = page.get('channel_identity')
    if not isinstance(raw, dict):
        return None
    external = str(raw.get('external_id') or '').strip()
    vanity = str(raw.get('vanity_url') or '').strip()
    title = str(raw.get('title') or '').strip()
    if not external or not vanity or not title:
        return None
    return external, vanity, title


def _channel_alias_aligned(page):
    """Tie @handle and /channel/id through the current browse renderer's own metadata."""
    identity = _channel_identity(page)
    if identity is None:
        return False
    external, vanity, meta_title = identity
    actual = youtube_resource(page.get('url'))
    vanity_resource = youtube_resource(vanity)
    canonical = youtube_resource(page.get('canonical_url'))
    if actual != vanity_resource or not actual or actual[0] != 'channel':
        return False
    if canonical != ('channel', external):
        return False
    return _norm(page.get('heading')) == _norm(meta_title)


def canonical_aligned(page):
    """Observed URL and code-owned canonical URL name the same YouTube resource."""
    canonical = str(page.get('canonical_url') or '')
    if not canonical:
        return False
    if same_youtube_resource(canonical, page.get('url')):
        return True
    return _channel_alias_aligned(page)


def surface_ready(page):
    """Visible heading and the current document title name the same non-shell subject."""
    heading = _norm(page.get('heading'))
    if not heading or heading in _SHELL_TITLES or heading == 'youtube':
        return False
    if _core_title(page.get('title')) != heading:
        return False
    canonical_title = _core_title(page.get('canonical_title'))
    if canonical_title and canonical_title != heading:
        return False
    return True


def aligned_title(page):
    """Visible heading only after canonical identity and the live title agree."""
    if not canonical_aligned(page) or not surface_ready(page):
        return ''
    return re.sub(r'\s+-\s+YouTube\s*$', '', str(page.get('heading') or ''), flags=re.I).strip()


def visible_document_ready(page):
    """Meaningful title and body. Blank shells and error titles are not ready."""
    if page.get('ready_state') not in {None, 'interactive', 'complete'}:
        return False
    title = _norm(page.get('title'))
    if (not title or title in _SHELL_TITLES or len(title) < 2 or len(_norm(page.get('text'))) < 40
            or title in _UNAVAILABLE_TITLES | _CONSENT_TITLES | _LOGIN_TITLES):
        return False
    return True


_NO_RESULT_PHRASES = ('no results found', 'did not match any', 'no results for')


def _intermediary_ready(page, kind):
    """Search step is decidable once requested-kind links or a loaded empty-results body exist."""
    actions = page.get('actions') if isinstance(page.get('actions'), list) else []
    if any(link_matches_kind(action.get('href'), kind) for action in actions if isinstance(action, dict)):
        return True
    text = _norm(page.get('text'))
    title = _norm(page.get('title'))
    if not title or title in _SHELL_TITLES or len(text) < 40:
        return False
    return any(phrase in text for phrase in _NO_RESULT_PHRASES)


def resource_settled(page, kind, provider=None):
    """Current page is decidable. Shells, stale canonicals, and thin search pages keep waiting."""
    if blocked_reason(page):
        return True
    if kind == 'homepage':
        return homepage_ready(page, provider or '')
    if kind == 'explicit_url':
        return visible_document_ready(page)
    observed = youtube_resource(page.get('url'))
    observed_kind = observed[0] if observed else ''
    if kind in {'video', 'channel', 'playlist'}:
        if observed_kind == 'search_results':
            return _intermediary_ready(page, kind)
        if observed_kind != kind:
            return True
        return canonical_aligned(page) and surface_ready(page)
    label = _visible_label(page)
    if not label or label in _SHELL_TITLES:
        return False
    return True


def completion_identity_same(before, after):
    """Document, URL, resource, and visible titles are the page that was assessed."""
    if not isinstance(before, dict) or not isinstance(after, dict):
        return False
    for key in ('document_id', 'url', 'title', 'heading', 'canonical_url', 'canonical_title'):
        if before.get(key) != after.get(key):
            return False
    if youtube_resource(before.get('url')) != youtube_resource(after.get('url')):
        return False
    return (before.get('channel_identity') or {}) == (after.get('channel_identity') or {})


def structural_status(page, plan, goal):
    """proof, kind_ok, intermediate, or a terminal structural reason. The model cannot upgrade these."""
    kind = goal.get('kind')
    provider = goal.get('provider')
    if blocked_reason(page):
        return blocked_reason(page)
    if kind == 'homepage':
        if lookalike_host(page.get('url'), provider) or not allowed_provider_host(page.get('url'), provider):
            return 'lookalike_host' if lookalike_host(page.get('url'), provider) else 'wrong_provider'
        return 'proof' if homepage_ready(page, provider) else 'unready'
    if kind == 'explicit_url':
        if not visible_document_ready(page):
            return 'unready'
        return 'proof' if explicit_url_matches(page.get('url'), goal.get('url') or plan.get('url')) else 'explicit_mismatch'
    if provider != 'youtube' or kind not in {'video', 'channel', 'playlist', 'search_results'}:
        return 'skip'
    if lookalike_host(page.get('url'), 'youtube'):
        return 'lookalike_host'
    if not allowed_provider_host(page.get('url'), 'youtube'):
        return 'wrong_provider'
    observed = youtube_resource(page.get('url'))
    observed_kind = observed[0] if observed else 'other'
    if kind == 'search_results':
        expected = _norm(plan.get('query') or goal.get('query') or '')
        if observed_kind == 'search_results' and observed[1] == expected and expected:
            label = _visible_label(page)
            return 'proof' if label and label not in _SHELL_TITLES else 'unready'
        return 'not_results'
    if observed_kind == 'search_results':
        return 'intermediate'
    if observed_kind != kind:
        return 'wrong_kind'
    if not canonical_aligned(page) or not surface_ready(page):
        return 'unready'
    return 'kind_ok'


def link_matches_kind(href, kind):
    resource = youtube_resource(href)
    return bool(resource) and resource[0] == kind
