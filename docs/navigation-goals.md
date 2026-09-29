# Navigation goals: acceptance contract

This increment gives local navigation an explicit finish condition. It covers known-site homepages and YouTube destinations while retaining the Wikipedia completion checks. The implementation lives in `navigation.py`, `navigation_completion.py` and `conversation.py`; the independent native runner is `scripts/check_navigation_goals.py`.

## Required behavior

- Plain homepage requests for Wikipedia, YouTube, GitHub and Google use code-owned URLs, skip query extraction and check the observed homepage. Extra instructions and negation do not enter this shortcut.
- Each navigation plan preserves the original request, provider, requested resource kind, tab and grounded query or supplied URL. A helper query cannot prove that the entire request was satisfied.
- YouTube results, videos, channels and playlists have different structural checks. A results page cannot complete a video request; a video playing inside a playlist cannot complete a playlist-page request. Identity is assessed from current page evidence, separately from structural proof.
- Link selection uses observed hrefs in bounded finite choices. It rechecks the document and href before navigation. Stop fences later actions. A failed mutation is never retried automatically.
- Empty or stale page shells are observed for a bounded interval. Wrong sites, consent/sign-in/unavailable pages, missing links and uncertain identity retain a failure reason and hand off without claiming completion.
- Live checks use their own conversation and tab, retain failures and restore prior selections only while they still own the app context.

## Verification scope

Offline regression tests must cover wrong page kind/site, query shortening, negation/compound requests, stale state, Stop and bounded choices. Explicit local integration checks must retain timings and Grok-call counts for four homepages and YouTube results/video/channel/playlist. Existing Wikipedia regressions must remain green.

General form completion, local extraction, GitHub repository/release workflows and model calibration remain separate work. Successful navigation does not establish video playback or authentication reliability.

## Example requests

| Request | Required destination |
| --- | --- |
| Bring me to YouTube | YouTube homepage |
| Go to GitHub | GitHub homepage |
| Open NASA's YouTube channel | NASA channel, not its search results or a video |
| Find a YouTube video about Artemis | A matching video page |
| Open a NASA playlist on YouTube | A matching playlist page |
| Show YouTube search results for NASA | The results list, without opening a result |
| Open YouTube and summarize the latest news | Preserve both parts; homepage arrival alone is insufficient |

YouTube documents separate content filters for videos, channels and playlists in its [advanced search help](https://support.google.com/youtube/answer/111997?hl=en-GB). This implementation works through the native browser, not the YouTube Data API. Search filters and DOM shapes may change, so observed links and live page checks remain necessary.

## Baseline observations (before this increment)

The real local router/helper produced a search for the literal words “Bring me to YouTube,” rejected the extracted query for “Open NASA's YouTube channel,” sent a playlist request to generic page actions, and handed “Find a YouTube video about Artemis” to Grok before browser work. These are planning probes, not full browser attempts. Evidence: `artifacts/navigation-goals-baseline.json`.

Native preflight captures confirm the site exposes actual channel/video links, separate “View full playlist” links, and destination headings. A video URL can drop tracking parameters after navigation. Playlist text can say “Unavailable videos are hidden” even while the playlist itself is valid; this must not be treated as a missing playlist. Captures: `artifacts/youtube-search-preflight.json`, `youtube-resources-preflight.json`, `youtube-destinations-preflight.json`.

## First native run — retained failures

`artifacts/navigation-goals-native-20260928T053955Z.json` recorded 5/8 passing cases: all four homepages and explicit YouTube search results, with zero Grok handoffs on those passes. Homepage elapsed time was 354–1,867 ms, including native browser work. The channel reached the correct page but failed canonical identity comparison (`/@NASA` versus `/channel/...`). Video and playlist routes declared completion while visible headings were still empty. The independent harness rejected both; these are failures, not passes.

The fix waits for visible heading/title agreement and ties channel aliases through the current page renderer's channel metadata. Canonical tags alone cannot complete an empty or stale page. `artifacts/navigation-goals-native-20260928T054945Z.json` subsequently passed 8/8 with zero Grok handoffs. Elapsed times include cold load, network and native observation; they are not a model throughput leaderboard.

A later eight-case repeat (`navigation-goals-native-20260928T060343281204Z-2e4883c8bc114306bcc44e1b4169bc30.json`) passed 7/8: a correct Artemis video was rejected by the semantic identity question. The harness retained the failure and stopped the Grok handoff. Supplying the grounded requested subject and resource kind improved the controlled title probes from 11/13 to 13/13, including rejection of a fan channel. These are development probes, not held-out accuracy; see `youtube-identity-development-probe.json`.

The reusable harness checks final page identity independently, saves partial rows and cleanup errors, handles per-turn cancellation, and yields if a new user turn takes over even in the same session/tab. Its artifacts are uniquely named. Import and `--help` do not contact the service. General page-task DONE remains `manual_check`.
