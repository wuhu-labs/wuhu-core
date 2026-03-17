import Foundation
import WuhuAPI

/// Cursor for channel message pagination.
public struct ChannelMessageCursor: RawRepresentable, Sendable, Hashable, Codable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(messageID: Int64) {
    rawValue = String(messageID)
  }

  public var messageID: Int64? {
    Int64(rawValue)
  }
}

/// Parameters for establishing a channel subscription.
public struct ChannelSubscriptionRequest: Sendable, Hashable, Codable {
  public var messageSince: ChannelMessageCursor?
  public var pageSize: Int

  public init(messageSince: ChannelMessageCursor? = nil, pageSize: Int = 50) {
    self.messageSince = messageSince
    self.pageSize = pageSize
  }
}

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
