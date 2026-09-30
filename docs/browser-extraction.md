# Native browser extraction

Jet Browser is an independent Flutter macOS application. Its CEF plugin, headers,
wrapper library, framework, renderer helpers and profile are inside this project.
The vten app and its daemon are not runtime dependencies.

## Source evidence

The plugin was copied from
`vten/deps/webview_cef/flutter_cef_browser` at
`a14b590260a0ed334a7a089db0f733f5818bc0c9` (the source submodule was clean).
The initial plugin copy preserved the original sources. A small additive local patch
now provides acknowledged native-view input dispatch; see below. the plugin's `PROVENANCE.md` ([SebRincon/flutter_cef_browser](https://github.com/SebRincon/flutter_cef_browser))
records SHA-256 hashes of 553 copied regular files. The macOS Runner was seeded
from that plugin's `benchmark_app/macos`, preserving its CEF helper copy/sign
phase, then renamed to `Jet Browser` / `dev.sebastian.jetbrowser`.

The existing `include` and `libcef_dll_wrapper.a` links pointed outside the plugin.
Their resolved contents were copied as real files/directories. Framework-internal
relative links are retained; no link in the vendored package resolves outside it.
The copied framework is CEF 147.0.11 / Chromium 147.0.7727.138, macOS arm64. Its
original artifact manifest is retained as historical build evidence; absolute
paths in that manifest are not used at runtime. CEF `LICENSE.txt` and
`CREDITS.html` were copied from the exact matching local source distribution.
The plugin's original BSD 3-Clause `LICENSE` is retained.

Large native assets remain local and git-ignored. This local checkout is
standalone and buildable. A future remote clone must receive those matching
assets through an explicit binary distribution/bootstrap step; no unpublished
asset-download URL is claimed here.

## Native architecture

The shell uses CEF `nativeView`. Its Chromium rectangle is measured from the left
content pane after Flutter layout. The address bar, tabs and right agent panel
are outside that rectangle, so Chromium does not overlap Flutter controls.
Background tabs are hidden and retain their own browser identity. Tab close
invalidates that identity. Popups with HTTP(S) URLs open as visible tabs.

The app reads `.runtime/token` before initializing CEF and uses one authenticated
loopback client on port 9148. The profile is `.runtime/browser-profile`; remote
CDP remains disabled (`remoteDebuggingPort: 0`). No app code launches a process.
The launcher starts Python/model/provider sidecars outside this CEF process.

`JET_ROOT` can be compiled with `--dart-define=JET_ROOT=/absolute/project/path` or
supplied in the process environment. The verified release build used the compile
time path to this checkout. Rebuild after relocating the project.

## Private host protocol

The host heartbeats the exact visible tab inventory and polls native commands.
Every command carries a unique id; a dispatched id is never replayed. Commands
for a closed or inactive tab fail before invoking CEF. A lost result is an
uncertain result and does not trigger an input retry. The backend owns request
deadlines and cancellation between actions.

- `Runtime.evaluate`: in-process awaited CEF evaluation, JSON envelope preserving
  value and `undefined`; returns CDP-shaped `{result:{type,value}}`.
- `Page.captureScreenshot`: in-process screenshot API, returns `{data}` base64.
- `Page.navigate`: CEF `loadUrl`.
- `Input.dispatchMouseEvent`, `Input.dispatchKeyEvent`, `Input.insertText`: fixed
  input-only whitelist through acknowledged in-process Chromium dispatch. CSS
  coordinates, modifier bits, select-all commands and Unicode are preserved
  exactly; no AppKit focus reset or OSR input translation is injected.
- `Browser.openTab`: creates and selects a tab, then synchronizes its handle.
- `Browser.back`, `Browser.forward`, `Browser.reload`: finite CEF history/reload
  calls on the exact active tab. An inactive or stale handle fails before input.
- `Browser.selectTab`, `Browser.closeTab`: operate on an exact observed tab,
  including inactive tabs, and immediately synchronize the resulting inventory.
  They return the requested `tab_id` and resulting `active_tab_id`.

These operations are private authenticated backend operations. Page text and
public agent tools receive no arbitrary JavaScript, selector or shell facility.
Public agent tools accept goals and observed tab handles.

## Local native input patch

The first live form run exposed an upstream contract mismatch: `imeCommitText`
silently ignores native-view browsers, because its dispatcher and bridge both
have explicit OSR-only guards. Native-view `SendMouseClickEvent` plus repeated
AppKit focus acquisition also failed to focus text inputs consistently. Recorded
focus diagnostics showed `BODY` remaining active despite requested field clicks.

Jet adds a distinct `dispatchInput` controller/native method with a fixed whitelist
of the three input methods above. It calls CEF `ExecuteDevToolsMethod` in process
and waits for Chromium's acknowledgement, preserving the original executor's
protocol semantics. The native dispatcher validates the whitelist again. No
remote debugging socket, arbitrary protocol method, page value assignment or
clipboard fallback is exposed. Browser close rejects pending input; a ten-second
acknowledgement timeout reports an uncertain result without retrying. Native
user mouse/keyboard handling is unchanged. the plugin's `PROVENANCE.md` ([SebRincon/flutter_cef_browser](https://github.com/SebRincon/flutter_cef_browser)) retains original
source hashes plus a separate `local_patches` map for the four changed plugin files.

## Verification

`flutter analyze` completed with no issues. Eighteen app tests passed for JSON
preservation, exact protocol input preservation, Unicode text, screenshot routing, unsupported
command rejection, safe URL/search entry, actionable startup errors, the single
Shadcn composer/settings flow, Markdown behavior, dark-theme text contrast,
finite exact-tab history commands, session/draft isolation, trace retrieval/copy
and manual-scroll preservation. The vten-style chat/tracing release rebuild
passed; see `artifacts/native-build-vten-tracing.log`.
`flutter build macos --release --dart-define=JET_ROOT="$PWD"`
built `app/build/macos/Build/Products/Release/Jet Browser.app` (349.4 MB).
The copied native plugin emits existing compiler warnings; no build errors.
Live end-to-end results are recorded separately in the project integration docs.

This first shell intentionally has browser tabs, navigation, chat and local task
controls. Full browser product features such as download management, permission
prompt UI, password storage controls and extension management have not yet been
implemented or qualified for general daily browsing.

The first real native launch displayed the local form correctly, with custom tabs,
address bar and agent panel. The final interface now uses the independent Shadcn
fork with one chat composer, a high contrast dark theme and rendered Markdown;
see `shadcn-fork.md`. Current screenshot:
`artifacts/native-shell-local-sessions.png`. The earlier Markdown screenshot is
`artifacts/native-shell-dark-markdown.png`. The initial screenshot is retained
at `artifacts/native-shell-initial.png` as historical evidence.
On one restart after an ad-hoc rebuild, Chromium startup spent several minutes
waiting in macOS Keychain (`artifacts/native-restart-sample.txt`). It recovered
without configuration or Keychain changes. The persistent profile continues to
use the normal secure Keychain path; mock Keychain mode was not enabled. Stable
code signing and repeat-startup qualification remain needed for distribution.
