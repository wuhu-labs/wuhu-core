# What is a coding agent?

A **coding agent** is an AI system that can take a goal (e.g. “add a feature”, “fix a bug”, “refactor this module”) and then **act** to achieve it, not just answer questions.

In practice, a coding agent typically:

- **Plans** a sequence of steps.
- **Reads and edits code**, usually across multiple files.
- **Runs tools** (tests, linters, build commands, git, package managers).
- **Iterates** based on feedback (test failures, type errors, reviewer comments).
- **Produces artifacts**: commits/PRs, patches, changelogs, release notes.

The key distinction from a chat-only assistant is **closed-loop execution**: it observes the repo state, performs actions, checks results, and repeats until the task is done.

Common capabilities and patterns:

- Tool use (shell, git, editors)
- Retrieval (searching the codebase and docs)
- Structured outputs (plans, diffs, test reports)
- Safety constraints (scoped permissions, redaction, policy checks)

Wuhu’s purpose is to **collect, store, and query** these agent sessions so humans (and other agents) can understand what happened and why.
