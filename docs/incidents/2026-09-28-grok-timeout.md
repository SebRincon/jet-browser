# Grok authoring timeout — 2026-09-28

Status: mitigated 2026-09-28 (see Follow-up below); provider root cause unknown. All times America/Chicago (CDT). This sanitized
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

## Follow-up — 2026-09-28

Grok's own local session log (inspected structurally; no content copied) shows the
model entered `streaming_reasoning` 0.9 s after `workflow_sdk` returned and changed
reasoning segments until 20:57:55. It then logged nothing for 3 min 29 s: no text,
tool call or turn end. Jet's trace had no event after 20:56:50 because reasoning
chunks were discarded without a count. Grok 1.0.41 also does not stream the
arguments of a tool call while generating them, so a model writing a large
`save_workflow` script looks identical to a stall from the client.

Repairs in this change series:

1. `GrokClient` ends a turn after 150 s with no provider message while no tool is
   running, and keeps the 300 s ceiling. Both raise `GrokStalled` with the stage and
   completed tool names. Reasoning volume, stage changes and quiet time are traced
   without content; Grok's `_x.ai/session/update` extension now counts as activity.
2. After any provider failure, the service reads durable workflow/collection state
   and tells the user exactly what was saved or started. It never replays the turn.
3. The chat status names the stage, such as "Grok is writing the workflow".

For this incident's timeline, the new client would have ended the turn at about
21:00:25 with "no provider activity for 150 s while writing the workflow" and
reported that nothing was saved or started. Reducing how much the model must write
is tracked separately (built-in workflow templates). A real provider rerun is still
needed to confirm the repaired flow end to end.
