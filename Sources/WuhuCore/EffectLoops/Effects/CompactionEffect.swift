import Foundation
import PiAI
import WuhuAPI

/// Effect factory for transcript compaction.
extension WuhuBehavior {
  /// Summarize transcript and persist compaction entry.
  func runCompaction(state: WuhuState) -> Effect<WuhuAction> {
    let sessionID = sessionID
    let store = store
    let runtimeConfig = runtimeConfig
    let llmRequestLogger = llmRequestLogger
    let baseStreamFn = baseStreamFn
    let entries = state.transcript.entries
    let settingsSnapshot = state.settings.snapshot

    return Effect { send in
      defer { Task { await send(WuhuAction.transcript(.compactionFinished)) } }

      let session = try await store.getSession(id: sessionID.rawValue)
      let provider = session.provider.piProvider
      let settingsModel = Model(id: session.model, provider: provider)
      let settings = WuhuCompactionSettings.load(model: settingsModel)

      guard let prep = WuhuCompactionEngine.prepareCompaction(transcript: entries, settings: settings) else {
        return
      }

      let resolved = WuhuModelCatalog.resolveAlias(session.model)
      let apiModel = Model(id: resolved.apiModelID, provider: provider, baseURL: providerBaseURL(for: provider))
      let streamFn = llmRequestLogger?.makeLoggedStreamFn(base: baseStreamFn, sessionID: sessionID.rawValue, purpose: .agent) ?? baseStreamFn
      var requestOptions = makeRequestOptions(model: apiModel, settings: settingsSnapshot, userModelID: session.model)
      mergeBetaFeatures(resolved.betaFeatures, into: &requestOptions)

      let summary = try await WuhuCompactionEngine.generateSummary(
        preparation: prep,
        model: apiModel,
        settings: settings,
        requestOptions: requestOptions,
        streamFn: streamFn,
      )

      let payload: WuhuEntryPayload = .compaction(.init(
        summary: summary,
        tokensBefore: prep.tokensBefore,
        firstKeptEntryID: prep.firstKeptEntryID,
      ))

      let (_, entry) = try await store.appendEntryWithSession(
        sessionID: sessionID,
        payload: payload,
        createdAt: Date(),
      )
      await send(WuhuAction.transcript(.append(entry)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      await send(WuhuAction.status(.updated(status)))
    }
  }
}
