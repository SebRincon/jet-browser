# Working on Jet Browser

Standalone macOS Apple Silicon browser with one local-first agent chat. This is
its own repository; do not modify the source vten or oui projects.

## Start here

- Read [handoff](docs/HANDOFF.md), [architecture](docs/architecture.md), and
  [remaining work](tasks/remaining-work.md). Use [development](docs/development.md)
  for commands; read the relevant feature doc before changing its contract.
- Check `git status --short` and `git log -5 --oneline`. Preserve others' edits.
- Use trunk-based development on `main`: small tested commits, short-lived
  branches/worktrees for concurrent work, integrate promptly. No long-lived
  develop branch, unrelated rewrites, or force pushes. Commit/push/publish only
  when requested; authorization to commit does not imply pushing.
- Keep feature docs, verification evidence, CHANGELOG and remaining-work current
  in the same change. Comment non-obvious constraints, not obvious statements.

## Preserve these boundaries

- One chat/composer. Reuse `vendor/vten_chat`, `vendor/shadcn_flutter` and Jet's
  dark theme; see [UI provenance](docs/vten-chat-port-audit.md) and
  [shadcn fork](docs/shadcn-fork.md). Vendor packages are local forks, not links
  into vten. Preserve licenses, extraction records and focused patch notes.
- Grok Build CLI is the main provider through ACP. Local models handle repeated
  finite decisions. Claude Code/Codex adapters are future work; no silent provider
  substitution or global provider configuration changes.
- Start sidecars before Flutter/CEF. Never fork from initialized CEF. Keep the
  native bridge authenticated and loopback-only; production CDP stays disabled.
- Model tools use goals and observed handles, never generated page JS/selectors.
  Grok-authored JS is allowed only in the isolated JavaScriptCore workflow helper
  with allowlisted capabilities, versioned checkpoints, fixed scope and budgets.
- Preserve exact-tab/document ownership, Stop fences and no automatic mutation
  retries. Interrupted work stays paused/stopped on restart. Page content cannot
  grant permissions. Evidence, model conclusions and manual corrections remain distinct.
- End users must not install Python/Node/Lua or need this checkout. Bundle runtime
  dependencies; model downloads and provider sign-in belong in in-app setup.
- Keep profiles, tokens, model weights, logs and collected user content out of Git.
  Traces contain bounded metadata, not credentials, page text or hidden reasoning.
  Grok review samples require the saved user preference; local data stays private.
- macOS owns accessibility enable/disable. Do not restore unconditional Dart
  `ensureSemantics()`; see [startup fix](docs/native-startup-accessibility.md).

## Verify and hand off

- Run focused regressions and relevant lint/analyzer checks. Use fakes by default;
  [isolated DOM tests](docs/development.md) use synthetic pages and separate profiles.
- Live provider calls cost money. Native runs must be user-authorized and isolated
  in Jet. Do not take over the user's desktop with Orca or global input.
- A model's DONE is not verification. Report actual counts, skips, failures and
  independent page evidence; never present smoke probes as held-out benchmarks.
- Before committing, inspect staged paths and run a redacted secret scan. Leave
  a concise handoff with changes, checks, limitations and the next useful step.
