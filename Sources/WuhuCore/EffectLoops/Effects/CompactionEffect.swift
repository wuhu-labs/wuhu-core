import Dependencies
import Foundation
import PiAI
import WuhuAPI

/// Effect factory for transcript compaction.
extension AgentBehavior {
  /// Summarize transcript and persist compaction entry.
  func runCompaction(state: AgentState) -> AgentEffect {
    let sessionID = sessionID
    let store = store
    let entries = state.transcript.entries
    let settingsSnapshot = state.settings.snapshot

    return .run("compaction") { send in
      @Dependency(\.streamFn) var streamFn
      defer { Task { await send(AgentAction.transcript(.compactionFinished)) } }

      let session = try await store.getSession(id: sessionID.rawValue)
      let provider = session.provider.piProvider
      let settingsModel = Model(id: session.model, provider: provider)
      let settings = CompactionSettings.load(model: settingsModel)

      guard let prep = CompactionEngine.prepareCompaction(transcript: entries, settings: settings) else {
        return
      }

      let resolved = WuhuModelCatalog.resolveAlias(session.model)
      let apiModel = Model(id: resolved.apiModelID, provider: provider, baseURL: providerBaseURL(for: provider))
      var requestOptions = makeRequestOptions(model: apiModel, settings: settingsSnapshot, userModelID: session.model)
      mergeBetaFeatures(resolved.betaFeatures, into: &requestOptions)

      let summary = try await CompactionEngine.generateSummary(
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
      await send(AgentAction.transcript(.append(entry)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      await send(AgentAction.status(.updated(status)))
    }
  }
}
