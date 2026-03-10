import Dependencies
import Foundation
import PiAI

/// Effect factory for running inference (streaming LLM call).
extension WuhuBehavior {
  /// Calls PiAI streaming API, sends `.inference(.delta)` for each text chunk,
  /// `.inference(.completed)` on success, `.inference(.failed)` on error.
  func runInference(state: WuhuState) -> Effect<WuhuAction> {
    let sessionID = sessionID
    let store = store
    let runtimeConfig = runtimeConfig
    let entries = state.transcript.entries
    return Effect { send in
      @Dependency(\.streamFn) var streamFn
      await send(WuhuAction.inference(.started))

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
        let header = (try? WuhuPromptPreparation.extractHeader(from: entries, sessionID: sessionID.rawValue))
        let systemPrompt = header?.systemPrompt ?? ""
        let messages = WuhuPromptPreparation.extractContextMessages(from: entries)
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
            await send(WuhuAction.inference(.delta(delta)))
            partial = p
          case let .done(message):
            final = message
          }
        }

        guard let message = final ?? partial else {
          throw PiAIError.unsupported("No model output")
        }

        // Persist assistant entry
        let (_, entry) = try await store.appendEntryWithSession(
          sessionID: sessionID,
          payload: .message(.fromPi(.assistant(message))),
          createdAt: message.timestamp,
        )
        await send(WuhuAction.transcript(.append(entry)))

        // Track cost for this inference (use resolved model from the response, not the session alias)
        if let usage = message.usage {
          let entryCost = WuhuPricingTable.computeEntryCost(
            provider: session.provider,
            model: message.model,
            usage: WuhuUsage.fromPi(usage),
          )
          if entryCost > 0 {
            await send(WuhuAction.cost(.spent(entryCost)))
          }
        }

        // Upsert tool call statuses for any tool calls in the response
        let calls = message.content.compactMap { block -> ToolCall? in
          if case let .toolCall(c) = block { return c }
          return nil
        }
        if !calls.isEmpty {
          let updates = try await store.upsertToolCallStatuses(sessionID: sessionID, calls: calls, status: .pending)
          for update in updates {
            await send(WuhuAction.tools(.statusSet(id: update.id, status: update.status)))
          }
        }

        let status = try await store.loadStatusSnapshot(sessionID: sessionID)
        await send(WuhuAction.status(.updated(status)))

        await send(WuhuAction.inference(.completed(message)))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        await send(WuhuAction.inference(.failed(InferenceError.from(error))))
      }
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
