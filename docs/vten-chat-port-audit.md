# Vten chat port audit

Published as [SebRincon/vten_chat](https://github.com/SebRincon/vten_chat) (pinned as the `vendor/vten_chat`
submodule). Source: vten.ai (private repository) at
`cc497919140469d58c71849f44210e35c3206766`. Chat sources were clean. Nothing in
that checkout is edited or imported at runtime. Recorded `origin/main` is newer;
this port follows the local UI at the SHA above.

Jet previously redrew the transcript by hand in `app/lib/chat_widgets.dart` and
`app/lib/agent_pane.dart`. That adaptation added an 18px "Jet Assistant" header,
a connection subheader, a "Local" or "Grok" label on every reply, a "Copy
response" text button, always-visible route and task rows, a sentence-style
working status, and a brighter color scheme than vten's 2026 dark tokens. The
complaint is about that extra chrome, not about a missing tint.

## Dependency boundary

Reusable presentation lives under `lib/widgets/vten/features/chat/` plus
`lib/widgets/vten/common_widgets/`, `lib/widgets/vten/common/chrome_icon_button.dart`,
`lib/widgets/vten/chat_ui_config.dart`, and `vten_ide/lib/theme/vscode_2026_colors.g.dart`
with `vscode_color_scheme.dart`.

Those widgets are wired to Riverpod session providers, the ACP message model
(`Message`, `ToolCall`, `ToolResult`), IDE tool renderers, permission prompts,
checkpoints, attachments, slash commands, and design/pinpoint modes. Copying that
graph would pull the IDE into Jet. The package `vendor/vten_chat` keeps the
rendering code and replaces provider reads with constructor arguments. Jet's
`AgentPane` is the only host adapter. It still talks to `BrowserHost`.

`ChatSessionTab` is the layout the IDE actually mounts: transcript, 1px divider,
8px inset, `EnhancedPromptInput`. `VtenAgentChatView` is the package shell around
that column (12px inset, sidebars, plan, terminal, permission overlay). Jet
follows the tab, and mounts the agent view's turn indicator inside the tab's
8px inset.

## Per-component decisions

| Source | Decision | Why |
| --- | --- | --- |
| `vten_ide/lib/app/editor/tab_views/chat_session_tab.dart` | Adapt | Keep the column, divider, and 8px `Listener` inset. Drop `ProviderScope`. |
| `lib/widgets/vten/features/chat/vten_agent_chat_view.dart` | Omit shell | Sidebars, plan, todos, terminal, ask-user, and permission overlays are IDE surfaces. Keep `TurnActivityIndicator` placement. |
| `widgets/message_list.dart` | Adapt extract | Keep reverse list, 8px padding, 672px column, hidden scrollbar, bottom button, per-session offsets, and the source pinned-prompt geometry (group spanning the top, user row offscreen, tap scrolls that row). Drop Codex review, compaction, and debug jump. Session restores capture the session id so a stale callback cannot write another session's offset. |
| `widgets/message_bubble.dart` (`UserMessageBubble`, `AssistantMessageFooter`) | Adapt extract | Keep the input-toned 560px bubble, 100px clamp, 14px text, and 24px icon footer. Replace the full-message dialog with in-pane expansion so a popup cannot cover CEF. Drop checkpoints and attachment chips. |
| Assistant prose in `MessageBubble` | Adapt | Source renders `AppMarkdown` with no role label. Jet passes its link-opening markdown into that slot. No "Local"/"Grok" row. |
| `widgets/tool_call_action_wrapper.dart` | Adapt extract | Keep both compact rows and the vten compact style. Feed a typed summary instead of `ToolCall`. Show a destructive badge on failure; the vten row alone hides errors. |
| `widgets/collapsible_steps_widget.dart` | Retain | Import rewrite only. Finished successful steps sit behind it. |
| `widgets/turn_activity_indicator.dart` | Adapt | Same `DotMatrixLoader` (16px, 5×4). `busy` comes from the host instead of `isSessionBusyProvider`. |
| `widgets/prompt_input.dart` `EnhancedPromptInput` | Adapt extract | Keep the input-colored 10px card, 13px field, stop square, and footer row. Drop attachments, slash menus, modes, pinpoint, priming, and cloud send. The focus ring listens to the focus node. Enter does not send while an IME composition is active. |
| `widgets/compact_config_selector.dart` | Adapt extract | Keep the muted model chip. Drop Claude/Codex/Pi mode and effort popovers. The chip opens an in-pane browser-model card. |
| `widgets/exploring_group_widget.dart` and `action_widgets/*` | Omit | They render IDE file, shell, and MCP tools. Browser tasks use the compact row plus an expanded detail child. |
| `widgets/styled_message_text.dart`, `chat_ui_config.dart`, `tool_call_expansion_control.dart` | Retain | No IDE imports. |
| `common_widgets/animated_collapse.dart`, `press_scale.dart`, `text_shimmer.dart`, `dot_matrix_loader.dart` | Retain | Presentation only. |
| `common/chrome_icon_button.dart` | Retain | Header history, new chat, and diagnostics use it. |
| `common_widgets/app_markdown.dart`, `code_block_wrapper.dart` | Omit copy | `AppMarkdown` needs the syntax highlighter and a global navigator toast. Jet `ChatMarkdown` keeps link opening and copies the 14/16/13px metrics. Body stays full foreground so `#bfbfbf` is not washed to 80%. |
| `vten_ide/lib/theme/vscode_2026_colors.g.dart`, `vscode_color_scheme.dart` | Retain | `jetTheme()` uses this scheme. Drop the previous brighter foreground, muted, primary, and border overrides. |
| `widgets/session_list_item.dart` | Omit | Provider-backed IDE session row. History stays an in-pane list with the same session ids and drafts. |
| Permission, ask-user, thinking, system message widgets | Omit | Jet has no IDE permission stream. Failures and handoffs stay in the transcript. |

