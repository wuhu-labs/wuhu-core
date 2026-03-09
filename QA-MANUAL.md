# Wuhu Core — QA Manual

This document describes the manual end-to-end QA tests for wuhu-core. These tests
exercise the full server → runner → worker pipeline with real sessions and real
LLM calls. They complement the unit test suite (`swift test`) which covers
component-level behavior.

Run these tests against every release candidate before tagging.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Setup](#environment-setup)
3. [Test 1: Unit Tests](#test-1-unit-tests)
4. [Test 2: DB Migration](#test-2-db-migration)
5. [Test 3: Basic Coding Tools](#test-3-basic-coding-tools)
6. [Test 4: Bash Execution](#test-4-bash-execution)
7. [Test 5: Remote Runner](#test-5-remote-runner)
8. [Test 6: Session Stop](#test-6-session-stop)
9. [Test 7: Async Bash Wake-Up](#test-7-async-bash-wake-up)
10. [Test 8: Server Kill & Recovery](#test-8-server-kill--recovery)
11. [Teardown](#teardown)

---

## Prerequisites

- Linux x86_64 (the primary deployment target)
- Swift toolchain matching `swift-tools-version` in `Package.swift`
- A copy of a production `wuhu.sqlite` database (for migration testing)
- Valid Anthropic API key (for LLM calls)
- `curl`, `python3`, `tmux`, `jq` available on PATH
- Ports 5540 and 5541 free

## Environment Setup

### 1. Build

```bash
cd wuhu-core
swift build --product wuhu
WUHU_BIN="$(pwd)/.build/debug/wuhu"
```

Verify: build succeeds with no errors.

### 2. Create test directory and config files

```bash
mkdir -p /tmp/wuhu-qa-test
```

**`/tmp/wuhu-qa-test/test-server.yml`**:
```yaml
host: 0.0.0.0
port: 5540
databasePath: /tmp/wuhu-qa-test/wuhu-test.sqlite
workspacePath: ~/workspace

llm:
  anthropic: <YOUR_ANTHROPIC_API_KEY>

runners:
  - name: test-remote-runner
    address: 127.0.0.1:5541

local_runner_socket: /tmp/wuhu-qa-test/local-runner.sock
default_cost_limit: 50
```

**`/tmp/wuhu-qa-test/test-runner.yml`**:
```yaml
name: test-remote-runner
listen:
  host: 0.0.0.0
  port: 5541
```

### 3. Copy production database

```bash
cp ~/.wuhu/wuhu.sqlite /tmp/wuhu-qa-test/wuhu-test.sqlite
cp ~/.wuhu/wuhu.sqlite-shm /tmp/wuhu-qa-test/wuhu-test.sqlite-shm 2>/dev/null || true
cp ~/.wuhu/wuhu.sqlite-wal /tmp/wuhu-qa-test/wuhu-test.sqlite-wal 2>/dev/null || true
```

### 4. Start runner and server

```bash
# Start remote runner
tmux new-session -d -s wuhu-qa-runner \
  "exec $WUHU_BIN runner --config /tmp/wuhu-qa-test/test-runner.yml 2>&1 | tee /tmp/wuhu-qa-test/runner.log"

sleep 2

# Start server
tmux new-session -d -s wuhu-qa-server \
  "exec $WUHU_BIN server --config /tmp/wuhu-qa-test/test-server.yml 2>&1 | tee /tmp/wuhu-qa-test/server.log"

sleep 5
```

### 5. Verify

```bash
curl -s http://127.0.0.1:5540/healthz
# Expected: "ok"
```

Check server log for:
- `Local runner registered and ready`
- `Mux runner 'test-remote-runner' connected`

---

## Test 1: Unit Tests

**Purpose:** Verify all component-level tests pass on the target platform.

```bash
cd wuhu-core && swift test
```

**Pass criteria:** All tests pass (check the final line, e.g. `Test run with N tests in M suites passed`).

---

## Test 2: DB Migration

**Purpose:** Verify that the latest migration applies cleanly to a production database.

This is implicitly tested during [Environment Setup](#4-start-runner-and-server) — the
server applies pending migrations on startup. Check the server log for migration
messages and confirm no errors.

**Pass criteria:**
- Server starts without migration errors
- `curl http://127.0.0.1:5540/healthz` returns `ok`

For explicit verification, you can query the session count:

```bash
sqlite3 /tmp/wuhu-qa-test/wuhu-test.sqlite "SELECT COUNT(*) FROM sessions;"
```

---

## Test 3: Basic Coding Tools

**Purpose:** Verify all file I/O tools work: `ls`, `write`, `read`, `edit`, `find`, `grep`.

### Steps

```bash
# Create a session with a local mount
SESSION=$(curl -s -X POST http://127.0.0.1:5540/v1/sessions \
  -H "Content-Type: application/json" \
  -d '{"provider":"anthropic","model":"claude-sonnet-4-20250514","mountPath":"/tmp/wuhu-qa-test"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

$WUHU_BIN client prompt --session-id "$SESSION" --server http://127.0.0.1:5540 \
  "Test all coding tools: 1) ls the current directory, 2) write a file test-qa.txt with 'hello world',
   3) read it back, 4) edit it to say 'hello wuhu', 5) find '*.txt' files, 6) grep for 'wuhu' in
   the current directory. Report each result."
```

**Pass criteria:** Agent successfully uses all 6 tools and reports correct results. Verify:

```bash
cat /tmp/wuhu-qa-test/test-qa.txt
# Expected: "hello wuhu"
```

---

## Test 4: Bash Execution

**Purpose:** Verify synchronous bash commands execute and return output.

### Steps

```bash
$WUHU_BIN client prompt --session-id "$SESSION" --server http://127.0.0.1:5540 \
  "Run this exact bash command and show me the output: echo QA_TEST_\$(date +%s) && uname -a"
```

**Pass criteria:** Agent runs bash, output contains `QA_TEST_` followed by a timestamp and a `Linux` uname line.

---

## Test 5: Remote Runner

**Purpose:** Verify mount and tool execution on a remote runner.

### Steps

```bash
SESSION_REMOTE=$(curl -s -X POST http://127.0.0.1:5540/v1/sessions \
  -H "Content-Type: application/json" \
  -d '{"provider":"anthropic","model":"claude-sonnet-4-20250514","mountPath":"/tmp/wuhu-qa-test"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

$WUHU_BIN client prompt --session-id "$SESSION_REMOTE" --server http://127.0.0.1:5540 \
  "Mount /tmp on the runner named 'test-remote-runner'. Then: 1) run 'echo REMOTE_OK' in bash,
   2) ls the mounted directory, 3) write a file /tmp/remote-qa.txt with 'remote test',
   4) read it back. Report each result."
```

**Pass criteria:** Agent mounts on `test-remote-runner`, all tools work. Verify:

```bash
cat /tmp/remote-qa.txt
# Expected: "remote test"
```

---

## Test 6: Session Stop

**Purpose:** Verify that stopping a session terminates the agent loop and repairs pending tool calls.

### Steps

```bash
SESSION_STOP=$(curl -s -X POST http://127.0.0.1:5540/v1/sessions \
  -H "Content-Type: application/json" \
  -d '{"provider":"anthropic","model":"claude-sonnet-4-20250514","mountPath":"/tmp/wuhu-qa-test"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Start a long-running bash (detached so we can stop mid-flight)
$WUHU_BIN client prompt --session-id "$SESSION_STOP" --server http://127.0.0.1:5540 --detach \
  "Run this bash command: sleep 120 && echo SHOULD_NOT_SEE_THIS"

# Wait for bash to start
sleep 10

# Stop the session
curl -s -X POST "http://127.0.0.1:5540/v1/sessions/$SESSION_STOP/stop"
sleep 5
```

**Pass criteria:**
- Session transcript contains an `execution_stopped` marker
- Pending tool calls are repaired with a "lost" message
- The agent does NOT continue executing after the stop

Check transcript:

```bash
curl -s "http://127.0.0.1:5540/v1/sessions/$SESSION_STOP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
for e in d['transcript'][-5:]:
    p = e.get('payload',{}).get('payload',{})
    print(p.get('role',''), p.get('type',''), str(p.get('message',{}).get('content',''))[:80])
"
```

**Known limitation:** The underlying bash process (`sleep 120`) may not be killed immediately.

---

## Test 7: Async Bash Wake-Up

**Purpose:** Verify that when an agent goes idle waiting for a long bash command (via `async_bash`),
it wakes up and resumes when the command completes.

### Steps

```bash
SESSION_ASYNC=$(curl -s -X POST http://127.0.0.1:5540/v1/sessions \
  -H "Content-Type: application/json" \
  -d '{"provider":"anthropic","model":"claude-sonnet-4-20250514","mountPath":"/tmp/wuhu-qa-test"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

$WUHU_BIN client prompt --session-id "$SESSION_ASYNC" --server http://127.0.0.1:5540 --detach \
  "Start an async bash command that runs 'sleep 10 && echo ASYNC_WAKEUP_OK && date'.
   Then wait for it to complete by polling its status, and tell me the final output."

# Wait for the full flow: agent starts async bash, goes idle, wakes up on callback
sleep 30
```

**Pass criteria:** The transcript shows:
1. Agent calls `async_bash` to start the command
2. Agent goes idle (or polls status)
3. After ~10 seconds, the bash completes
4. Agent reports the output containing `ASYNC_WAKEUP_OK`

Check:

```bash
curl -s "http://127.0.0.1:5540/v1/sessions/$SESSION_ASYNC" | python3 -c "
import sys,json
d = json.load(sys.stdin)
for e in d['transcript'][-5:]:
    p = e.get('payload',{}).get('payload',{})
    content = p.get('message',{}).get('content',[])
    text = ' '.join([c.get('text','')[:100] for c in content if isinstance(c,dict) and 'text' in c])
    if text: print(p.get('role',''), ':', text[:200])
"
```

---

## Test 8: Server Kill & Recovery

**Purpose:** Verify that when the server is killed (SIGKILL), the worker process survives,
bash commands complete, results are persisted to disk, and on server restart the worker is
adopted and results recovered.

This is the most complex test. It validates the full crash recovery pipeline.

### Phase 1: Start a long bash and kill the server

```bash
SESSION_KILL=$(curl -s -X POST http://127.0.0.1:5540/v1/sessions \
  -H "Content-Type: application/json" \
  -d '{"provider":"anthropic","model":"claude-sonnet-4-20250514","mountPath":"/tmp/wuhu-qa-test"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

$WUHU_BIN client prompt --session-id "$SESSION_KILL" --server http://127.0.0.1:5540 --detach \
  "Run this bash command with 120 second timeout: sleep 30 && echo SURVIVED_SERVER_KILL && date"

# Wait for bash to start
sleep 12

# Verify sleep is running
ps aux | grep "sleep 30" | grep -v grep

# Find the worker directory
WORKER_DIR=$(ls -d ~/.wuhu/workers/local.worker.* | head -1)
echo "Worker: $WORKER_DIR"

# Kill the server
SERVER_PID=$(pgrep -f "wuhu server.*test-server" | head -1)
kill -9 $SERVER_PID
```

### Phase 2: Verify worker survives and bash completes

```bash
sleep 3

# Server is dead
curl -s http://127.0.0.1:5540/healthz  # should fail/timeout

# Worker is alive
WORKER_PID=$(pgrep -f "$WORKER_DIR/socket" | head -1)
ps -p $WORKER_PID  # should show the worker process

# Wait for sleep 30 to finish
sleep 25

# Check that the worker persisted the result
ls -la "$WORKER_DIR"/output/*.result
# Should have a non-empty .result file containing "SURVIVED_SERVER_KILL"
```

**Pass criteria (Phase 2):**
- Worker process is still alive (orphan mode)
- After sleep completes, a `.result` file appears in `$WORKER_DIR/output/`
- The result file contains `SURVIVED_SERVER_KILL` in the output field

### Phase 3: Restart server and verify recovery

```bash
# Clean up stale sockets/locks
rm -f /tmp/wuhu-qa-test/local-runner.sock
rm -f ~/.wuhu/workers/local.runner

# Restart runner (it lost its parent too)
tmux kill-session -t wuhu-qa-runner 2>/dev/null
pkill -f "test-runner.yml" 2>/dev/null
sleep 2
tmux new-session -d -s wuhu-qa-runner \
  "exec $WUHU_BIN runner --config /tmp/wuhu-qa-test/test-runner.yml 2>&1 | tee /tmp/wuhu-qa-test/runner-restart.log"
sleep 2

# Restart server
tmux new-session -d -s wuhu-qa-server \
  "exec $WUHU_BIN server --config /tmp/wuhu-qa-test/test-server.yml 2>&1 | tee /tmp/wuhu-qa-test/server-restart.log"
sleep 10

# Verify
curl -s http://127.0.0.1:5540/healthz
# Expected: "ok"
```

Check server restart log:

```bash
grep -E "previous-gen|Adopted|Resumed" /tmp/wuhu-qa-test/server-restart.log
```

**Pass criteria (Phase 3):**
- Server log shows `Found N previous-gen workers`
- Server log shows `Adopted worker local.worker.<epoch>`
- Server log shows `Resumed N previously-running session(s)`
- `healthz` returns `ok`
- The session resumes and eventually completes (agent detects stale tool call, retries)

### Verify final session state

Wait ~60 seconds for the session to retry and complete, then:

```bash
curl -s "http://127.0.0.1:5540/v1/sessions/$SESSION_KILL" | python3 -c "
import sys,json
d = json.load(sys.stdin)
for e in d['transcript']:
    p = e.get('payload',{}).get('payload',{})
    content = p.get('message',{}).get('content',[])
    text = ' '.join([c.get('text','')[:100] for c in content if isinstance(c,dict) and 'text' in c])
    if text and 'SURVIVED' in text: print('FOUND:', text[:200])
"
```

**Pass criteria:** The transcript contains `SURVIVED_SERVER_KILL` somewhere — either in the
original tool result (if the callback was recovered in time) or in a retry.

---

## Teardown

```bash
# Stop everything
tmux kill-session -t wuhu-qa-server 2>/dev/null
tmux kill-session -t wuhu-qa-runner 2>/dev/null
pkill -f "test-server.yml\|test-runner.yml\|wuhu worker\|wuhu runner" 2>/dev/null
sleep 2

# Clean up worker state
rm -rf ~/.wuhu/workers/local.worker.*
rm -rf ~/.wuhu/workers/test-remote-runner.worker.*
rm -f ~/.wuhu/workers/local.runner
rm -f ~/.wuhu/workers/test-remote-runner.runner
rm -f /tmp/wuhu-qa-test/local-runner.sock

# Optionally remove test directory
# rm -rf /tmp/wuhu-qa-test
```

---

## Notes for Automated Execution

This manual is designed to be run by a coding agent (e.g. a Wuhu session itself). When
assigning this to an agent:

1. Point the agent at this file and ask them to run the full QA suite
2. Provide the Anthropic API key (or tell them where to find it)
3. Specify the commit/branch to test
4. The agent should produce a QA report in the format of `~/workspace/wuhu-qa/<version>/attempt-<N>.md`
5. If bugs are found, the agent should fix them, re-run the affected tests, and create a PR

Key things the agent should know:
- Use **different ports** (5540/5541) to avoid conflicting with a running production server
- Copy the production database — never test against it directly
- Always clean up worker state between test runs
- The server log is the primary debugging tool — check it first when things go wrong
- `tmux` sessions are used to run the server/runner in the background
- `--detach` flag on the client is essential for tests where you need to interact mid-flight
