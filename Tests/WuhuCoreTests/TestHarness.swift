import Dependencies
import Foundation
import PiAI
import WuhuAPI
@testable import WuhuCore

// MARK: - TestHarness

/// A self-contained test harness that exercises the full session lifecycle
/// (create → enqueue → LLM → tools → transcript) without a real HTTP server or LLM.
///
/// The harness wires together:
/// - `SQLiteSessionStore` with `:memory:` database
/// - `WuhuService` with a mock `StreamFn`
/// - `InMemoryFileIO` via swift-dependencies
/// - `DataBucket` configured via swift-dependencies
struct TestHarness {
  let service: WuhuService
  let store: SQLiteSessionStore
  let mockLLM: MockStreamFn?

  /// Optional InMemoryFileIO for tool tests. If nil, tools won't use InMemoryFileIO.
  let fileIO: InMemoryFileIO?

  init(
    mockLLM: MockStreamFn,
    fileIO: InMemoryFileIO? = nil,
    workspaceRoot: String? = nil,
  ) throws {
    self.mockLLM = mockLLM
    self.fileIO = fileIO
    store = try SQLiteSessionStore(path: ":memory:")

    service = WuhuService(
      store: store,
      workspaceRoot: workspaceRoot,
      runnerRegistry: RunnerRegistry(runners: [LocalRunner()]),
    ) {
      $0.streamFn = mockLLM.streamFn
      $0.dataBucket = LocalDataBucket(rootDirectory: NSTemporaryDirectory() + "wuhu-test-data-\(UUID().uuidString.lowercased())")
    }
  }

  /// Init with a raw `StreamFn` instead of `MockStreamFn`.
  init(
    streamFn: @escaping StreamFn,
    fileIO: InMemoryFileIO? = nil,
    workspaceRoot: String? = nil,
  ) throws {
    mockLLM = nil
    self.fileIO = fileIO
    store = try SQLiteSessionStore(path: ":memory:")

    service = WuhuService(
      store: store,
      workspaceRoot: workspaceRoot,
      runnerRegistry: RunnerRegistry(runners: [LocalRunner()]),
    ) {
      $0.streamFn = streamFn
      $0.dataBucket = LocalDataBucket(rootDirectory: NSTemporaryDirectory() + "wuhu-test-data-\(UUID().uuidString.lowercased())")
    }
  }

  /// Create a new harness re-using the same store (simulates server restart).
  func newServiceSameStore(mockLLM newMock: MockStreamFn) -> WuhuService {
    WuhuService(
      store: store,
      runnerRegistry: RunnerRegistry(runners: [LocalRunner()]),
    ) {
      $0.streamFn = newMock.streamFn
      $0.dataBucket = LocalDataBucket(rootDirectory: NSTemporaryDirectory() + "wuhu-test-data-\(UUID().uuidString.lowercased())")
    }
  }

  // MARK: - Session creation

  /// Create a session with an optional mount path (cwd).
  func createSession(
    cwd: String? = nil,
    provider: WuhuProvider = .openai,
    model: String = "mock-model",
    systemPrompt: String = "You are a test assistant.",
  ) async throws -> WuhuSession {
    let sessionID = UUID().uuidString.lowercased()
    return try await service.createSession(
      sessionID: sessionID,
      provider: provider,
      model: model,
      systemPrompt: systemPrompt,
      cwd: cwd,
    )
  }

  // MARK: - Enqueue and wait

  /// Enqueue a user message on the follow-up lane and wait for the session to go idle.
  func enqueueAndWaitForIdle(
    _ text: String,
    sessionID: String,
    timeout: TimeInterval = 15,
  ) async throws {
    let message = QueuedUserMessage(
      author: .participant(.init(rawValue: "test-user"), kind: .human),
      content: .text(text),
    )
    _ = try await service.enqueue(sessionID: .init(rawValue: sessionID), message: message, lane: .followUp)

    // Follow the session stream and wait for idle.
    let stream = try await service.followSessionStream(
      sessionID: sessionID,
      sinceCursor: nil,
      sinceTime: nil,
      stopAfterIdle: true,
      timeoutSeconds: timeout,
    )

    for try await event in stream {
      switch event {
      case .idle, .done:
        return
      default:
        continue
      }
    }
  }

  // MARK: - Transcript access

  /// Get the full transcript for a session.
  func transcript(sessionID: String) async throws -> [WuhuSessionEntry] {
    try await store.getEntries(sessionID: sessionID)
  }

  /// Extract all message payloads from a transcript.
  func messages(sessionID: String) async throws -> [WuhuPersistedMessage] {
    let entries = try await transcript(sessionID: sessionID)
    return entries.compactMap { entry in
      if case let .message(m) = entry.payload { return m }
      return nil
    }
  }

  /// Extract text from assistant messages in the transcript.
  func assistantTexts(sessionID: String) async throws -> [String] {
    let msgs = try await messages(sessionID: sessionID)
    return msgs.compactMap { msg in
      guard case let .assistant(a) = msg else { return nil }
      return a.content.compactMap { block in
        if case let .text(text: text, signature: _) = block { return text }
        return nil
      }.joined()
    }
  }

  /// Check if any entry has a compaction payload.
  func hasCompactionEntry(sessionID: String) async throws -> Bool {
    let entries = try await transcript(sessionID: sessionID)
    return entries.contains { entry in
      if case .compaction = entry.payload { return true }
      return false
    }
  }
}
