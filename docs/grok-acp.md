# Grok chat adapter

`backend/jet_browser/grok.py` runs the installed Grok Build CLI as a dedicated ACP
stdio process. It does not connect to a vten session or use a CLI wrapper. Its
default executable is `~/.grok/bin/grok`; `JET_GROK_PATH` can select another native
installation. The implementation was grounded in the installed v1.0.41 docs and verified live
with 1.0.44 (2026-09-29). Jet uses the newest Grok available and keeps only a 1.0.41 floor; if a
later release changes the `_meta["x.ai/tool"]` identity, permissions fail closed (denied).

## Python contract

```python
client = GrokClient(
    cwd=project_path,
    mcp_command=[python_executable, str(project_path / "backend/jet_browser/mcp.py")],
    emit=append_event,
    trace=trace_callback,  # Optional: callback(event: str, **attributes).
)
await client.start()
answer = await client.prompt("Read the selected page and summarize it")
await client.cancel()
await client.close()
```

`start()` is idempotent and `prompt()` starts the client if needed. A prompt
returns the concatenation of its streamed assistant text when the ACP turn
finishes. Concurrent prompts are rejected instead of silently queued. The
service owns its visible chat queue and transcript. `emit` is a synchronous,
non-blocking callback on the service's asyncio event loop.

The constructor's `cwd` records the app's project context. The ACP session runs
inside a new private temporary directory instead of that project. Browser chat
does not require project filesystem tools. Pass an absolute MCP script/launcher
whose imports do not depend on the current directory.

| Event | Fields |
| --- | --- |
| Assistant text | `type: text`, `text` |
| Tool progress | `type: tool`, `tool_call_id`, `title`, `status`, `tool_name`, `kind`, `input`, `output`, `content` |
| Permission decision | `type: tool`, `tool_call_id`, `title`, `status: permission_allowed/permission_denied`, `tool_name`, `message` |
| Lifecycle | `type: status`, `status: starting/ready/thinking/cancelling/cancelled/closed`; final ready also includes `stop_reason` |
| Error | `type: error`, `message` |

Tool update fields are merged by ACP tool-call id, so a completion update keeps
the earlier title and input. Tool content and page results are untrusted data
for the UI to render as text. Agent thought chunks are not added to answers or
persisted by this adapter. Raw process stderr is drained without forwarding it
to the UI or logs. Credentials remain managed by Grok's existing login.

Errors raise `GrokError`. A stopped turn raises `GrokCancelled`, which subclasses
`GrokError`; the service should show it as stopped, not as a failed answer.
An externally cancelled Python task retains normal `asyncio.CancelledError`
behavior and shuts down the CLI so it cannot keep issuing tools.

## Provider trace contract

The optional synchronous `trace(event, **attributes)` callback answers three
diagnostic questions: did startup or the provider turn take the time, when did
the first answer text arrive, and which canonical tool was allowed or denied?
It receives metadata only. It never receives prompts, assistant text, thoughts,
tool input/output, display titles, stderr, environment values or exception
messages. Character counts describe Python text lengths, not token usage.
Identifiers are bounded to identifier characters; kind, status and reason
fields use bounded categories. Unknown display text cannot become an identity.

| Event | Principal attributes |
| --- | --- |
| `grok.provider.start` | Process startup attempt |
| `grok.provider.ready` | `duration_ms` for process startup and ACP handshake |
| `grok.provider.error` | `duration_ms`, exception class `error_type` |
| `grok.provider.close` | `duration_ms`, `return_code`, `forced_kill`, exception class `reason_type` |
| `grok.acp.request.send` | `method`, unique integer `request_id` |
| `grok.acp.request.end` / `.error` | Same method/id, `duration_ms`; errors add exception class `error_type` |
| `grok.acp.notification.send` / `.error` | `method: session/cancel`; errors add exception class `error_type` |
| `grok.permission.decision` | Request/tool ids, canonical `tool_name`, `tool_kind`, `identity_source`, `allowed`, `reason`, `level` |
| `grok.tool.update` | `tool_call_id`, canonical `tool_name`, `tool_kind`, `status`, `identity_source` |
| `grok.prompt.start` | `input_characters` |
| `grok.stream.first_text` | `duration_ms` from accepted prompt to first nonempty answer text |
| `grok.stream.text` | Per-chunk `characters`, cumulative `total_characters` and `chunks` |
| `grok.prompt.end` / `.error` / `.cancel` | `duration_ms`, `text_characters`, `text_chunks`, `tool_calls`; respectively `stop_reason`, `error_type`, or `reason` |
| `grok.prompt.cancel_requested` | Explicit cancellation was requested |

