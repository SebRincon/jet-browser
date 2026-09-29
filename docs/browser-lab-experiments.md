# Browser Lab experiment catalog

2026-09-28. **Proposed experiments, not shipped capabilities or measured results.** Parent: [plan](../tasks/plan.md). Task contracts: [work items](../tasks/browser-lab-work-items.md). Source revisions and license metadata: [baseline manifest](../tasks/browser-lab-baseline.json).

## Extraction policy

Read the pinned source before adopting a pattern; copy only small compatible units when license terms permit, retain notices, and record source/destination hashes. Implement new fixture content ourselves. Do not copy JevTest code/fixtures while its license is unspecified. JevScout and Jev QA also have unresolved license metadata; inspect their pinned license texts before any copying. Preserve the current Jev Ultrafast lineage; do not import another browser, daemon, model host, or conversation UI.

The ten browser-project references below were reviewed through their public descriptions; their performance claims were not reproduced. Source pins make later code inspection repeatable. API license metadata is only a discovery aid, not the license audit. Individual source license texts and dependency notices still govern extraction.

## Twenty-two visible demos

Each demo gets a deterministic local practice site or frozen observation, a model-visible request, a separate oracle, and an adversarial variant. The first six families form the pilot. Demo values are synthetic. A gallery tile starts a real task in the existing chat; it never drives an external desktop browser.

| ID | User-facing example | What the local model does | Independent completion / hard variant | Tasks |
|---|---|---|---|---|
| D01 | Open Elon Musk's Wikipedia article | Pick entity/result; judge a remaining identity question | Article identity and visible content; reject results, missing article, wrong namesake | B01–B05 |
| D02 | Find this page's support email and total due | Choose roles among observed email/amount candidates | Exact source spans; distinguish billing vs support, subtotal vs total; absent answer | B06, B08 |
| D03 | Show me where cancellation is explained | Select relevant section then passage | Highlight a source span; independent relevance labels; no policy on page | B07, B08 |
| D04 | Open this GitHub repo's latest stable release | Match owner/repo and release candidates | Actual repo/release; prerelease and dates ordered in code; no release exists | B09 |
| D05 | Fill registration and stop at review | Bind supplied values to controls/options | Actual values and review state; no submission; prefilled/styled controls | B11, B12 |
| D06 | Find products under $100 with these filters | Choose controls and categorical matches | Actual filter state and visible matching rows; currency, unavailable filter | B15 |
| D07 | Open NASA's channel, then the requested playlist | Select resource type and correct observed identity | Channel/playlist differs from similar video/results; dynamic readiness | B03, B04 |
| D08 | Switch to my release-notes tab | Select observed tab using relevant history | Exact tab ID; target beyond first 15 and duplicate titles | B02, B10 |
| D09 | Find official documentation, prefer technical discussions | Rank relevant results against user's preference | Labeled relevance and retained result IDs; commercial intent reverses preference | B16 |
| D10 | Find remote Flutter roles on these companies' sites | Select careers links, roles and source-backed fields | Correct listing, location and requirements; remote-only ambiguity | B17 |
| D11 | Compare these three products' price and returns policy | Navigate and collect fields/passages | Requirement coverage, exact quotes and currency; Grok synthesis labeled and counted | B18, B19 |
| D12 | Find the claim's source; show conflicts | Select supporting/contradicting passages | Quote presence in code plus independent support labels; misleading near-match | B19 |
| D13 | Run my saved registration flow with new values | Rebind semantic steps to current controls | Final predicates, no duplicated action, fresh parameter binding; layout changed | B13, B14 |
| D14 | Test this signup page for validation bugs | Follow an acceptance journey | Seeded valid/invalid behavior and state assertions; false bug reports count | B20 |
| D15 | Show how the models performed this task | Execute an identical fresh scenario per arm | Step events and outcome match capture; replay never executes actions | B05, B21, B22, B32 |
| D16 | Open the second one. No, the other one | Resolve a correction against the last observed choices | Exact intended target or clarification; stale/changed list and interrupted speech | B10, B23 |
| D17 | Highlight useful content and fold promotional clutter | Classify observed blocks | Labeled relevant blocks retained; full restoration; no security/tracker claim | B24 |
| D18 | Find dates that meet these booking constraints | Select date roles/options | Calendar math/timezone in code; impossible date, locale, unavailable option | B15, B27 |
| D19 | Ask this supported web app for last month's transactions | Select a declared read tool and bounded arguments | Site fixture tool log/result; no permission expansion, unsupported CEF reported | B25 |
| D20 | Complete this form with a custom dropdown and embedded field | Select supported controls through guarded observations | Actual field/control state; shadow root/frame boundary explicitly supported or rejected | B26 |
| D21 | Organize my saved posts into categories | Collect stable post IDs, extract source fields and classify batches | Unique-item recall, partial/end state, no duplicate records, resumable taxonomy version; source account unchanged | H01–H05, H07–H08, U01–U03 |
| D22 | Gather information from this website section | Traverse observed links, extract requirements and classify pages | Scope/frontier coverage, citation support, limits/traps, missing pages and crash recovery | H01–H06, H08, U01–U03 |

