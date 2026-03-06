import ArgumentParser
import Foundation
import PiAI

// MARK: - Version subcommand

struct VersionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "version",
    abstract: "Print detailed version information.",
  )

  func run() {
    print("wuhu \(WuhuVersion.display)")
    print("  platform: \(WuhuVersion.platform)")
  }
}

// MARK: - Upgrade subcommand

struct UpgradeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upgrade",
    abstract: "Upgrade wuhu to the latest (or a specific) version.",
  )

  @Option(name: .long, help: "Install a specific version instead of the latest.")
  var target: String?

  @Flag(help: "Check for updates without installing.")
  var dryRun: Bool = false

  func run() async throws {
    let current = WuhuVersion.version

    // If a specific version is requested and already installed locally, just switch the symlink.
    if let requestedVersion = target {
      let binDir = WuhuPaths.binDir
      let versionDir = binDir.appendingPathComponent(requestedVersion)
      let versionBinary = versionDir.appendingPathComponent("wuhu")
      if FileManager.default.fileExists(atPath: versionBinary.path) {
        if dryRun {
          print("Version \(requestedVersion) is already downloaded at \(versionDir.path)")
          return
        }
        try WuhuPaths.atomicSymlinkSwap(
          link: binDir.appendingPathComponent("wuhu"),
          target: "\(requestedVersion)/wuhu",
        )
        print("Switched to wuhu \(requestedVersion) (already downloaded)")
        return
      }
    }

    // Resolve latest version from GitHub Releases
    let http = AsyncHTTPClientTransport()
    let release: GitHubRelease
    if let requestedVersion = target {
      release = try await fetchGitHubRelease(http: http, tag: requestedVersion)
    } else {
      release = try await fetchLatestGitHubRelease(http: http)
    }

    let targetVersion = release.tagName

    if dryRun {
      print("Current: wuhu \(current)")
      print("Latest:  wuhu \(targetVersion)")
      if current == targetVersion {
        print("Already up to date.")
      }
      return
    }

    if current == targetVersion && target == nil {
      print("Already up to date: wuhu \(current)")
      return
    }

    // Find the right asset for this platform
    let platform = WuhuVersion.platform
    let assetName = "wuhu-\(platform).tar.gz"
    guard let asset = release.assets.first(where: { $0.name == assetName }) else {
      throw UpgradeError.noAsset(platform: platform, version: targetVersion,
        available: release.assets.map(\.name))
    }

    // Download
    print("Downloading wuhu \(targetVersion) for \(platform)...")
    let archiveData = try await downloadAsset(http: http, url: asset.browserDownloadUrl)
    print("Downloaded \(ByteCountFormatter.string(fromByteCount: Int64(archiveData.count), countStyle: .file))")

    // Install
    let binDir = WuhuPaths.binDir
    let versionDir = binDir.appendingPathComponent(targetVersion)
    try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

    let binaryPath = versionDir.appendingPathComponent("wuhu")
    try extractTarGz(archiveData, toBinary: binaryPath)

    // Make executable
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)

    // Verify the new binary works
    try verifyBinary(binaryPath)

    // Atomic symlink swap
    let symlinkPath = binDir.appendingPathComponent("wuhu")
    try WuhuPaths.atomicSymlinkSwap(link: symlinkPath, target: "\(targetVersion)/wuhu")

    print("Upgraded: \(current) → \(targetVersion)")
    print("Binary:   \(binaryPath.path)")
  }
}

// MARK: - Paths

enum WuhuPaths {
  /// ~/.wuhu/bin/
  static var binDir: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu")
      .appendingPathComponent("bin")
  }

  /// Atomically swap a symlink to point to a new target (relative path).
  ///
  /// Creates a temporary symlink next to the target, then uses rename(2)
  /// to atomically replace the real one. There is never a moment where
  /// the link path doesn't exist.
  static func atomicSymlinkSwap(link: URL, target: String) throws {
    let dir = link.deletingLastPathComponent().path
    let tmpName = ".wuhu-symlink-\(ProcessInfo.processInfo.processIdentifier)"
    let tmpPath = "\(dir)/\(tmpName)"

    // Clean up any leftover temp symlink from a previous crash
    try? FileManager.default.removeItem(atPath: tmpPath)

    // Create temp symlink
    try FileManager.default.createSymbolicLink(
      atPath: tmpPath,
      withDestinationPath: target,
    )

    // Atomic rename over the real symlink
    guard rename(tmpPath, link.path) == 0 else {
      let err = errno
      try? FileManager.default.removeItem(atPath: tmpPath)
      throw UpgradeError.renameFailed(errno: err)
    }
  }
}

// MARK: - Resolve current executable

enum ExecutablePath {
  static func resolve() throws -> String {
    #if os(Linux)
    return try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
    #elseif os(macOS)
    var buf = [CChar](repeating: 0, count: 4096)
    var size = UInt32(buf.count)
    guard _NSGetExecutablePath(&buf, &size) == 0 else {
      throw UpgradeError.cannotResolveExePath
    }
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    #else
    throw UpgradeError.unsupportedPlatform
    #endif
  }
}

// MARK: - GitHub Releases API

private struct GitHubRelease: Sendable {
  var tagName: String
  var assets: [Asset]

  struct Asset: Sendable {
    var name: String
    var browserDownloadUrl: String
    var size: Int
  }
}

