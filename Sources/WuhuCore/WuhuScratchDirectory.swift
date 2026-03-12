import Foundation

/// Creates and manages per-session scratch directories.
///
/// When a session calls `mount({})` with no path, a scratch directory is created
/// at `~/.wuhu/scratch/<sessionID>` so the agent has a private workspace.
public enum WuhuScratchDirectory {
  /// The root directory under which all scratch directories live.
  public static func scratchRoot() -> String {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".wuhu/scratch")
      .path
  }

  /// Creates a scratch directory for the given session ID and returns its absolute path.
  ///
  /// The directory is created at `~/.wuhu/scratch/<sessionID>`. If it already
  /// exists (e.g. from a previous mount call), this is a no-op and the existing
  /// path is returned.
  public static func create(sessionID: String) throws -> String {
    let root = scratchRoot()
    let dirPath = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent(sessionID, isDirectory: true)
      .path

    try FileManager.default.createDirectory(
      atPath: dirPath,
      withIntermediateDirectories: true,
    )

    return dirPath
  }
}
