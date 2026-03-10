import Dependencies
import PiAI

public typealias StreamFn = @Sendable (Model, Context, RequestOptions) async throws
  -> AsyncThrowingStream<AssistantMessageEvent, any Error>

// MARK: - Dependency registration

private enum StreamFnKey: DependencyKey {
  static let liveValue: StreamFn = PiAI.streamSimple
  static let testValue: StreamFn = PiAI.streamSimple
}

public extension DependencyValues {
  var streamFn: StreamFn {
    get { self[StreamFnKey.self] }
    set { self[StreamFnKey.self] = newValue }
  }
}