Permission reasons distinguish allowed browser/read-only web tools, missing
programmatic identity, rejected tool identity, missing `allow_once`, a foreign
session, no active turn, and a cancelled turn. Denials carry `level: warn`;
allowances carry `level: info`. Diagnostic identity does not grant permission;
the exact permission guard remains authoritative. Error events end in `.error`
so the trace store can give them error severity without logging error prose.

The service owns turn/span correlation and may replace public `client.trace`
before each reused turn. Every event reads the current callback, including
events from the persistent stdout reader. The callback should capture the
current service context; this adapter does not create another context layer.
Callback exceptions, including cancellation exceptions, cannot change provider
behavior. A trace sink should remain non-blocking. First-text latency includes
startup when `prompt()` starts a new process; the provider lifecycle events
separate that cost. Chunk counts reset for each accepted prompt and exclude
thought updates. The trace store separately sanitizes and retains these fields.

## Process and tool scope

Launch arguments are process-local:

```text
grok --permission-mode default --no-subagents
  --deny Bash --deny Edit --deny Write
  agent --no-leader --agent-profile <private-temporary-profile> stdio
```

The generated agent profile declares `search_tool`, `use_tool`, `web_search`,
and `web_fetch` only, disables project `AGENTS.md` injection, and contains the
browser task rules. Its private temporary directory is removed on shutdown.
The installed CLI documents `--tools` as a headless `-p` filter, so this ACP
adapter uses the documented agent-profile mechanism instead. Native shell/file
mutation denies supplement the profile; no always-approve flag or persistent
grant is installed. Available web features still depend on the CLI's model and
configuration.

The private session directory also contains exactly this generated project
permission configuration:

```toml
[permission]
ask = ["MCPTool(*)"]
```

Grok's documented rule ordering puts `ask` ahead of configured `allow` rules.
Remembered grants can satisfy an ask rule, so each process receives a fresh
temporary working directory with no previous project grants. The adapter only
selects `allow_once`, never creating remembered grants. `GROK_FOLDER_TRUST=0` is
set in the child process environment so this code-owned folder's configuration
loads without writing a persistent folder-trust grant. It does not change the
service's environment or the user's global settings. The folder contains no
user project files, hooks, copied credentials, or source checkout.

`initialize` negotiates protocol version 1 without filesystem or terminal
client capabilities. `session/new` supplies the working directory and one
per-session stdio MCP server named `browser`, with the provided executable,
arguments, and an empty environment override list. The MCP child inherits the
service environment through Grok; keep its authentication in private local
state rather than command-line credentials.

This client selects `allow_once` for these exact browser MCP identities:

```text
browser__list_tabs     browser__open_url     browser__read_page
browser__run_task      browser__task_status  browser__stop_task
browser__browser_action                   browser__conversation_history
```

Requested information gathering also permits the two native read-only tools
`web_search` and `web_fetch`. Standard ACP canonical `name` values are accepted;
Grok's extension form must carry `version: 1`, `namespace: grok_build`, matching
`name`/`kind` equal to one of those two tools, and `read_only: true`. Conflicting
identity is denied. A `read_only` flag alone does not authorize any other tool,
including filesystem reads or foreign MCP integrations. The selected option
is always the provided `allow_once` id, never a remembered domain grant.

