import Foundation
import PiAI

func makeRequestOptions(model: Model, settings: SessionSettingsSnapshot, userModelID: String? = nil) -> RequestOptions {
  var requestOptions = RequestOptions()

  // Max tokens: use model spec (maxOutput / 3) or a generous fallback.
  // Look up by user-facing model ID first (for alias specs), then fall back to API model ID.
  let specLookupID = userModelID ?? model.id
  requestOptions.maxTokens = WuhuModelCatalog.defaultMaxTokens(for: specLookupID)

  if let effort = settings.effectiveReasoningEffort {
    requestOptions.reasoningEffort = effort
  } else if model.provider == .openai || model.provider == .openaiCodex,
            model.id.contains("gpt-5") || model.id.contains("codex")
  {
    requestOptions.reasoningEffort = .low
  }
  if model.provider == .anthropic {
    requestOptions.anthropicPromptCaching = .init(mode: .explicitBreakpoints)
    requestOptions.maxTokens = requestOptions.maxTokens ?? 4096
  }
  return requestOptions
}

func mergeBetaFeatures(_ features: [String], into options: inout RequestOptions) {
  guard !features.isEmpty else { return }
  let existing = options.headers["anthropic-beta"] ?? ""
  var items = existing.isEmpty ? [] : existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  for feature in features where !items.contains(feature) {
    items.append(feature)
  }
  options.headers["anthropic-beta"] = items.joined(separator: ", ")
}

func modelFromSettings(_ settings: SessionSettingsSnapshot) -> Model {
  let provider: Provider = switch settings.effectiveModel.provider.rawValue {
  case ProviderID.openai.rawValue:
    .openai
  case ProviderID.openaiCodex.rawValue:
    .openaiCodex
  case ProviderID.anthropic.rawValue:
    .anthropic
  default:
    .openai
  }
  return .init(id: settings.effectiveModel.id, provider: provider)
}

/// Resolves an optional base URL override for a provider from environment
/// variables. Checks `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL`.
func providerBaseURL(for provider: Provider) -> URL? {
  let envVar: String? = switch provider {
  case .anthropic:
    ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"]
  case .openai, .openaiCodex:
    ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
  }
  guard let value = envVar, let url = URL(string: value) else { return nil }
  return url
}
