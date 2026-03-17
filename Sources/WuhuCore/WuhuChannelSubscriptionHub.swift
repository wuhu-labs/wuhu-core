import Foundation
import WuhuAPI
import WuhuCoreClient

/// In-process pub/sub for channel events.
public actor WuhuChannelSubscriptionHub {
  private var subscribers: [String: [UUID: AsyncStream<ChannelEvent>.Continuation]] = [:]

  public init() {}

  public func subscribe(channelID: String) -> AsyncStream<ChannelEvent> {
    AsyncStream(ChannelEvent.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let token = UUID()
      subscribers[channelID, default: [:]][token] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeSubscriber(channelID: channelID, token: token) }
      }
    }
  }

  public func publish(channelID: String, event: ChannelEvent) {
    guard let channelSubs = subscribers[channelID], !channelSubs.isEmpty else { return }
    for (_, continuation) in channelSubs {
      continuation.yield(event)
    }
  }

  private func removeSubscriber(channelID: String, token: UUID) {
    subscribers[channelID]?[token] = nil
    if subscribers[channelID]?.isEmpty == true {
      subscribers[channelID] = nil
    }
  }
}
