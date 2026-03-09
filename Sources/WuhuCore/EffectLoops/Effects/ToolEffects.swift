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
    let blobStore = blobStore
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

      let results: [(ToolCall, Result<AgentToolResult, any Error>)] =
        await withTaskGroup(
          of: (ToolCall, Result<AgentToolResult, any Error>).self,
        ) { group in
          for call in allowed {
            group.addTask {
              do {
                guard let tool = tools.first(where: { $0.tool.name == call.name }) else {
                  throw PiAIError.unsupported("Unknown tool: \(call.name)")
                }
                let rawResult = try await tool.execute(toolCallId: call.id, args: call.arguments)
                let truncated = applyToolResultTruncation(
                  result: rawResult,
                  direction: tool.truncationDirection,
                  toolCallId: call.id,
                  sessionDir: sessionDir,
                )
                return (call, .success(truncated))
              } catch {
                return (call, .failure(error))
              }
            }
          }
          var outputs: [(ToolCall, Result<AgentToolResult, any Error>)] = []
          for await output in group {
            outputs.append(output)
          }
          return outputs
        }

      // Record results
      for (call, result) in results {
        let argsHash = call.arguments.hashValue
        switch result {
        case let .success(toolResult):
          let resultHash = toolResult.hashValue
          await persistToolSuccess(
            call: call,
            toolResult: toolResult,
            argsHash: argsHash,
            resultHash: resultHash,
            tracker: tracker,
            sessionID: sessionID,
            store: store,
            blobStore: blobStore,
            send: send,
          )

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
  blobStore: WuhuBlobStore,
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
    let persistedContent = try finalResult.content.map { block -> WuhuContentBlock in
      if case let .image(img) = block, !img.data.hasPrefix("blob://") {
        guard let rawData = Data(base64Encoded: img.data) else {
          return WuhuContentBlock.fromPi(block)
        }
        let uri = try blobStore.store(sessionID: sessionID.rawValue, data: rawData, mimeType: img.mimeType)
        return .image(blobURI: uri, mimeType: img.mimeType)
      }
      return WuhuContentBlock.fromPi(block)
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
private func applyToolResultTruncation(
  result: AgentToolResult,
  direction: ToolResultTruncation.Direction,
  toolCallId: String,
  sessionDir: String?,
) -> AgentToolResult {
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