private let githubRepo = "wuhu-labs/wuhu-core"

private func fetchLatestGitHubRelease(http: some HTTPClient) async throws -> GitHubRelease {
  let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
  return try await fetchRelease(http: http, url: url)
}

private func fetchGitHubRelease(http: some HTTPClient, tag: String) async throws -> GitHubRelease {
  let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/tags/\(tag)")!
  return try await fetchRelease(http: http, url: url)
}

private func fetchRelease(http: some HTTPClient, url: URL) async throws -> GitHubRelease {
  var req = HTTPRequest(url: url, method: "GET")
  req.setHeader("application/vnd.github+json", for: "Accept")
  req.setHeader("wuhu-cli/\(WuhuVersion.version)", for: "User-Agent")

  let (data, response) = try await http.data(for: req)

  guard response.statusCode == 200 else {
    let body = String(decoding: data, as: UTF8.self)
    throw UpgradeError.githubAPI(status: response.statusCode, body: body)
  }

  return try parseReleaseJSON(data)
}

private func parseReleaseJSON(_ data: Data) throws -> GitHubRelease {
  guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let tagName = json["tag_name"] as? String,
    let assets = json["assets"] as? [[String: Any]]
  else {
    throw UpgradeError.badResponse("Could not parse GitHub release JSON")
  }

  let parsed = assets.compactMap { a -> GitHubRelease.Asset? in
    guard let name = a["name"] as? String,
      let url = a["browser_download_url"] as? String,
      let size = a["size"] as? Int
    else { return nil }
    return .init(name: name, browserDownloadUrl: url, size: size)
  }

  return GitHubRelease(tagName: tagName, assets: parsed)
}

// MARK: - Download

private func downloadAsset(http: some HTTPClient, url: String) async throws -> Data {
  guard let downloadURL = URL(string: url) else {
    throw UpgradeError.badResponse("Invalid download URL: \(url)")
  }

  var req = HTTPRequest(url: downloadURL, method: "GET")
  req.setHeader("application/octet-stream", for: "Accept")
  req.setHeader("wuhu-cli/\(WuhuVersion.version)", for: "User-Agent")

  let (data, response) = try await http.data(for: req)
  guard (200 ..< 300).contains(response.statusCode) else {
    throw UpgradeError.downloadFailed(status: response.statusCode)
  }

  return data
}

// MARK: - tar.gz extraction

private func extractTarGz(_ archiveData: Data, toBinary outputPath: URL) throws {
  let fm = FileManager.default

  // Write archive to a temp file
  let tmpDir = fm.temporaryDirectory.appendingPathComponent("wuhu-upgrade-\(ProcessInfo.processInfo.processIdentifier)")
  try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: tmpDir) }

  let archivePath = tmpDir.appendingPathComponent("wuhu.tar.gz")
  try archiveData.write(to: archivePath)

  // Extract using tar
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
  process.arguments = ["xzf", archivePath.path, "-C", tmpDir.path]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()

  guard process.terminationStatus == 0 else {
    throw UpgradeError.extractionFailed(exitCode: Int(process.terminationStatus))
  }

  // Find the wuhu binary in the extracted files
  let extractedBinary = tmpDir.appendingPathComponent("wuhu")
  guard fm.fileExists(atPath: extractedBinary.path) else {
    throw UpgradeError.extractionFailed(exitCode: -1)
  }

  // Move to destination (remove existing first)
  if fm.fileExists(atPath: outputPath.path) {
    try fm.removeItem(at: outputPath)
  }
  try fm.moveItem(at: extractedBinary, to: outputPath)
}

// MARK: - Verify

private func verifyBinary(_ path: URL) throws {
  let process = Process()
  process.executableURL = path
  process.arguments = ["--version"]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()

  guard process.terminationStatus == 0 else {
    throw UpgradeError.verificationFailed
  }
}

// MARK: - Errors

enum UpgradeError: Error, CustomStringConvertible {
  case cannotResolveExePath
  case unsupportedPlatform
  case githubAPI(status: Int, body: String)
  case noAsset(platform: String, version: String, available: [String])
  case badResponse(String)
  case downloadFailed(status: Int)
  case extractionFailed(exitCode: Int)
  case renameFailed(errno: Int32)
  case verificationFailed

  var description: String {
    switch self {
    case .cannotResolveExePath:
      return "Could not determine the path to the current wuhu executable."
    case .unsupportedPlatform:
      return "Self-upgrade is not supported on this platform."
    case let .githubAPI(status, body):
      if status == 404 {
        return "Release not found. Check that the version exists at https://github.com/\(githubRepo)/releases"
      }
      return "GitHub API error (HTTP \(status)): \(body.prefix(200))"
    case let .noAsset(platform, version, available):
      return "No asset for platform '\(platform)' in release \(version). Available: \(available.joined(separator: ", "))"
    case let .badResponse(msg):
      return msg
    case let .downloadFailed(status):
      return "Download failed (HTTP \(status))."
    case let .extractionFailed(exitCode):
      return "Failed to extract archive (tar exit code \(exitCode))."
    case let .renameFailed(errno):
      return "Failed to swap symlink: \(String(cString: strerror(errno)))"
    case .verificationFailed:
      return "New binary failed verification (--version check). The download may be corrupted."
    }
  }
}
