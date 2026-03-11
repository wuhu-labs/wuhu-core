# AgentLoop / EffectLoop Refactor — PROGRESS

## Status / Phases

- **Early exploration (current)**: build/tests may be broken; prioritize getting the architecture shape right.
- **Shape mostly done**: build must pass; tests may still be red while we delete/rewrite old code paths.
- **Validation**: goal is to drive tests green (and add/restore only the tests that clarify correctness).

## Goal

A **clean cutover** to an agent loop that is **obviously correct** and **easily testable** (PointFree-style): small primitives, explicit sequencing, and a runtime that is straightforward to reason about.

During this journey we expect to **drop code aggressively** and **remove/replace tests aggressively** if they obscure the intended invariants.

## Current PR / Tracking

- Draft PR: https://github.com/wuhu-labs/wuhu-core/pull/61
- Branch: `agentloop-effectloop-v2`

Primary implementation commit (detailed message already exists):
- `28806d8` — “WIP: EffectLoop v2 primitives + AgentBehavior cutover”

PR body currently contains a high-level change summary; for further details see the files listed below.

## Core Preferences (human-driven; discuss if they impact the big picture)

These are the preferences driving the refactor so far. Each item is **not a law**—if a preference blocks the overall design goal, we should discuss and adjust.

1. **Primitive effect model only** (no effect merging / batching API).
   - See `Sources/WuhuCore/EffectLoops/Effect.swift`.

2. **Reducer returns an effect**.
   - See `Sources/WuhuCore/EffectLoops/LoopBehavior.swift`.

3. **Persist-first semantics**: durable “intent” changes happen in `.sync` before any `.run` is spawned.
   - See `.sync` handling in `Sources/WuhuCore/EffectLoops/EffectLoop.swift`.

4. **Drain semantics**: drain all `.sync` (and `.cancel`) work first; defer `.run` until sync work is drained.
   - See `EffectLoop.step()` in `Sources/WuhuCore/EffectLoops/EffectLoop.swift`.

5. **Greedy scheduling**: the loop drains effects greedily (v1-style), but with the new sync/run staging.
   - Same file as above.

6. **Action handling**: `send(action)` enqueues; reduction happens inside `step()`.
   - Same file as above.

7. **Strict task IDs**: one in-flight task per ID; duplicates are a programmer error.
   - See `.run` handling and `precondition` checks in `Sources/WuhuCore/EffectLoops/EffectLoop.swift`.

8. **(Likely) double-tracking tasks**: one in the loop runtime + one in state, to support domain-level correctness (stale detection, recovery intent, etc.).
   - This is still being explored.

9. **Repair/startup**: no dedicated runtime hook; domain behavior should schedule repair via normal `nextEffect` logic (e.g. an `initialized` / `needsRepair` flag).
   - This is a guiding design intent; implementation may evolve.

10. **State vs derived getters**: prefer inferring status from state where possible, but accept explicit “stage/step” if it makes the state machine more legible.
    - This remains an explicit decision point for the human.

## Where we are (early exploration)

### Runtime cutover (EffectLoop)

- New effect type and behavior contract:
  - `Sources/WuhuCore/EffectLoops/Effect.swift` @ `28806d8`
  - `Sources/WuhuCore/EffectLoops/LoopBehavior.swift` @ `28806d8`

- New effect loop runtime semantics:
  - `Sources/WuhuCore/EffectLoops/EffectLoop.swift` @ `28806d8`
  - Key points:
    - enqueue-only `send()`
    - `.sync` returns committed actions
    - `.run` is named tasks (deferred until sync drains)
    - `.cancel([TaskID])` cancels both in-flight and deferred

### AgentBehavior cutover (still partial)

- Planner and reducers:
  - `Sources/WuhuCore/EffectLoops/Reducers/AgentBehavior.swift` @ `28806d8`

- Queue drains rewritten as `.sync` (no drain guard token):
  - `Sources/WuhuCore/EffectLoops/Effects/DrainEffects.swift` @ `28806d8`
  - `Sources/WuhuCore/EffectLoops/Actions/QueueAction.swift` @ `28806d8`
  - `Sources/WuhuCore/EffectLoops/Reducers/ReduceQueue.swift` @ `28806d8`

- Inference split: run task streams + completion message; persistence moved to `.sync`:
  - `Sources/WuhuCore/EffectLoops/Effects/InferenceEffect.swift` @ `28806d8`
  - `Sources/WuhuCore/EffectLoops/Actions/InferenceAction.swift` @ `28806d8`
  - `Sources/WuhuCore/EffectLoops/State/InferenceState.swift` @ `28806d8`
  - `Sources/WuhuCore/EffectLoops/Reducers/ReduceInference.swift` @ `28806d8`

- Tools: move toward per-tool-call tasks (`tool:{id}`) triggered by `.tools(.willExecute(call))`:
  - `Sources/WuhuCore/EffectLoops/Effects/ToolEffects.swift` @ `28806d8`
  - `Sources/WuhuCore/EffectLoops/Reducers/ReduceTools.swift` @ `28806d8`

- Observation layer updates to new inference action:
  - `Sources/WuhuCore/SessionRuntime.swift` @ `28806d8`

## Known gaps / risks (from self-review)

1. **Large semantic shift**: `send()` no longer reduces immediately; assumptions elsewhere may break.
2. **Cancellation is ID-convention based**; correctness depends on consistent IDs.
3. **Status snapshot round-trips** still exist; “infer from state” is not yet achieved.
4. **Legacy paths remain** (e.g. batch tool executor logic still exists in the codebase even if we are moving away from it).

## Next iteration (proposed)

1. **Finish the clean cutover**: delete/disable remaining legacy code paths that compete with the new model (especially tool execution variants) so there is one obvious path.
2. **Make stopping semantics coherent**: decide what is derived vs explicitly stored, and remove redundant bookkeeping.
3. **Reduce DB status round-trips**: move toward deriving execution status and using DB reads only where they represent durable inputs.
4. **Then move to “shape mostly done”**: require build to pass before continuing deeper behavior changes.

## Process Notes

- For **any big code changes in this PR**, use a **detailed commit message** (and keep the PR description updated as the branch evolves).
- This file is the running narrative of what changed and why; prefer linking to code + commit hashes rather than duplicating code here.
