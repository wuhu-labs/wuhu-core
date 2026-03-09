import Foundation
import WuhuAPI

/// Static pricing table for computing session cost from token usage.
///
/// Prices are in **hundredths-of-a-cent per million tokens** (Int64).
/// This avoids floating-point drift — a $500 spend = 5,000,000,000 units,
/// which fits comfortably in Int64.
enum WuhuPricingTable {
  struct ModelPrice: Sendable {
    var inputPricePerMTok: Int64
    var outputPricePerMTok: Int64
  }

  /// Lookup table keyed by (provider rawValue, model ID).
  private static let prices: [String: ModelPrice] = {
    var table: [String: ModelPrice] = [:]

    // Anthropic
    let opus = ModelPrice(inputPricePerMTok: 1500, outputPricePerMTok: 7500)
    table["anthropic:claude-opus-4-5"] = opus
    table["anthropic:claude-opus-4-6"] = opus

    let sonnet = ModelPrice(inputPricePerMTok: 300, outputPricePerMTok: 1500)
    table["anthropic:claude-sonnet-4-5"] = sonnet
    table["anthropic:claude-sonnet-4-6"] = sonnet

    let haiku = ModelPrice(inputPricePerMTok: 80, outputPricePerMTok: 400)
    table["anthropic:claude-haiku-4-5"] = haiku

    // Anthropic 1M context aliases (same pricing as base model)
    table["anthropic:claude-opus-4-6[1m]"] = opus
    table["anthropic:claude-sonnet-4-6[1m]"] = sonnet

    // OpenAI
    let gpt5 = ModelPrice(inputPricePerMTok: 200, outputPricePerMTok: 800)
    for model in ["gpt-5", "gpt-5.1", "gpt-5.2", "gpt-5-codex", "gpt-5.1-codex", "gpt-5.2-codex"] {
      table["openai:\(model)"] = gpt5
    }

    // OpenAI Codex
    for model in ["codex-mini-latest", "gpt-5-codex", "gpt-5.1", "gpt-5.1-codex", "gpt-5.2", "gpt-5.2-codex", "gpt-5.3-codex"] {
      table["openai-codex:\(model)"] = gpt5
    }

    return table
  }()

  /// Conservative fallback price (Opus pricing — most expensive known).
  static let fallbackPrice = ModelPrice(inputPricePerMTok: 1500, outputPricePerMTok: 7500)

  /// Look up the price for a (provider, model) pair.
  static func price(provider: WuhuProvider, model: String) -> ModelPrice {
    let key = "\(provider.rawValue):\(model)"
    if let found = prices[key] { return found }
    let line = "[WuhuPricingTable] WARNING: Unknown model '\(key)', using fallback (Opus) pricing\n"
    FileHandle.standardError.write(Data(line.utf8))
    return fallbackPrice
  }

  /// Compute cost for a single assistant entry's usage.
  ///
  /// Returns cost in hundredths-of-a-cent.
  static func computeEntryCost(
    provider: WuhuProvider,
    model: String,
    usage: WuhuUsage,
  ) -> Int64 {
    let p = price(provider: provider, model: model)
    let inputCost = Int64(usage.inputTokens) * p.inputPricePerMTok
    let outputCost = Int64(usage.outputTokens) * p.outputPricePerMTok
    return (inputCost + outputCost) / 1_000_000
  }

  /// Compute total cost from a list of transcript entries.
  ///
  /// Iterates assistant message entries, extracts (provider, model, usage),
  /// and sums cost. Divides once at the end to minimize rounding loss.
  static func computeCost(entries: [WuhuSessionEntry]) -> Int64 {
    var totalNumerator: Int64 = 0

    for entry in entries {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .assistant(a) = m else { continue }
      guard let usage = a.usage else { continue }

      let p = price(provider: a.provider, model: a.model)
      totalNumerator += Int64(usage.inputTokens) * p.inputPricePerMTok
      totalNumerator += Int64(usage.outputTokens) * p.outputPricePerMTok
    }

    return totalNumerator / 1_000_000
  }
}
