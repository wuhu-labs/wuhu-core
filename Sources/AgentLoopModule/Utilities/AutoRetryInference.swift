import WuhuAI


// this is a dump ground

/*
 tool call


   let argsHash = call.arguments.hashValue
   let count = repetitionTracker.preflightCount(toolName: call.name, argsHash: argsHash)

   if count >= ToolCallRepetitionTracker.blockThreshold {
     let blockedResult = behavior.blockedToolResult(for: call)
     behavior.persistToolResult(blockedResult, for: call, state: &state)
     try await waitUntilDurableCurrentVersion()
     return
   }

 let resultHash = toolResult.hashValue
 let recordedCount = repetitionTracker.record(
   toolName: call.name,
   argsHash: argsHash,
   resultHash: resultHash,
 )


 private static var maxInferenceRetries: Int {
   10
 }

 private func performInferenceWithRetry(context: Context) async throws -> AssistantMessage {
   var lastError: (any Error)?
   for attempt in 0 ... Self.maxInferenceRetries {
     if stopRequested {
       throw CancellationError()
     }

     if attempt > 0 {
       let delay = min(pow(2, Double(attempt - 1)), 60)
       let jitter = delay * Double.random(in: -0.25 ... 0.25)
       try await sleepBackoff(seconds: delay + jitter)
     }

     do {
       return try await performInference(context: context)
     } catch is CancellationError {
       throw CancellationError()
     } catch {
       lastError = error
       guard Self.isTransientError(error) else { throw error }
     }
   }
   throw lastError ?? AgentLoopError.inferenceProducedNoResult
 }

 private func sleepBackoff(seconds: Double) async throws {
   var remaining = max(0, seconds)
   while remaining > 0 {
     if stopRequested {
       throw CancellationError()
     }

     let slice = min(0.1, remaining)
     try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
     remaining -= slice
   }
 }

 private nonisolated static func isTransientError(_ error: any Error) -> Bool {
   if let piError = error as? WuhuAIError,
      case let .httpStatus(code, _) = piError
   {
     return code == 429 || code == 500 || code == 502 || code == 503 || code == 529
   }

   let description = String(describing: error)
   if description.contains("remoteConnectionClosed")
     || description.contains("connectTimeout")
     || description.contains("readTimeout")
   {
     return true
   }

   return false
 }


 public enum ToolCallRepetitionError: Error, CustomStringConvertible {
   case blocked

   public var description: String {
     ToolCallRepetitionTracker.blockText
   }
 }


 */
