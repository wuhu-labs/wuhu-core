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
    let blobStore = blobStore
    let entries = state.transcript.entries
    return Effect { send in
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
        let streamFn = await runtimeConfig.streamFn()

        // Build context
        let header = (try? WuhuPromptPreparation.extractHeader(from: entries, sessionID: sessionID.rawValue))
        let systemPrompt = header?.systemPrompt ?? ""
        let messages = WuhuPromptPreparation.extractContextMessages(from: entries)
        let hydrated = hydrateImageBlobs(in: messages, blobStore: blobStore)

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
private func hydrateImageBlobs(in messages: [Message], blobStore: WuhuBlobStore) -> [Message] {
  messages.map { message in
    switch message {
    case var .user(u):
      u.content = u.content.map { hydrateBlock($0, blobStore: blobStore) }
      return .user(u)
    case let .assistant(a):
      return .assistant(a)
    case var .toolResult(t):
      t.content = t.content.map { hydrateBlock($0, blobStore: blobStore) }
      return .toolResult(t)
    }
  }
}

private func hydrateBlock(_ block: ContentBlock, blobStore: WuhuBlobStore) -> ContentBlock {
  guard case let .image(img) = block, img.data.hasPrefix("blob://") else { return block }
  do {
    let base64 = try blobStore.resolveToBase64(uri: img.data)
    return .image(.init(data: base64, mimeType: img.mimeType))
  } catch {
    return .text(.init(text: "[Failed to load image: \(error)]"))
  }
}
