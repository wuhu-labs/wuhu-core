public enum WuhuMountTemplateResolutionError: Error, Sendable, CustomStringConvertible {
  case unknownMountTemplate(String)
  case unsupportedType(String)

  public var description: String {
    switch self {
    case let .unknownMountTemplate(name):
      "Unknown mount template: \(name)"
    case let .unsupportedType(type):
      "Unsupported mount template type: \(type)"
    }
  }
}
