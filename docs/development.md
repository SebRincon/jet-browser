# Development and verification

Run commands from the repository root unless noted. End users use the packaged
app and in-app setup; the tools below are developer/build requirements only.

## Prepare a checkout

Use Apple Silicon macOS, Xcode/command-line tools, Flutter (verified: 3.41.6),
CocoaPods and `uv` with Python 3.12. Dependency locks are `backend/uv.lock`,
`app/pubspec.lock`, `app/macos/Podfile.lock` and vendor requirement files.

**Fresh-clone gap:** CEF frameworks/headers/wrapper and model weights are ignored
by Git. `scripts/setup.sh` does not download CEF. Before a native build, prepare
`vendor/flutter_cef_browser/macos/Frameworks/` with the exact framework, matching
`include/`, `libcef_dll_wrapper.a`, license/credits and artifact manifest. The
original asset source/version/hashes are in [CEF manifest](dependencies/cef-artifact-manifest.yaml)
and `vendor/flutter_cef_browser/EXTRACTION.json`. Its absolute paths are provenance,
not paths every developer must reproduce. A reproducible public CEF acquisition
step is still needed; do not substitute an arbitrary framework against these headers.

Smallest backend/test setup, without model downloads:

```sh
uv sync --project backend --frozen
./scripts/build_workflow_runtime.sh
cd app
flutter pub get
```

For local inference and development app builds, after preparing CEF:

```sh
bash scripts/setup.sh
bash scripts/start.sh --dev
```

`setup.sh` installs the controller, four isolated engine environments, Flutter
dependencies and a release build. It does not fetch model weights. The current
machine has local weights; packaged first-run setup downloads pinned weights.
Model-engine requirement files pin key versions but do not fully lock transitive
dependencies. Preserve this limitation in reproducibility claims.

## Verify

```sh
backend/.venv/bin/python -m pytest backend/tests -q
backend/.venv/bin/ruff check backend/jet_browser backend/tests
cd app
flutter analyze
flutter test
```

The backend suite makes no paid provider calls. Without `JET_TEST_CHROMIUM`,
browser DOM cases skip; without the native JS helper, runtime cases skip. Inspect
skip counts. To exercise real DOM behavior without the user's browser:

```sh
JET_TEST_CHROMIUM='/absolute/path/to/chrome-headless-shell' \
  backend/.venv/bin/python -m pytest backend/tests -q
```

Use the dedicated Chromium headless-shell executable (this checkpoint used build
1228). Regular installed Chrome failed fixture loading in the handoff run; do not
treat any Chromium executable as interchangeable. The fixture starts a headless
browser with a temporary profile and serves synthetic
page responses. Its test-only CDP connection is not Jet's production browser API.
When changing vendored chat, also run `flutter test` and `flutter analyze` from
`vendor/vten_chat`. A widget test does not prove native CEF focus/background behavior.

Real-model and provider checks are separate: inspect `--help` and the script before
running. `verify_portable_workflow.py` explicitly needs isolated data, a packaged
runtime, prepared models, a test browser and an authenticated paid Grok account.
It does not attach to the user's browser. The older navigation/check-chat helpers
may use the development service; do not run them against an active user job.

## Package and launch

With CEF, engine environments and Flutter prepared:

```sh
bash scripts/prepare_portable_runtime.sh
JET_BUILD_GROK='/absolute/path/to/pinned/grok' python3 scripts/package_runtime.py
bash scripts/start.sh
```

The packager builds Flutter, copies runtime dependencies, compiles Swift helpers
and ad hoc signs `dist/Jet Browser.app`. It records the Grok hash but currently
does not reject a wrong CLI version: supply the pinned 1.0.41 binary yourself.
`--no-build` deliberately reuses the existing Flutter build; avoid it after UI or
native changes. Build output is not committed. Developer ID/notarization is pending.

The launcher starts bundled Python before exec into Flutter/CEF; never move that
spawn into the initialized native browser. The app can be relocated without the
checkout, uses in-app weight downloads, and needs network access for Grok sign-in.

## Data, ports and diagnosis

| Context | Data and access |
| --- | --- |
| Packaged default | `~/.jet-browser/.runtime/`, models under `~/.jet-browser/models/` |
| Development | Checkout `.runtime/` and `models/`; service 9148, typing helper 9149 |
| Isolated package | Set absolute `JET_DATA_ROOT`, `JET_WORKSPACE_ROOT` and a free `JET_PORT`; helper uses port + 1 |
| Workspace default | `~/.jet-browser/workspaces/<session>/` plus private `index.sqlite3`; independent of `JET_DATA_ROOT` unless explicitly overridden |
| Durable stores | `.runtime/conversations.sqlite3`, `collections.sqlite3`, `workflows.sqlite3` |
| Diagnostics | `.runtime/service.log`, `.runtime/traces/events.jsonl`; app diagnostics and authenticated `/traces`, `/metrics` |

`JET_RESOURCE_ROOT` points at immutable bundled resources; the native launcher sets
it automatically. Do not put profiles or writable files inside the `.app` bundle.
Do not share data roots between concurrent test and user instances.

The developer `./jet status`, `./jet trace` and `./jet metrics` use the checkout's
token and port 9148, even when environment overrides exist. For another instance,
use its UI or a client configured with its port and `.runtime/token`. Read tokens
privately into the client, never print them or paste them into command lines/docs.
`/health` returns identity only. Confirm identity before restarts or control calls.

Use stable turn IDs to correlate route → Grok/tool → native dispatch/ack → outcome.
See [tracing](tracing.md) and [latest timeout incident](incidents/2026-09-28-grok-timeout.md).
Keep content out of diagnostic exports; provider-native logs can contain private
conversation data. Do not copy them wholesale into Git.

## Commit and hand off

Use `main` with small trunk-based changes. Check staged paths and run relevant
tests before committing; preserve lockfiles and licenses. Recommended local scan:

```sh
git diff --cached --check
gitleaks git --pre-commit --staged --redact --no-banner
```

Update [remaining work](../tasks/remaining-work.md), the affected feature doc and
[CHANGELOG](../CHANGELOG.md) with measured outcomes. Historical `artifacts/` and
`.clankstamp/` references are local-only; commit sanitized summaries instead of
user data. Neither push nor publish is implied by a request to commit.
