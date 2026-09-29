# Chat interface

Jet renders the vten agent chat from `vendor/vten_chat`. The package is an
independent fork of the presentation widgets at vten
`cc497919140469d58c71849f44210e35c3206766`. There is no runtime import of the
vten checkout. The audit and retain/adapt/omit table are in
[vten-chat-port-audit.md](vten-chat-port-audit.md).

The pane is `ChatSessionTab`: `MessageList`, a 1px divider, and an 8px inset
around `EnhancedPromptInput`. `TurnActivityIndicator` (the dot-matrix loader)
sits in that inset while a turn is running. The transcript column is 672px
wide. User text is the source input-toned card, at most 560px, 14px type, 12px
radius. Long prompts expand inside the card. Assistant text is markdown with
the 24px icon copy footer. There is no role label and no "Jet Assistant"
header.

Finished successful local tools fold into `CollapsibleStepsWidget`. A Grok
handoff stays as its own compact row. Failures keep the destructive badge and
the error text. Pending titles use `TextShimmer`. The model chip opens the
browser action-model card in the pane. Enter sends, Shift+Enter inserts a
newline, and Command-Enter or Control-Enter also sends.

History, new chat, per-session drafts, and per-session scroll offsets stay.
Scrolling away from the latest edge shows the source bottom button (Latest)
and keeps that offset while tokens stream. The pinned prompt is the user line
of the group spanning the top of the viewport after that row has scrolled off;
tapping it brings the row back. Diagnostics, history, and model settings are
mutually exclusive and height-capped. A disconnected service shows a one-line
notice and disables Send and Stop. Copy ID, Copy trace, retained-event loading,
and stale-session protection are unchanged.

Popups stay inside the Flutter column. The composer and header blur the native
view before taking focus. The Flutter isolate does not spawn processes.

## Theme

`jetTheme()` uses the copied `vsCodeColorScheme` on the 2026 dark workbench
map. Background `#121314`, foreground `#bfbfbf`, sidebar `#191A1B`, muted text
`#8C8C8C`, button `#297AA0`. Body text stays at full foreground. Links use
`#60A5FA`.

## Verification

Review fixes cover stale session restores, stable turn keys, the focus ring,
IME Enter, pinned-prompt geometry, a disconnected notice, and short-pane
inspectors. Logs with exit codes: `artifacts/review-fix-app-analyze.log`,
`artifacts/review-fix-app-test.log`, `artifacts/review-fix-package-analyze.log`,
`artifacts/review-fix-package-test.log`, and
`artifacts/native-build-vten-direct-port.log`. Visual and native QA belong to
the root pass; this lane does not launch the app.
