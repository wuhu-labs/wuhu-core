import Foundation
import PiAI
import WuhuAPI

enum PromptPreparation {
  static func extractHeader(from transcript: [WuhuSessionEntry], sessionID: String) throws -> WuhuSessionHeader {
    guard let headerEntry = transcript.first(where: { $0.parentEntryID == nil }) else {
      throw StoreError.noHeaderEntry(sessionID)
    }
    guard case let .header(header) = headerEntry.payload else {
      throw StoreError.sessionCorrupt("Header entry \(headerEntry.id) payload is not header")
    }
    return header
  }

  static func extractReasoningEffort(from header: WuhuSessionHeader) -> ReasoningEffort? {
    guard let metadata = header.metadata.object else { return nil }
    guard let raw = metadata["reasoningEffort"]?.stringValue else { return nil }
    return ReasoningEffort(rawValue: raw)
  }

  static func extractContextMessages(from transcript: [WuhuSessionEntry]) -> [Message] {
    let headerIndex = transcript.firstIndex(where: { $0.parentEntryID == nil }) ?? 0
    let reminderIndex = GroupChat.reminderEntryIndex(in: transcript)

    var summary: String?
    var firstKeptEntryID: Int64?

    if let entry = transcript.last(where: { if case .compaction = $0.payload { return true }; return false }),
       case let .compaction(compaction) = entry.payload
    {
      summary = compaction.summary
      firstKeptEntryID = compaction.firstKeptEntryID
    }

    let startIndex: Int = if let firstKeptEntryID {
      transcript.firstIndex(where: { $0.id == firstKeptEntryID }) ?? min(headerIndex + 1, transcript.count)
    } else {
      min(headerIndex + 1, transcript.count)
    }

    var messages: [Message] = []
    if let summary, !summary.isEmpty {
      messages.append(CompactionEngine.makeSummaryMessage(summary: summary))
    }

    // Track pending tool calls so we can defer context entries that land
    // between an assistant tool_use and its tool_result. Anthropic requires
    // tool_result messages to immediately follow the assistant message that
    // issued the tool_use — interleaving user messages breaks the API.
    var pendingToolCallIDs: Set<String> = []
    var deferredContextMessages: [Message] = []

    for (idx, entry) in transcript[startIndex...].enumerated() {
      let entryIndex = startIndex + idx

      // Convert context custom entries (AGENTS.md, skills, mount announcements) into user messages
      if case let .custom(customType, data) = entry.payload,
         [
           WuhuCustomMessageTypes.agentsContext,
           WuhuCustomMessageTypes.skillsContext,
           WuhuCustomMessageTypes.mountContext
         ].contains(customType),
         case let .object(obj) = data,
         case let .string(text) = obj["text"],
         !text.isEmpty
      {
        let userMsg = Message.user(UserMessage(content: [.text(text)]))
        if pendingToolCallIDs.isEmpty {
          messages.append(userMsg)
        } else {
          // Defer until all pending tool results arrive
          deferredContextMessages.append(userMsg)
        }
        continue
      }

      guard case let .message(m) = entry.payload else { continue }
      guard let pi = GroupChat.renderForLLM(message: m, entryIndex: entryIndex, reminderIndex: reminderIndex) else { continue }

      // Track tool call lifecycle
      switch pi {
      case let .assistant(a):
        for block in a.content {
          if case let .toolCall(call) = block {
            pendingToolCallIDs.insert(call.id)
          }
        }
      case let .toolResult(r):
        pendingToolCallIDs.remove(r.toolCallId)
        messages.append(pi)
        // Flush deferred context messages once all tool results are in
        if pendingToolCallIDs.isEmpty, !deferredContextMessages.isEmpty {
          messages.append(contentsOf: deferredContextMessages)
          deferredContextMessages.removeAll()
        }
        continue
      default:
        break
      }

      messages.append(pi)
    }

    // Flush any remaining deferred messages (shouldn't happen in normal flow)
    messages.append(contentsOf: deferredContextMessages)

    return ToolRepairer.repairMissingToolResultsInMemory(messages)
  }

  static func extractLatestSessionSettings(from transcript: [WuhuSessionEntry]) -> WuhuSessionSettings? {
    for entry in transcript.reversed() {
      if case let .sessionSettings(s) = entry.payload {
        return s
      }
    }
    return nil
  }

  static func normalizeUser(_ user: String?) -> String {
    let trimmed = (user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? WuhuUserMessage.unknownUser : trimmed
  }

  static func firstPromptingUser(in transcript: [WuhuSessionEntry]) -> String? {
    for entry in transcript {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .user(u) = m else { continue }
      return u.user
    }
    return nil
  }
}
