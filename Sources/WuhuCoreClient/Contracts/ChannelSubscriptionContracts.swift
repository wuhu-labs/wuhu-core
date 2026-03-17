import Foundation
import WuhuAPI

/// Initial payload for a channel subscription.
public struct ChannelInitialState: Sendable, Hashable, Codable {
  public var channel: WuhuChannel
  public var members: [WuhuChannelMember]
  public var messages: [WuhuChannelMessage]

  public init(
    channel: WuhuChannel,
    members: [WuhuChannelMember],
    messages: [WuhuChannelMessage],
  ) {
    self.channel = channel
    self.members = members
    self.messages = messages
  }
}

/// Live channel events emitted after initial state.
public enum ChannelEvent: Sendable, Hashable, Codable {
  case messagePosted(WuhuChannelMessage)
  case memberJoined(WuhuChannelMember)
  case memberLeft(userID: String)
  case channelUpdated(WuhuChannel)
}

/// Wire format for `GET /v1/channels/:id/subscribe`.
public enum ChannelSubscriptionSSEFrame: Sendable, Hashable, Codable {
  case initial(ChannelInitialState)
  case event(ChannelEvent)
}
