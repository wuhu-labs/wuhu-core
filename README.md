# wuhu-core

Wuhu core: agent runtime, session model, server, runner, and CLI.

This is the heart of [Wuhu](https://github.com/wuhu-labs/wuhu) — a data layer
and API for understanding coding agents. It collects session logs from Claude
Code, Codex, OpenCode, etc. and provides APIs so agents can query them.

## Packages

| Module | Description |
|--------|-------------|
| `WuhuAPI` | Shared types: models, enums, HTTP types, provider definitions |
| `WuhuCoreClient` | Client-safe session contracts, queue types, SSE transport (no GRDB) |
| `WuhuCore` | Agent loop, session store, SQLite persistence, tools, compaction |
| `WuhuClient` | HTTP client library to talk to a Wuhu server |
| `WuhuServer` | Hummingbird HTTP server, runner registry |
| `WuhuRunner` | Remote tool execution daemon |
| `WuhuCLIKit` | CLI output formatting |

## CLI

```bash
swift run wuhu --help
swift run wuhu server --config ~/.wuhu/server.yml
swift run wuhu client create-session --provider openai --environment my-env
swift run wuhu client prompt --session-id <id> "Hello"
swift run wuhu client get-session --session-id <id>
swift run wuhu runner --config ~/.wuhu/runner.yml
```

## Dev

Requires Swift 6.2.

```bash
swift build
swift test
```

Formatting:

```bash
swift package --allow-writing-to-package-directory swiftformat
```

## Dependencies

- [wuhu-ai](https://github.com/wuhu-labs/wuhu-ai) — PiAI unified LLM client
- [wuhu-workspace-engine](https://github.com/wuhu-labs/wuhu-workspace-engine) — Workspace scanning and querying
- [GRDB](https://github.com/groue/GRDB.swift) — SQLite
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) — HTTP server
- [Yams](https://github.com/jpsim/Yams) — YAML parsing

## License

MIT
