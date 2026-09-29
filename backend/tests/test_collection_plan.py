import pytest

from jet_browser.collection_plan import CollectionPlan, canonical_url

ARGS = {
    "request": "Categorize this website",
    "title": "Site notes",
    "categories": [{"id": "docs", "name": "Docs", "description": "Technical documentation"}],
}


def plan(**overrides):
    return CollectionPlan.from_request(
        {**ARGS, **overrides}, start_url="https://example.test/docs/start", tab_id="tab-1", model="lfm_rlcd"
    )


def test_plan_roundtrip_and_scope():
    p = plan(section_path="/docs")
    assert CollectionPlan.from_dict(p.to_dict()) == p
    assert p.in_scope("https://example.test/docs/API?a=1&b=2")
    for u in [
        "https://example.test/docs2",
        "https://example.test.evil/docs",
        "http://example.test/docs",
        "https://example.test:444/docs",
    ]:
        assert not p.in_scope(u)


def test_canonicalization_preserves_query_path_and_ipv6():
    assert canonical_url("HTTPS://Example.Test:443/Docs/API?B=2&a=1#x") == "https://example.test/Docs/API?B=2&a=1"
    assert (
        canonical_url("http://[::1]:80/a?next=https%3A%2F%2Ffoo.test") == "http://[::1]/a?next=https%3A%2F%2Ffoo.test"
    )


@pytest.mark.parametrize(
    "url",
    [
        "file:///a",
        "javascript:alert(1)",
        "https://a:b@example.test/a",
        "https://example.test:abc/a",
        "https://example.test:99999/a",
        "https://example.test/a/../b",
        "https://example.test/a/%2e%2e/b",
        "https://example.test/a%2f..%2fb",
        "https://example.test/with space",
        "https://example.test\\@evil.test/a",
    ],
)
def test_invalid_urls_rejected(url):
    with pytest.raises(ValueError):
        canonical_url(url)


@pytest.mark.parametrize(
    "overrides",
    [
        {"max_pages": True},
        {"max_pages": 51},
        {"max_seconds": 0},
        {"max_seconds": float("nan")},
        {"unknown": 1},
        {"section_path": "/docs2"},
        {"categories": []},
        {"categories": [{"id": "needs_review", "name": "Review", "description": "Reserved"}]},
        {"categories": ARGS["categories"] * 2},
    ],
)
def test_invalid_contract_inputs(overrides):
    with pytest.raises(ValueError):
        plan(**overrides)


def test_persisted_origin_cannot_override_scope():
    raw = plan().to_dict()
    raw["origin"] = "https://evil.test"
    with pytest.raises(ValueError):
        CollectionPlan.from_dict(raw)
