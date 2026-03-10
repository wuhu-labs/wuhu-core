import Foundation
import PiAI
import WuhuAPI

/// Effect factories for tool execution and stale tool recovery.
extension WuhuBehavior {
  /// Execute tool calls in parallel. Each sends `.tools(.completed)` or
  /// `.tools(.failed)` with the result. Repetition tracking data is sent
  /// back in the actions so the reducer can update the tracker.
  func executeToolCalls(_ calls: [ToolCall], state: WuhuState) -> Effect<WuhuAction> {
    let sessionID = sessionID
    let store = store
    let runtimeConfig = runtimeConfig
    let tracker = state.tools.repetitionTracker

    return Effect { send in
      // Mark all as started in DB
      for call in calls {
        _ = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .started)
        await send(WuhuAction.tools(.willExecute(call)))
        let status = try await store.loadStatusSnapshot(sessionID: sessionID)
        await send(WuhuAction.status(.updated(status)))
      }

      // Partition calls into blocked vs. allowed based on repetition history.
      var blocked: [ToolCall] = []
      var allowed: [ToolCall] = []
      for call in calls {
        let argsHash = call.arguments.hashValue
        let count = tracker.preflightCount(toolName: call.name, argsHash: argsHash)
        if count >= ToolCallRepetitionTracker.blockThreshold {
          blocked.append(call)
        } else {
          allowed.append(call)
        }
      }

      // Record blocked calls as errors immediately.
      for call in blocked {
        let now = Date()
        let argsHash = call.arguments.hashValue
        let toolResult: Message = .toolResult(.init(
          toolCallId: call.id,
          toolName: call.name,
          content: [.text(ToolCallRepetitionTracker.blockText)],
          details: .object(["wuhu_tool_error": .string("repetition_blocked")]),
          isError: true,
          timestamp: now,
        ))

        let (_, entry) = try await store.appendEntryWithSession(
          sessionID: sessionID,
          payload: .message(.fromPi(toolResult)),
          createdAt: now,
        )
        await send(WuhuAction.transcript(.append(entry)))

        _ = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .errored)
        await send(WuhuAction.tools(.failed(id: call.id, status: .errored, toolName: call.name, argsHash: argsHash)))

        let status = try await store.loadStatusSnapshot(sessionID: sessionID)
        await send(WuhuAction.status(.updated(status)))
      }

      // Execute allowed calls in parallel.
      let tools = await runtimeConfig.tools()

      // Resolve the session directory for disk persistence of truncated output.
      // NOTE: We only persist full output to disk when the primary mount is on the
      // local runner. ToolEffects runs on the server process, so FileManager writes
      // target the server filesystem. If the mount belongs to a remote runner, the
      // persisted path would not be accessible from the agent's active mount, so we
      // skip disk persistence and omit the path from the truncation notice.
      let primaryMount: WuhuMount? = try? await store.getPrimaryMount(sessionID: sessionID.rawValue)
      let sessionDir: String? = if let primaryMount, primaryMount.runnerID == .local {
        primaryMount.path
      } else {
        nil
      }

      let results: [(ToolCall, Result<ToolExecutionResult, any Error>, ToolResultTruncation.Direction)] =
        await withTaskGroup(
          of: (ToolCall, Result<ToolExecutionResult, any Error>, ToolResultTruncation.Direction).self,
        ) { group in
          for call in allowed {
            group.addTask {
              do {
                guard let tool = tools.first(where: { $0.tool.name == call.name }) else {
                  throw PiAIError.unsupported("Unknown tool: \(call.name)")
                }
                let rawResult = try await tool.execute(toolCallId: call.id, args: call.arguments)
                return (call, .success(rawResult), tool.truncationDirection)
              } catch {
                return (call, .failure(error), .head)
              }
            }
          }
          var outputs: [(ToolCall, Result<ToolExecutionResult, any Error>, ToolResultTruncation.Direction)] = []
          for await output in group {
            outputs.append(output)
          }
          return outputs
        }

