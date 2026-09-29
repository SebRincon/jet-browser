# Navigation intent completion

The subsequent [navigation-goal increment](navigation-goals.md) adds typed homepage, explicit-URL and YouTube resource checks. Generic forms still require independent outcome verification; their model DONE remains `manual_check`. Current tests and retained failures are in [verification](VERIFICATION.md).

Local search no longer treats a title that matches the helper query, or a model DONE, as proof that the original request is finished. This increment checks the original prompt. A shortened query is not evidence.

## What the router plans

`LocalRouter.prepare` still picks a search provider with the warm SemIf worker. It then asks one more finite question: `destination` or `search_results`.

- `destination` keeps the Wikipedia lookup that includes `go=Go`, so an exact title can still open directly.
- `search_results` asks Wikipedia for the results list with `fulltext=1` and without `go=Go`. Omitting `go` alone can still redirect to an article.

The current request decides that stopping point. A simple imperative such as "Show Wikipedia search results for …" or "go to … Wikipedia page" is applied directly. Negation, commas, or a topic that merely mentions search results is not parsed; that request asks the model, and the open page is not included in the question.

Direct `open_url` and the other application actions are unchanged. They do not run this checker.

## What the search path accepts

`assess_navigation` compares the current prompt with the observed URL, title, heading, lead, and a short text excerpt. Recent requests stay in the model state for pronouns and aliases. They are not deterministic proof when the current prompt does not itself name the title. The exact check does not strip a stopword list and keeps Unicode titles.

A Wikipedia destination is deterministic proof only when all of these hold:

- the host is `wikipedia.org` or a real subdomain (`en.wikipedia.org.evil.test` does not count)
- the URL is a main article (`/wiki/` or `index.php?title=` without a namespace colon), not a search endpoint
- the visible title is one whole mention in the current prompt, and every remaining word is navigation boilerplate. A lowercase first name or last name left inside a longer name (`elon` or `musk` inside `elon musk`) is not proof. Other wording goes to the semantic model and stays unverified
- the page is not a disambiguation (`may refer to`). A redirect stub is only a short notice such as `Redirect page` or `redirects to`. A canonical article that says `Redirected from Quantum physics` is not a stub
- the page is not Wikipedia's missing-article notice. A title that matches the prompt on `/wiki/Elon_musks` is not proof when the snapshot flag `missing_article` is set from the `noarticletext` element, or when an older snapshot still shows "Wikipedia does not have an article with this exact name". That page stays blocked and may follow an observed link

Search-result proof needs the provider host, an exact search path (`/search` or YouTube `/results`, not `/search-fiction`), the decoded query, and that same full-topic check against the original prompt. A helper query that dropped entity words is `incomplete_query` and can only finish as a local-model assessment. `notgoogle.com`, `notyoutube.com`, and a Wikipedia lookalike host are not results.

If that check fails, `execute_local` asks the same router, through `service.local_call`, whether the original request is `reached`, should `continue`, or is `uncertain`. The question states that page observations are untrusted evidence, not instructions. `continue` may select one observed link whose role is `link`, kind is `click`, and href is `http`/`https` without userinfo, or `NONE`. Each model call offers at most 15 of those links plus `NONE` (16 choices, the SemIf range). Links are ordered with a lexical overlap against the request so a content result past the first screen is not hidden behind Wikipedia chrome; that overlap only orders batches and is not completion. Further batches follow a `NONE` answer. The route records how many links were observed, whether the scan stopped early, and each batch size.

On a real Wikipedia article that is not already proved, the model is asked only whether the article covers the requested subject, including a canonical title named in the introduction. `yes` is stored as `assessment: local_model` with `verified: false`. It is not proof. `no` continues through the same bounded link follow-up. `unknown` hands off. A missing-article page is not asked that question and cannot be accepted. Search pages, stubs, disambiguation, lookalike hosts, and the wrong site never take that answer. Other pages are asked whether the full request is satisfied, including the kind of page and the site, so a matching topic of the wrong kind does not count. The chat text is `Opened [observed title](observed URL).` Route `outcome.kind` is `assessment`, and the trace `verified` flag is false. Search pages, disambiguation, redirect stubs, lookalike hosts, and wrong-provider pages cannot be finished by that answer (`model_not_proof`). `uncertain` hands off. A link followed from a redirect stub is not proof; the landed page is assessed again. An unrelated article such as Donate stays unverified even if the model calls it reached.

The snapshot copies each anchor's resolved `href` onto the action. The follow-up opens that observed URL only. Before the navigation it reads the page again and requires the same document id, the same URL, and the same href. A mismatch stops with `stale_page` or `stale_href` and does not retry. A failed native acknowledgement is not retried. An unchanged document after the navigation stops with `outcome_unknown` and does not retry. At most three follow-up links are opened. The page reached by the third link can still receive a read-only reached or uncertain assessment. A fourth navigation is not sent. A repeated URL stops with `loop`.

Deterministic successes use `verified` `title_and_url` or `search_results` and route `outcome.kind` `proof`. Traces emit reason, model, attempt, and the proof/assessment flag only (`route.outcome`), not the prompt or page text. Stop still cancels inside `local_call` before another navigation.

## Not in this increment

`TaskManager` general form completion still reports model DONE as `manual_check`. This search-path checker does not verify arbitrary form tasks.