Both a directly qualified ACP `name` and `name: use_tool` with an explicit
inline `rawInput.tool_name` are recognized. Grok v1.0.41 omits the top-level name
on its MCP permission requests: the verified runtime shape supplies
`_meta["x.ai/tool"]` with `version: 1`, `namespace: grok_build`, and
`name`/`kind: use_tool`, plus `rawInput.variant: UseTool`. That exact extension
shape also establishes the dispatcher identity; the inline tool name must
still match the eight-tool allowlist. Conflicting top-level identity, a foreign
namespace or a different variant is rejected. The supplied `optionId` is returned,
never an invented id or an allow-always option. Display titles, page text,
substring matches, foreign tool names and file-backed invocation envelopes do
not establish ownership. Missing identity or an unrelated tool produces a
denial event with an actionable explanation. Unsupported client methods return
JSON-RPC method-not-found; this client cannot supply a terminal or write files.

Grok may still discover globally configured MCP integrations; this is an
execution permission gate, not an exclusive catalog. The private ask rule sends
their calls through the same exact tool guard even if a global allow rule
exists. Unrelated calls are denied. This adapter does not rewrite global
settings, disable managed hooks, or present itself as an OS sandbox. The app's
MCP server and task controller must enforce browser identity, cancellation and
user scope independently of the chat model's text.

## Delegation and stopping

The session rules tell Grok to obtain actual tab handles, delegate a bounded
natural-language goal with user-provided values, inspect returned page evidence,
and distinguish model `DONE` from independent verification. No generated
JavaScript, selectors or hand-authored browser action sequence enters the
public tool API. Failed browser mutations are not retried by the adapter.
Grok omits the `model` argument unless the user names one, so a local task uses
the current model selected in the browser settings.

Local routing and Grok participate in one saved conversation. Simple supported
app actions may complete locally before Grok is called. Grok receives the
shared context and can use `conversation_history` for older messages and task
results, or `browser_action` for supported observed app controls. History does
not authorize new operations: a completed task is not repeated unless the
current user requests it. The service supplies the full current request
separately from the bounded history.

## Durable shared history

`ConversationStore(root)` in `backend/jet_browser/sessions.py` creates
`.runtime/conversations.sqlite3`. The runtime directory and database are
owner-only (0700/0600). Each write commits a SQLite transaction; the selected
conversation, streamed messages, local task outcomes and route decisions
survive a service restart. Provider sessions remain separate: a restarted Grok
process receives app history through context rather than an undocumented ACP
session-restore operation.

| Method | Result/behavior |
| --- | --- |
| `current_id` | Property containing the persisted selected conversation id |
| `session(session_id=None)` | Reads session metadata without changing the selected conversation |
| `create(title='New conversation')` | Creates and selects a conversation; returns `{id,title,created_at,updated_at}` |
| `list(limit=50)` | Sessions ordered by most recent saved activity; limit 1–500 |
| `activate(id)` | Selects an existing conversation and returns its session record |
| `messages(session_id=None)` | Full messages in timestamp/insertion order |
| `save_message(message, session_id=None)` | Upserts by id, preserving source and original timestamp during streaming |
| `tasks(session_id=None)` / `save_task(task, session_id=None)` | Read/upsert local task records and actual results |
| `routes(session_id=None)` / `save_route(route, session_id=None)` | Read/upsert routing records; generates route id/time when omitted |
| `context(prompt,browser,session_id=None,max_chars=14000)` | Returns bounded, labelled history/evidence using prompt terms for recall |
| `close()` | Closes the SQLite connection |

The constructor restores the selection or creates an initial empty conversation.
The first nonempty user message names an untitled conversation; an explicitly
chosen title is preserved. Record saves return the merged persisted dictionary,
including its authoritative `session_id`. Messages require `id`, `role`, and
`text`; missing creation times are assigned automatically. Tasks require `id`.
Unknown conversation ids are rejected by every session-scoped operation.

Context gives separate space to recent messages, relevant older messages,
recent local results, current browser evidence and recent routes. Relevant
recall uses lexical matching within the selected conversation and excerpts near
the matching words. It is deterministic retrieval, not semantic embeddings or
a model-written memory. Long records are visibly shortened to keep the output
within `max_chars`; the complete originals remain available through history.
The input `prompt` is a retrieval query, not copied or truncated into an
instruction to execute. Historical/page text is marked untrusted context.
Synchronous methods are intended for the service's event-loop thread.
Route context prioritizes the actual observed page title, URL and text snippet,
then includes the concise requested plan and outcome. Large native probability
audits and action arrays stay in the complete saved route record.