No real checkout, account creation, message sending, production submission or credential entry is required for these practice demos. Live smoke uses read-only public pages and a user-started isolated Jet run. On user-requested real tasks, existing task authorization governs; the lab does not create global permission rules.

The [Orca/T3 interaction audit](chat-and-hybrid-loops.md) separately grounds the unified chat and collection-loop UX. Its two pinned UI repositories supplement these ten browser references.

## Public project patterns to test

| Source | Small unit to inspect/adapt | First experiment | Port boundary |
|---|---|---|---|
| [FastBrowse](https://github.com/agent-labs-dev/fastbrowse) | Requirement/evidence linkage and event/recording shape | D11/D15 | Keep Jet's CEF and Grok; recreate events in its private service |
| [Ying-Kai-Liao/jev-browser](https://github.com/Ying-Kai-Liao/jev-browser) | Step outcomes, ambiguity, candidate field values | D05/D13 | Reuse Jet handles; no imported Playwright execution |
| [JevScout](https://github.com/hqman/JevScout) | Careers-link and job relevance questions | D10 | Generalize only after the job fixture works |
| [Sift](https://github.com/tylergibbs1/sift) | Several narrow result judgments combined in code | D09 | First show a ranked list in chat; DOM reordering is optional later |
| [Jev Voice Browser](https://github.com/moritzkremb/jev-voice-browser) | Recent actions and disambiguation choices | D16 | Start with text transcripts; no new audio service required |
| [TypeSafe Adblock](https://github.com/realZachi/typesafe-adblock) | Candidate block detection and highlight classification | D17 | Highlight first, reversible folding only after retention checks |
| [Jev QA](https://github.com/divyekant/jev-qa) | Scenario/checkpoint and measured conformance patterns | D14 | Own acceptance fixtures, exact assertions; no general visual-design claim |
| [JevTest](https://github.com/CorieW/JevTest) | Independent oracle and planted-bug evaluation concept | D14/D15 | Design inspiration only pending license; author new fixtures |
| [Jev WebMCP](https://github.com/jangya/jev-webmcp) | Finite selection of website tools | D19 | Capability spike before any browser-version or production support claim |
| [Jev Ultrafast](https://github.com/browser-use/jev-ultrafast) | Existing indexed action and separate typing design | D05/D06 | Extend existing code and provenance rather than replacing it |

## All eighteen official cookbook adaptations

The [official index](https://docs.typesafe.ai/llms.txt) still lists these 18 cookbooks at review time. Run each original recipe only when its dataset/code license, dependencies and costs are understood; original-domain reproduction is separate from the Jet adaptation. B27 records both statuses. Start with small legally reusable subsets or equivalent self-authored fixtures, then expand. Unsupported primitives are reported, never silently substituted.

| ID / source | Jet experiment | Measure / task |
|---|---|---|
| C01 [Noul consistency](https://docs.typesafe.ai/cookbooks/consistency_noul_cookbook) | Repeated/no-answer judgments on the same passage | Disagreement, abstention and added latency; B28 |
| C02 [Choice consistency](https://docs.typesafe.ai/cookbooks/consistency_choice_cookbook) | Paraphrase and candidate-order variants | Stability vs task correctness; B28/B29 |
| C03 [Parallel questions](https://docs.typesafe.ai/cookbooks/parallel_questions) | Independent role/resource/check questions on shared state | Actual wall time, forward calls and memory; B30 |
| C04 [Re-ranking](https://docs.typesafe.ai/cookbooks/rerank_typesafe) | Cheap lexical shortlist then semantic ranking | Candidate recall and ranking quality; B16 |
| C05 [Semantic find](https://docs.typesafe.ai/cookbooks/semantic_find) | Section/passages selected with a no-answer check | Correct span, false positive and latency; B07 |
| C06 [Structure recovery](https://docs.typesafe.ai/cookbooks/autoformat) | Label headings/lists/code in extracted page blocks | Exact text retained, block-label quality; B24/B27 |
| C07 [Function calling](https://docs.typesafe.ai/cookbooks/function_calling) | Select registered browser skill plus finite slots | Correct skill, missing-slot abstention; B03/B13 |
| C08 [Skill suggestion](https://docs.typesafe.ai/cookbooks/skill_suggestion) | Shortlist supported workflows before checking prerequisites | Recall and escalation cost; B28 |
| C09 [Entity alignment](https://docs.typesafe.ai/cookbooks/entity_alignment) | Alias vs related entity, channel vs video, duplicate product | Same/different/unknown labels; B09/B10 |
| C10 [RAG passages](https://docs.typesafe.ai/cookbooks/classifying_rag_passages) | Select relevant evidence for Grok, preserve conflict | Evidence coverage, discarded support, context size; B18 |
| C11 [Citation checking](https://docs.typesafe.ai/cookbooks/citation_check) | Quote presence plus claim support | False-supported claims and honest unknown; B19 |
| C12 [LLM guardrails](https://docs.typesafe.ai/cookbooks/llm_guardrails) | Detect suspicious page instructions in an owned fixture | Detection/false blocks; code permissions unchanged; B27 |
| C13 [Extraction cascade](https://docs.typesafe.ai/cookbooks/sde_cascade) | Verify extracted fields and escalate only unresolved ones | Exact field accuracy and total recovery cost; B06/B18/B28 |
| C14 [Date extraction](https://docs.typesafe.ai/cookbooks/date_extraction_cookbook) | Choose date components/roles then resolve in code | Locale, timezone, leap-day and absent-date cases; B15 |
| C15 [Pre-parsed values](https://docs.typesafe.ai/cookbooks/pre_parsed_value_extraction_cookbook) | Choose from verbatim email/phone/amount candidates | Correct role, exact copy, no invented values; B06 |
| C16 [Hierarchical classification](https://docs.typesafe.ai/cookbooks/hierarchical_classification) | Section → passage or site → resource → action | Recall under limits, ambiguity preservation; B02/B29 |
| C17 [Autoresearch features](https://docs.typesafe.ai/cookbooks/autoresearch_feature_discovery) | Offline question/feature tuning for skill choice | Train-only proposals, frozen validation/test; B31 |
| C18 [Confidence classification](https://docs.typesafe.ai/cookbooks/classification_using_confidence) | Back off to broader skill or abstain | Local coverage at observed error level; B28 |

Scores, probabilities and confidence are distinct and adapter-specific. An ordered Choice approximation is a labeled approximation, not a native Jev Score. Null confidence stays null. Do not combine normalized probabilities across independently scored chunks as a shared distribution.

## Experiment record

Every catalog entry records: source revision/license check; borrowed idea vs copied code; current Jet module; prompt/candidate version; supported model primitives; data/split/version; oracle; raw outcomes including failures; timings and costs; decision (keep, revise, unsupported, defer). No entry is considered tried because a package installed or a model returned a valid label.