Keyboard note: at this SHA, `_handleKeyEvent` sends on Meta/Ctrl+Enter and lets
the multiline field insert a newline on Enter. The requested composer behavior
is Enter to send, Shift+Enter for a newline, with Meta/Ctrl+Enter still sending.
That is an intentional host binding, not what the source handler does today.

Theme note: 2026 dark background is `#121314`, foreground `#bfbfbf`, sidebar
`#191A1B`, muted text `#8C8C8C`, button `#297AA0`. White on that button is about
4.8:1. The old Jet test required 7:1 and forced brighter tokens. Body and muted
text stay on the source colors when they clear 4.5:1. Primary is a button fill,
not small text on the page background. Links use the source markdown blue
`#60A5FA`.

## What the host still owns

`AgentPane` maps `/state` messages, routes, and tasks into turns. A successful
local route is omitted when the same turn already has a browser task. A Grok
handoff stays visible as its own row. Failures stay visible and are not folded
into the steps disclosure. Diagnostics stay on `TracePanel`, closed until the
header control opens them. One composer remains. Stop still calls `/chat/stop`.
Drafts and scroll offsets stay per session. The composer and header call
`blurBrowser` before taking focus.

## Parity checklist

- [x] Pane is `MessageList`, 1px divider, 8px inset, one `EnhancedPromptInput`.
- [x] Transcript column max width is 672. User cards max width 560, 14px, 12px radius, input-toned fill.
- [x] Assistant text is plain markdown with an icon copy control and no role label.
- [x] Finished successful tools collapse behind `CollapsibleStepsWidget`. Pending rows use `TextShimmer`. Busy turns show `DotMatrixLoader`.
- [x] Composer text is 13px. Send and Stop sit inside the card. Model chip is the footer.
- [x] Enter sends, Shift+Enter inserts a newline, Meta/Ctrl+Enter sends.
- [x] No second composer, no attachment or mode controls, no "Jet Assistant" title.
- [x] History, new chat, drafts, manual scroll, and Latest still work.
- [x] Trace load, copy, and stale-session protection still work, behind the header.
- [x] Narrow (360) and wide (800) panes lay out without overflow in widget tests.
- [x] `flutter analyze` is clean for the app and `vten_chat`. App tests: 21 passed. Package tests: 9 passed. Release build log: `artifacts/native-build-vten-direct-port.log` (349.7MB, EXIT:0). Review-fix logs are `artifacts/review-fix-*.log`. Native visual QA is not part of this lane.
