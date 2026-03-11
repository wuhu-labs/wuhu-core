import Foundation
import Observation

@MainActor
@Observable
public final class SessionViewModel {
  public private(set) var state: AgentState

  private let session: SessionActor
  private var observationTask: Task<Void, Never>?

  public init(session: SessionActor) {
    self.session = session
    self.state = AgentState()
  }

  public func start() {
    guard observationTask == nil else { return }

    observationTask = Task {
      let stream = await session.subscribe()
      for await state in stream {
        self.state = state
      }
    }
  }

  public func send(_ text: String) async {
    await session.sendUserMessage(text)
  }

  public func stop() async {
    await session.stop()
  }

  public func resume() async {
    await session.resume()
  }
}
