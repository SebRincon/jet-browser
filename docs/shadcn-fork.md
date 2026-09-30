# Independent Shadcn Flutter fork

Jet Browser uses the same `shadcn_flutter` working copy as vten, independently
vendored at `vendor/shadcn_flutter`. The application depends on it through
`path: ../vendor/shadcn_flutter`. There are no paths, links or runtime imports
back into vten.

Published as [SebRincon/shadcn_flutter_jet](https://github.com/SebRincon/shadcn_flutter_jet) and pinned here as
the `vendor/shadcn_flutter` git submodule. Source: `vibe-coder-app/shadcn_flutter` (private), Git revision
`8dc009e44cb915525243a07f7c6e705c0261f9ea`, package version `0.0.47`. The source was
dirty in `lib/src/components/form/select.dart`; that actual working-copy file was
preserved intentionally. The original source checkout was not changed. The local
copy includes library code, fonts/icons, tests, pubspec, original BSD 3-Clause
license, README and changelog. Its `PROVENANCE.md` records the source revision and the
dirty file; the submodule's commit SHA pins the exact content.

The app uses real `ShadcnApp`, Geist typography, `ThemeData(radius: 0.5)`, Shadcn
text fields, buttons, icons, tooltips and select popup. This follows vten's
`vten_ide/lib/theme/app_theme_data.dart`, `theme/chrome_colors.dart`,
`app/desktop_app.dart` and select patterns in `app/settings/ui/setting_row.dart`.
The app's dark default palette uses the same semantic sidebar/background/ring
roles, with high contrast foregrounds and visible field boundaries. Those vten
files were inspected as implementation evidence, not imported. The chat pane is
480 logical pixels wide at a 1400-pixel window and uses 15-pixel body text, clear
message authors, compact expandable action rows and a single comfortable composer. Short
conversations start at the top; streaming follows the bottom unless the user has
scrolled back to read history.

There is one Jet Assistant chat composer. Local routing decisions show the actual
model, decision, reason and elapsed time inline. Assistant messages identify their
source as Local or Grok. Browser tasks appear as inline expandable rows
with the actual local model, actions, timing and completion status. The settings
control chooses the browser action model, which is independent of routing. A
separate read-only router label comes from `provider.router_model` (the dedicated
SemIf 4B router in this version). A unified Stop covers local routing,
local execution and Grok, and cancels future browser input. The previous separate local-task composer
and run button were removed. The headless direct-task backend remains available
for integration checks only.

Chat history and New chat live in the same pane. The backend supplies the selected
session and saved session list; the UI creates/selects through `/sessions` and
`/sessions/select`. Switches are disabled during active work and refresh the full
selected-session state. A generation guard discards old heartbeat responses while
switching. Unsent drafts stay separate per session in memory, and a failed send
or switch preserves the draft. Durable saved conversations are owned by the
backend; unsent drafts are not claimed to persist across app exits.

The settings select popup is constrained to the right panel width. Header
tooltips open upward within the custom chrome. Chromium occupies only the left
content rectangle, leaving Shadcn interaction surfaces outside the native view.

## Markdown

`app/lib/chat_markdown.dart` follows the renderer pattern inspected in vten's
`lib/widgets/vten/common_widgets/app_markdown.dart`: `MarkdownGenerator` builds
selectable widgets with explicit paragraph, heading, list, code, link, blockquote
and table configuration. The exact `markdown_widget: 2.3.2+8` release is pinned in
the app pubspec and lockfile. Its transitive packages are resolved by Flutter;
there is no dependency on vten's Markdown component or IDE services.

Grok responses support formatted headings, emphasis, lists, inline code, fenced
syntax-highlighted code with an explicit Copy button, quotes and horizontally
scrollable tables. HTTP(S) links open inside Jet Browser. Other URI schemes are
ignored, and Markdown images become explicit open-image controls. Code is only
displayed or copied after a user click; it is never executed by the renderer.
The code and image controls are genuine Shadcn buttons. Flutter's `SelectionArea`
provides text selection, as it does in the inspected vten renderer.

Validation: app analysis, eighteen Flutter tests and the release build pass for
the vten-style chat/tracing update. Build log: `artifacts/native-build-vten-tracing.log`.
The running app is only restarted during coordinated integration. Tests cover
protocol-value preservation, the input-only allowlist, coordinate/key-command
preservation, startup errors and the actual single-composer Shadcn UI. The UI test
opens the real Shadcn select and verifies its `/settings` write, and expands an
inline task's real action list. Markdown tests exercise rendered headings/lists,
code copying, safe link routing, quotes and tables. Contrast checks require at
least 7:1 for primary text and 4.5:1 for metadata/accent text on all chat surfaces.
Session tests exercise Local/Grok labels, routing Stop, disabled competing
commands, actual history selection/New chat, isolation of messages and drafts,
failed-submit preservation and layout at a 390-pixel pane width. Native history
tests prove exact-tab navigation and reject stale/inactive handles.
The live native screenshot is `artifacts/native-shell-dark-markdown.png`; it shows
an actual Grok response and task card, with the practice form reset by Reload
after that conversation. Live browser/model results are recorded separately by
the backend integration checks. The previous light screenshot is retained as
historical evidence, not the current theme.

The session/routing release was launched and reconnected to the authenticated
service, with the previously visible Wikipedia page restored. Screenshot:
`artifacts/native-shell-local-sessions.png`. It shows the real restored
conversation, the Jet Assistant header/history controls and active local routing
with the unified Stop button. No model calls were made by the shell validation.

The current UI follows vten's actual message/tool/composer and session-list
sources more closely and includes a compact deep-trace viewer. See
`chat-interface.md` for exact source parallels, behavior and validation.
