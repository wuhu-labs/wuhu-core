import WuhuAI

public struct SessionTranscript: Equatable, Sendable {
  public var items: [SessionItem] = []

  public var pendingToolCalls: [ToolCall] {
    var i = items.endIndex - 1
    var completedToolCalls = Set<String>()

    while i >= items.startIndex {
      switch items[i].content {
      case .assistant(let message):
        var toolCalls: [ToolCall] = []
        for content in message.content {
          if case .toolCall(let toolCall) = content,
             !completedToolCalls.contains(toolCall.id)
          {
            toolCalls.append(toolCall)
          }
        }
        return toolCalls

      case .toolResult(let toolResult):
        completedToolCalls.insert(toolResult.toolCallId)

      default:
        break
      }

      i -= 1
    }

    return []
  }

  var needsInference: Bool {
    guard let lastItem = items.last,
          pendingToolCalls.isEmpty
    else { return false }

    switch lastItem.content {
    case .assistant, .interruption:
      return false
    default:
      return true
    }
  }

  var canDrainFollowUp: Bool {
    guard case .assistant = items.last?.content, pendingToolCalls.isEmpty else { return false }
    return true
  }
}
