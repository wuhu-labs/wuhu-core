/// Build version metadata.
///
/// CI overwrites this file before release builds to inject the tag and commit.
/// Local / debug builds use the defaults below.
enum WuhuVersion {
  /// Semantic version string. Set to the git tag (e.g. "0.6.0") by CI.
  static let version: String = "dev"

  /// Full git commit SHA. Set by CI.
  static let gitCommit: String = "unknown"

  /// Human-readable one-liner: "0.6.0 (abc1234)" or "dev (local)".
  static var display: String {
    let shortCommit = gitCommit == "unknown" ? "local" : String(gitCommit.prefix(7))
    return "\(version) (\(shortCommit))"
  }

  /// Platform triple for asset matching, e.g. "linux-x86_64", "macos-arm64".
  static var platform: String {
    #if os(Linux) && arch(x86_64)
    return "linux-x86_64"
    #elseif os(Linux) && arch(arm64)
    return "linux-arm64"
    #elseif os(macOS) && arch(arm64)
    return "macos-arm64"
    #elseif os(macOS) && arch(x86_64)
    return "macos-x86_64"
    #else
    return "unknown"
    #endif
  }
}
