# AGENTS.md

## What is Wuhu

Wuhu is a data layer + API for understanding coding agents. Not a task runner -
a session log collector and query system.

Core value: collect logs from Claude Code, Codex, OpenCode, etc. Provide APIs so
agents can query them. Git blame a line → find the session → understand the why.

Quick primer: `docs/what-is-a-coding-agent.md`.

## Status

This repo (`wuhu-core`) is the heart of Wuhu: agent runtime, server, runner,
CLI, and all library modules. It depends on
[wuhu-ai](https://github.com/wuhu-labs/wuhu-ai) (PiAI) and
[wuhu-workspace-engine](https://github.com/wuhu-labs/wuhu-workspace-engine)
as external packages.

The native apps (macOS/iOS) live in a separate repo:
[wuhu-app](https://github.com/wuhu-labs/wuhu-app).

### The 0.6.0 → 0.7.6 Revert & Squash

Commit `796b4c6` reverted main back to the `0.6.0` (`4a01d29`) state (batch
revert of all 27 commits after `0.6.0`). The pre-revert HEAD was saved to the
abandoned codebase branch: `backup/pre-revert-to-0.6.0`.

Commit `1a2ac12` then squash-reintroduced the `0.6.0`→`0.6.1` (`cbe2e75`)
changes (release pipeline, version/self-upgrade, mux runner v2 transport,
SIGILL fix, repetition tracker fix) as a single commit on top of the reverted
main. This commit was tagged `0.7.6`.

**Lineage:**
- `0.6.0` (`4a01d29`) — last clean baseline
- `0.6.1` (`cbe2e75`) — added release pipeline, runner v2, bug fixes (5 commits)
- `0.6.1`..`backup/pre-revert-to-0.6.0` — abandoned codebase (21 further commits: effect loops, runner v3, workers, OTel, etc.)
- `796b4c6` — reverted main to content-identical to `0.6.0` (minus `.githooks/pre-commit` update)
- `1a2ac12` / `0.7.6` — squash-reintroduced the `0.6.0`→`0.6.1` diff as one commit

The abandoned codebase branch (`backup/pre-revert-to-0.6.0`) preserves the
pre-revert HEAD for reference.

## Project Structure

Never add a "project structure diagram" (tree listing) to this file. It always drifts from reality.

If you need to understand the current layout, inspect the repo directly (or use `Package.swift` / `swift package describe` as the source of truth).

## Local Dev

Prereqs:

- Swift 6.2 toolchain

Common commands (repo root):

```bash
swift test
swift run wuhu --help
swift run wuhu openai "Say hello"
swift run wuhu anthropic "Say hello"
```

Formatting:

```bash
swift package --allow-writing-to-package-directory swiftformat
swift package --allow-writing-to-package-directory swiftformat --lint .
```

Environment variables:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`

For local manual testing, `wuhu` loads API keys from its server config. Check whether `~/.wuhu` exists; if it does, assume it has the keys and use that (don't rely on a local `.env`).

## WuhuCore / WuhuCoreClient

Before modifying anything in `Sources/WuhuCore/`, read the DocC index (`Sources/WuhuCore/WuhuCore.docc/WuhuCore.md`) to understand the module's architecture and contract boundaries.

`WuhuCoreClient` contains the client-safe subset of WuhuCore: session contracts, queue types, identifiers, and `RemoteSessionSSETransport`. It has no GRDB or server-side dependencies and is safe to use on iOS. `WuhuCore` re-exports `WuhuCoreClient`, so server-side code can use everything from either module.

Files under `Sources/WuhuCoreClient/Contracts/` and `Sources/WuhuCore/Contracts/` are the human-authored alignment surface. **Do not add, remove, or modify contract types without explicit human approval.**

## Notes

General documentation lives in `docs/`.

## Collaboration

When the user is interactively asking questions while reviewing code:

- Treat the user's questions/concerns as likely-valid signals, not as "user error".
- Take a neutral stance: verify by inspecting the repo before concluding who's right.
- Correct the user only when there's a clear factual mismatch, and cite the exact file/symbol you're relying on.
- Assume parts of the codebase may be sloppy/LLM-generated; prioritize clarity and maintainability over defending the status quo.
