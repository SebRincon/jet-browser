# Desktop UX and harness improvement

The user requested a cleaner, more usable application with extensive testing. Preserve the locally vendored shadcn_flutter and vten chat presentation, one composer, Markdown, dark workbench colors and session memory.

## Findings and acceptance

- The browser shell reserves a fixed 390/480 px for chat. Add a resizable and collapsible split, maintain the chat instance so drafts and transcript position survive, clamp both panes and test short/narrow windows.
- Browser commands need familiar keyboard support and readable focus: Cmd+L selects the address, Cmd+T creates a tab, Cmd+R reloads. Loading should be visible without a distracting overlay.
- Empty chats should offer a few concrete editable examples. Clicking an example fills the composer; it must not silently submit or replace a draft.
- Local task rows should name the goal and show full elapsed time when available. Navigation proof and semantic assessment must stay distinct. Stopped work must not look successful.
- Busy state should reflect the backend's authoritative busy flag. Preserve Stop during routing/provider startup, block duplicate sends, retain failed drafts, and make the current phase understandable.
- History needs title search, selected-session indication and useful empty/no-match states. Drafts and manual scroll must survive session changes and incoming streamed content.
- The harness must check observed page identity independently, retain partial failures, identify its own turn/session/tab, avoid mutation retries, restore prior selection only when still owned, and never read credentials on import or --help.

## Verification contract

Behavioral widget tests cover resize/collapse, keyboard focus, editable examples, history/drafts, busy/Stop, failed send, progress/outcomes and narrow/short layouts. Run all app and vendored chat tests plus both analyzers. Build release, inspect the real native app, and exercise the same navigation harness with genuine local inference. Keep the user's active chat intact; do not restart a busy service or app.

The initial native screenshot was captured through Orca because the Cua native pipe failed twice. The existing UI uses the requested dark vten chat but leaves little room for inspecting progress. Screenshot inspection does not replace interaction checks on the final build.

## Implemented behavior

The shell now has a clamped resizable chat split and an address-toolbar collapse button. Hidden chat is excluded from focus/semantics while the same instance retains drafts and scroll. The compact shell includes loading progress. Native macOS Cmd+L/T/R commands cross a small app-owned channel to the same Flutter actions; exact chords are scoped to the key window and duplicate dispatch is guarded.

Empty conversations offer four editable examples, hidden when a draft exists. History supports case-insensitive title search and marks the current session. Backend busy state controls Send, session switching and Stop. Current-turn phases and task titles describe opening/checking/handoff; completion wording distinguishes structural proof, local semantic assessment, manual verification and stopped work. Markdown and the actual vendored vten components remain intact.

Automated validation: 27 app tests, 9 vendored-chat tests, both analyzers clean, and a successful 349.8 MB macOS release build. The fake-host widget checks cover draft/scroll preservation, resizing/collapse, narrow/short windows, native-channel dispatch, history, examples, failed sends and busy/Stop behavior. The separate backend suite and real navigation harness provide controller coverage; widget tests alone do not prove native keyboard behavior.
