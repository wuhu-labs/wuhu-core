import Dependencies
import Foundation
import PiAI

/// Effect factory for running inference (streaming LLM call).
extension AgentBehavior {
  /// Calls PiAI streaming API, sends `.inference(.delta)` for each text chunk,
  /// `.inference(.completed)` on success, `.inference(.failed)` on error.
  func runInference(state: AgentState) -> AgentEffect {
    let sessionID = sessionID
    let store = store
    let runtimeConfig = runtimeConfig
    let entries = state.transcript.entries
    return .run("inference") { send in
      @Dependency(\.streamFn) var streamFn
      await send(AgentAction.inference(.started))

      do {
        let session = try await store.getSession(id: sessionID.rawValue)
        let settings = try await store.loadSettingsSnapshot(sessionID: sessionID)

        let resolved = WuhuModelCatalog.resolveAlias(session.model)
        let provider = session.provider.piProvider
        let apiModel = Model(id: resolved.apiModelID, provider: provider, baseURL: providerBaseURL(for: provider))
        var requestOptions = makeRequestOptions(model: apiModel, settings: settings, userModelID: session.model)
        mergeBetaFeatures(resolved.betaFeatures, into: &requestOptions)

        let tools = await runtimeConfig.tools()

        // Build context
        let header = (try? PromptPreparation.extractHeader(from: entries, sessionID: sessionID.rawValue))
        let systemPrompt = header?.systemPrompt ?? ""
        let messages = PromptPreparation.extractContextMessages(from: entries)
        let hydrated = await hydrateImageBlobs(in: messages)

        var effectiveSystemPrompt = systemPrompt
        if let cwd = session.cwd {
          effectiveSystemPrompt += "\n\nWorking directory: \(cwd)\nAll relative paths are resolved from this directory."
        }

        let context = Context(
          systemPrompt: effectiveSystemPrompt,
          messages: hydrated,
          tools: tools.map(\.tool),
        )

        let events = try await streamFn(apiModel, context, requestOptions)

        var partial: AssistantMessage?
        var final: AssistantMessage?
        for try await event in events {
          switch event {
          case let .start(p):
            partial = p
          case let .textDelta(delta, p):
            await send(AgentAction.inference(.delta(delta)))
            partial = p
          case let .done(message):
            final = message
          }
        }

        guard let message = final ?? partial else {
          throw PiAIError.unsupported("No model output")
        }

        // Hand off persistence to the loop (sync effect). The run task only
        // produces streaming deltas and the final assistant message.
        await send(AgentAction.inference(.completed(message)))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        await send(AgentAction.inference(.failed(InferenceError.from(error))))
      }
    }
  }

  /// Persist a completed assistant message (and derived side effects) to SQLite.
  ///
  /// This runs as a `.sync` effect so it is serialized with other short DB work.
  func persistInferenceCompletion(_ message: AssistantMessage) -> AgentEffect {
    let sessionID = sessionID
    let store = store

    return .sync { _ in
      let session = try await store.getSession(id: sessionID.rawValue)

      let (_, entry) = try await store.appendEntryWithSession(
        sessionID: sessionID,
        payload: .message(.fromPi(.assistant(message))),
        createdAt: message.timestamp,
      )

      var actions: [AgentAction] = [.transcript(.append(entry))]

      // Cost (use resolved model from the response, not the session alias)
      if let usage = message.usage {
        let entryCost = PricingTable.computeEntryCost(
          provider: session.provider,
          model: message.model,
          usage: WuhuUsage.fromPi(usage),
        )
        if entryCost > 0 {
          actions.append(.cost(.spent(entryCost)))
        }
      }

      // Tool call statuses for any tool calls in the response.
      let calls = message.content.compactMap { block -> ToolCall? in
        if case let .toolCall(c) = block { return c }
        return nil
      }
      if !calls.isEmpty {
        let updates = try await store.upsertToolCallStatuses(sessionID: sessionID, calls: calls, status: .pending)
        for update in updates {
          actions.append(.tools(.statusSet(id: update.id, status: update.status)))
        }
      }

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      actions.append(.status(.updated(status)))

      actions.append(.inference(.persisted))
      return actions
    }
  }
}

/// Replace blob URIs in image content blocks with base64-encoded data for LLM consumption.
private func hydrateImageBlobs(in messages: [Message]) async -> [Message] {
  var result: [Message] = []
  for message in messages {
    switch message {
    case var .user(u):
      u.content = await hydrateBlocks(u.content)
      result.append(.user(u))
    case let .assistant(a):
      result.append(.assistant(a))
    case var .toolResult(t):
      t.content = await hydrateBlocks(t.content)
      result.append(.toolResult(t))
    }
  }
  return result
}

private func hydrateBlocks(_ blocks: [ContentBlock]) async -> [ContentBlock] {
  var result: [ContentBlock] = []
  for block in blocks {
    await result.append(hydrateBlock(block))
  }
  return result
}

private func hydrateBlock(_ block: ContentBlock) async -> ContentBlock {
  guard case let .image(img) = block, img.data.hasPrefix("blob://") else { return block }
  do {
    let base64 = try await BlobBucket.resolveToBase64(uri: img.data)
    return .image(.init(data: base64, mimeType: img.mimeType))
  } catch {
    return .text(.init(text: "[Failed to load image: \(error)]"))
  }
}