      // Record results
      for (call, result, truncationDirection) in results {
        let argsHash = call.arguments.hashValue
        switch result {
        case let .success(.immediate(toolResult)):
          let truncated = await applyToolResultTruncation(
            result: toolResult,
            direction: truncationDirection,
            toolCallId: call.id,
            sessionDir: sessionDir,
          )
          let resultHash = truncated.hashValue
          await persistToolSuccess(
            call: call,
            toolResult: truncated,
            argsHash: argsHash,
            resultHash: resultHash,
            tracker: tracker,
            sessionID: sessionID,
            store: store,
            send: send,
          )

        case .success(.pending):
          // Fire-and-forget tool (e.g., bash). Result will arrive via callback.
          // Tool call stays in .started status. Just clear the executing guard.
          await send(WuhuAction.tools(.statusSet(id: call.id, status: .started)))

        case let .failure(error):
          await persistToolFailure(
            call: call,
            error: error,
            argsHash: argsHash,
            sessionID: sessionID,
            store: store,
            send: send,
          )
        }
      }
    }
  }

  /// Inject an error result for an orphaned tool call stuck in started/pending.
  func recoverStaleToolCall(id: String, state: WuhuState) -> Effect<WuhuAction> {
    let sessionID = sessionID
    let store = store

    return Effect { send in
      // Check if result already exists in transcript (avoid double-repair).
      let hasResult = state.transcript.entries.contains { entry in
        guard case let .message(m) = entry.payload else { return false }
        guard case let .toolResult(t) = m else { return false }
        return t.toolCallId == id
      }

      // Find the tool name from the transcript
      let toolName: String = {
        for entry in state.transcript.entries.reversed() {
          guard case let .message(m) = entry.payload else { continue }
          guard case let .assistant(a) = m else { continue }
          for block in a.content {
            guard case let .toolCall(callID, name, _) = block else { continue }
            if callID == id { return name }
          }
        }
        return "unknown"
      }()

      if hasResult {
        _ = try await store.setToolCallStatus(sessionID: sessionID, id: id, status: .errored)
        await send(WuhuAction.tools(.failed(id: id, status: .errored, toolName: toolName, argsHash: 0)))
        return
      }

      let now = Date()
      let repaired: Message = .toolResult(.init(
        toolCallId: id,
        toolName: toolName,
        content: [.text(WuhuToolRepairer.lostToolResultText)],
        details: .object([
          "wuhu_repair": .string("stale_tool_call"),
          "reason": .string("lost"),
        ]),
        isError: true,
        timestamp: now,
      ))

      let (_, entry) = try await store.appendEntryWithSession(
        sessionID: sessionID,
        payload: .message(.fromPi(repaired)),
        createdAt: now,
      )
      await send(WuhuAction.transcript(.append(entry)))

      _ = try await store.setToolCallStatus(sessionID: sessionID, id: id, status: .errored)
      await send(WuhuAction.tools(.failed(id: id, status: .errored, toolName: toolName, argsHash: 0)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      await send(WuhuAction.status(.updated(status)))
    }
  }

  /// Persist a bash result that was delivered from the worker (typically after server restart).
  func persistDeliveredBashResult(toolCallID: String, result: BashResult, state: WuhuState) -> Effect<WuhuAction> {
    let sessionID = sessionID
    let store = store

    return Effect { send in
      // Check if result already exists in transcript (avoid double-persist).
      let hasResult = state.transcript.entries.contains { entry in
        guard case let .message(m) = entry.payload else { return false }
        guard case let .toolResult(t) = m else { return false }
        return t.toolCallId == toolCallID
      }

      if hasResult {
        // Already have a result — just update status and clear recovering flag
        _ = try await store.setToolCallStatus(sessionID: sessionID, id: toolCallID, status: .completed)
        await send(WuhuAction.tools(.completed(
          id: toolCallID, status: .completed,
          toolName: "bash", argsHash: 0, resultHash: result.output.hashValue,
        )))
        let status = try await store.loadStatusSnapshot(sessionID: sessionID)
        await send(WuhuAction.status(.updated(status)))
        return
      }

      // Format the bash output similar to how the bash tool does
      var output = result.output
      if result.timedOut {
        output += "\n[timed out]"
      }
      if result.terminated {
        output += "\n[terminated]"
      }

      // Apply truncation (tail direction — build/test output is most useful at the end).
      let displayOutput: String
      if output.isEmpty {
        displayOutput = "(no output)"
      } else {
        let primaryMount: WuhuMount? = try? await store.getPrimaryMount(sessionID: sessionID.rawValue)
        let sessionDir: String? = if let primaryMount, primaryMount.runnerID == .local {
          primaryMount.path
        } else {
          nil
        }

        let agentResult = AgentToolResult(content: [.text(output)], details: .object([:]))
        let truncated = await applyToolResultTruncation(
          result: agentResult,
          direction: .tail,
          toolCallId: toolCallID,
          sessionDir: sessionDir,
        )
        // Extract the (possibly truncated) text back out.
        displayOutput = truncated.content.compactMap { block in
          if case let .text(t) = block { return t.text }
          return nil
        }.joined()
      }

      let now = Date()
      let toolResultMessage = WuhuToolResultMessage(
        toolCallId: toolCallID,
        toolName: "bash",
        content: [.text(text: displayOutput, signature: nil)],
        details: .object([
          "exit_code": .number(Double(result.exitCode)),
        ]),
        isError: result.exitCode != 0,
        timestamp: now,
      )

      let (_, entry) = try await store.appendEntryWithSession(
        sessionID: sessionID,
        payload: .message(.toolResult(toolResultMessage)),
        createdAt: now,
      )
      await send(WuhuAction.transcript(.append(entry)))

      _ = try await store.setToolCallStatus(sessionID: sessionID, id: toolCallID, status: .completed)
      await send(WuhuAction.tools(.completed(
        id: toolCallID, status: .completed,
        toolName: "bash", argsHash: 0, resultHash: result.output.hashValue,
      )))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      await send(WuhuAction.status(.updated(status)))
    }
  }
}

// MARK: - Tool result persistence helpers

private func persistToolSuccess(
  call: ToolCall,
  toolResult: AgentToolResult,
  argsHash: Int,
  resultHash: Int,
  tracker: ToolCallRepetitionTracker,
  sessionID: SessionID,
  store: SQLiteSessionStore,
  send: Send<WuhuAction>,
) async {
  do {
    let now = Date()

    // Check repetition count from the snapshot to decide whether to append a warning.
    // The actual tracker update happens in the reducer when it processes .completed.
    let currentCount = tracker.preflightCount(toolName: call.name, argsHash: argsHash)

    var finalResult = toolResult
    if currentCount + 1 >= ToolCallRepetitionTracker.warningThreshold {
      finalResult.content.append(.text(ToolCallRepetitionTracker.warningText))
    }

    // Convert image content blocks: store base64 data as blobs, replace with blob URIs.
    var persistedContent: [WuhuContentBlock] = []
    for block in finalResult.content {
      if case let .image(img) = block, !img.data.hasPrefix("blob://") {
        guard let rawData = Data(base64Encoded: img.data) else {
          persistedContent.append(WuhuContentBlock.fromPi(block))
          continue
        }
        let uri = try await BlobBucket.store(namespace: sessionID.rawValue, data: rawData, mimeType: img.mimeType)
        persistedContent.append(.image(blobURI: uri, mimeType: img.mimeType))
      } else {
        persistedContent.append(WuhuContentBlock.fromPi(block))
      }
    }

    let toolResultMessage = WuhuToolResultMessage(
      toolCallId: call.id,
      toolName: call.name,
      content: persistedContent,
      details: finalResult.details,
      isError: false,
      timestamp: now,
    )

    let (_, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.toolResult(toolResultMessage)),
      createdAt: now,
    )
    await send(WuhuAction.transcript(.append(entry)))

    _ = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .completed)
    await send(WuhuAction.tools(.completed(
      id: call.id, status: .completed,
      toolName: call.name, argsHash: argsHash, resultHash: resultHash,
    )))

    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    await send(WuhuAction.status(.updated(status)))
  } catch {
    // If persistence fails, record as failure
    await persistToolFailure(
      call: call, error: error, argsHash: argsHash,
      sessionID: sessionID, store: store, send: send,
    )
  }
}

