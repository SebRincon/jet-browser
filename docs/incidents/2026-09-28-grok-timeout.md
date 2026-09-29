# Grok authoring timeout — 2026-09-28

Status: diagnosed, unresolved. All times America/Chicago (CDT). This sanitized
record contains no bookmark text, credentials or provider reasoning content.

The user asked to organize the first 100 bookmarks with overlapping tags, summaries,
links and dates, reviewing every ten. The isolated packaged instance on port 9168
failed before creating a workflow.

| Time | Observed event |
| --- | --- |
| 20:56:23 | Local SemIf routing succeeded in about 366 ms and selected collection handoff |
| 20:56:23.973 | Grok ACP `session/prompt` began |
| 20:56:50 | `list_tabs`, `inspect_collection_source`, `workflow_sdk` completed successfully; permissions returned immediately |
| 20:57:55 | Last provider activity metadata; no later tool calls or completion |
| 21:01:23.976 | Hard 300-second deadline fired |
| 21:01:24 | Grok process terminated; error: `Grok timed out during session/prompt; no tool will be retried` |
| 21:02:07 | Native window closed normally, after the timeout |

Turn: `85e57134dbed4e439e5d1a76024d712c`; session:
`a275a4944c4145a1932158fdd07b7fb4`. The private trace remains in the isolated data
directory identified in [handoff](../HANDOFF.md); it is not part of this commit.

No `save_workflow` or `run_workflow` occurred. This session had no workflow or
collection records. Earlier collections in other profiles were not part of this
attempt. Local inference, tool permissions and native DOM execution all succeeded.
The logs do not establish a network outage, rate limit or the provider's root cause.

`GrokClient.prompt_timeout` is a wall-clock limit in `grok.py`; streaming does not
reset it. `_request` uses `asyncio.wait_for`; shutdown prevents late tool dispatch.
Provider stderr is intentionally discarded and reasoning content is excluded from
Jet traces. Preserve those privacy boundaries while adding safe activity/stage data.

Follow-up acceptance: author/save/start in bounded stages with visible progress;
test a stalled provider and cancellation; inspect saved state before recovery;
never replay an already-executed mutation. A longer timeout alone is not a repair.