`cancel()` first marks the turn stopped and sends the ACP `session/cancel`
notification. Further permission requests receive no approval. If the CLI does
not finish within five seconds, it is terminated; all waiting requests are
resolved. Startup requests have 45-second deadlines and a turn has a five-minute
ceiling. A turn also ends after 150 seconds with no provider message while no tool
call is running (`idle_timeout`). Reasoning chunks, text, tool updates and Grok's
`_x.ai/session/update` extension all count as activity; reasoning text itself is
never stored or traced, only chunk and character counts. Grok 1.0.41 does not stream
the arguments of a tool call it is still generating, so `idle_timeout` must stay
above a bounded argument generation. Both limits raise `GrokStalled` with a safe
`stage` and the names of completed tools. The service then reads saved workflow and
collection state and reports what was actually saved or started. It never replays
the turn. The UI label follows the same stage metadata. The service must **also stop its local task worker**, because a
browser operation already dispatched through MCP may outlive the chat request.
Stopping cannot undo an input already sent to the browser.

One continuous stdout reader dispatches notifications, responds to permissions,
and correlates responses with unique request ids. EOF, process exit, invalid
protocol data and timeout settle outstanding requests rather than hanging the
UI. A later explicitly requested turn can start a new process after transport
failure, but no failed turn or tool is replayed automatically. A new process
starts a new ACP session; chat context is not automatically rehydrated.

## Checks and authoritative references

Run the fake protocol tests without provider access:

```sh
uv run --project backend pytest backend/tests/test_grok.py -q
uv run --project backend ruff check backend/jet_browser/grok.py backend/tests/test_grok.py
```

Tests cover interleaved streaming/response correlation, merged tool updates,
exact permission identity and option ids, denied client methods, cancellation,
concurrent-turn rejection, startup timeout, silent-provider and ceiling stalls,
running-tool idle suspension, process exit, stderr isolation and
the private permission configuration/child-only environment override. Trace
tests cover request pairing, first-text timing, counts, denial diagnostics,
private-content exclusion, per-turn callback replacement, sink failure and
success/error/cancellation terminal events using fake streams only.
They do not prove a live provider login or the runtime CLI tool catalog; those
are separate, serialized integration checks recorded in the main project docs.

A read-only native v1.0.41 `grok inspect --json` check in a generated empty
directory confirmed `projectTrusted: true`, one loaded permission source and
zero skipped sources with the child-only trust setting. This check made no
model request; actual unrelated-tool denial is part of the live integration.

One explicitly authorized read-only Grok turn subsequently discovered and called
`browser__list_tabs`. It received `allow_once`, returned the actual browser tabs,
and completed its answer. The private diagnostic is under
`.runtime/grok-permission-check/`; no navigation or local model inference was
performed. The captured extension shape is covered by protocol tests, including
foreign MCP names, conflicting metadata and file-backed calls that stay denied.

A separate authorized read-only `web_fetch` turn read the fixed Wikipedia URL
`https://en.wikipedia.org/wiki/Elon_Musk` and returned its page title. Its native
permission request had no top-level `name`; it supplied the exact Grok metadata
above with `name`/`kind: web_fetch`, `read_only: true`, and
`rawInput: {variant: WebFetch, url: ...}`. The same paused request completed after
the narrow permission fix. Small sanitized identity/outcome diagnostics are
under `.runtime/grok-web-permission-check/`. No app tab, conversation selection,
or local browser model was operated by that check.

- Installed Grok references: `~/.grok/docs/user-guide/15-agent-mode.md`,
  `07-mcp-servers.md`, `14-headless-mode.md`, `16-subagents.md`,
  `22-permissions-and-safety.md`, and the native `grok --help` output.
- [ACP initialization](https://agentclientprotocol.com/protocol/v1/initialization)
  defines version negotiation and capability advertisement.
- [ACP tool calls and permissions](https://agentclientprotocol.com/protocol/v1/tool-calls)
  define partial updates and permission outcome/option identifiers.
- [ACP prompt lifecycle](https://agentclientprotocol.com/protocol/v1/prompt-turn)
  defines streamed replies, final stop reasons and cancellation notifications.