private func persistToolFailure(
  call: ToolCall,
  error: any Error,
  argsHash: Int,
  sessionID: SessionID,
  store: SQLiteSessionStore,
  send: Send<WuhuAction>,
) async {
  do {
    let now = Date()
    let toolResult: Message = .toolResult(.init(
      toolCallId: call.id,
      toolName: call.name,
      content: [.text("[tool error] \(error)")],
      details: .object(["wuhu_tool_error": .string("\(error)")]),
      isError: true,
      timestamp: now,
    ))

    let (_, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.fromPi(toolResult)),
      createdAt: now,
    )
    await send(WuhuAction.transcript(.append(entry)))

    _ = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .errored)
    await send(WuhuAction.tools(.failed(id: call.id, status: .errored, toolName: call.name, argsHash: argsHash)))

    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    await send(WuhuAction.status(.updated(status)))
  } catch {
    // Best-effort: if even error persistence fails, just send the failure action.
    await send(WuhuAction.tools(.failed(id: call.id, status: .errored, toolName: call.name, argsHash: argsHash)))
  }
}

// MARK: - Tool result truncation

/// Apply the shared truncation system to a tool result's text content blocks.
/// If truncation occurs and a session directory is available, persist the full output to disk.
///
/// - TODO: The disk persistence (`ToolResultTruncation.persistFullOutput`) currently uses
///   synchronous `FileManager` I/O. This should go through the runner's async file I/O
///   interface for consistency, but is acceptable for now since it only runs when the
///   primary mount is local (same machine as the server process).
private func applyToolResultTruncation(
  result: AgentToolResult,
  direction: ToolResultTruncation.Direction,
  toolCallId: String,
  sessionDir: String?,
) async -> AgentToolResult {
  var modified = result

  // Find the first (and typically only) text content block.
  guard let textIndex = modified.content.firstIndex(where: {
    if case .text = $0 { return true }
    return false
  }) else {
    return modified
  }

  guard case let .text(textBlock) = modified.content[textIndex] else {
    return modified
  }
  let rawText = textBlock.text

  let truncResult = ToolResultTruncation.truncate(rawText, direction: direction)
  guard truncResult.wasTruncated else { return modified }

  // Persist full output to disk if we have a session directory.
  var fullOutputPath: String?
  if let sessionDir {
    fullOutputPath = ToolResultTruncation.persistFullOutput(
      content: rawText,
      sessionDir: sessionDir,
      toolCallId: toolCallId,
    )
  }

  // Build the truncated text with notice.
  var truncatedText = truncResult.content
  if let notice = ToolResultTruncation.renderNotice(for: truncResult, fullOutputPath: fullOutputPath) {
    truncatedText += notice
  }

  modified.content[textIndex] = .text(.init(text: truncatedText))
  return modified
}
