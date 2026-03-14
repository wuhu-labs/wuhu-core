// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "wuhu-core",
  platforms: [
    .macOS(.v14),
    .iOS(.v16),
  ],
  products: [
    .library(name: "WuhuAPI", targets: ["WuhuAPI"]),
    .library(name: "WuhuCLIKit", targets: ["WuhuCLIKit"]),
    .library(name: "WuhuCoreClient", targets: ["WuhuCoreClient"]),
    .library(name: "WuhuCore", targets: ["WuhuCore"]),
    .library(name: "WuhuClient", targets: ["WuhuClient"]),
    .library(name: "WuhuServer", targets: ["WuhuServer"]),
    .library(name: "WuhuRunner", targets: ["WuhuRunner"]),
    .executable(name: "wuhu", targets: ["wuhu"]),
    .executable(name: "wuhu-bench-find", targets: ["WuhuBenchFind"]),
  ],
  dependencies: [
    .package(url: "https://github.com/wuhu-labs/wuhu-ai.git", exact: "0.4.1"),
    .package(url: "https://github.com/wuhu-labs/wuhu-workspace-engine.git", exact: "0.1.0"),
    .package(url: "https://github.com/wuhu-labs/wuhu-yamux.git", exact: "0.1.3"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.9.0"),
    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.2.0"),
    .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
  ],
  targets: [
    .target(
      name: "WuhuAPI",
      dependencies: [
        .product(name: "PiAI", package: "wuhu-ai"),
      ],
    ),
    .target(
      name: "WuhuCLIKit",
      dependencies: [
        .product(name: "PiAI", package: "wuhu-ai"),
        "WuhuAPI",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
    ),
    .target(
      name: "WuhuCoreClient",
      dependencies: [
        "WuhuAPI",
        .product(name: "PiAI", package: "wuhu-ai"),
        .product(name: "PiAIAsyncHTTPClient", package: "wuhu-ai"),
      ],
    ),
    .target(
      name: "WuhuCore",
      dependencies: [
        "WuhuCoreClient",
        "WuhuAPI",
        .product(name: "PiAI", package: "wuhu-ai"),
        .product(name: "PiAIAsyncHTTPClient", package: "wuhu-ai"),
        .product(name: "Mux", package: "wuhu-yamux"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
        .product(name: "Tracing", package: "swift-distributed-tracing"),
      ],
    ),
    .target(
      name: "WuhuClient",
      dependencies: [
        "WuhuAPI",
        "WuhuCoreClient",
        .product(name: "PiAIAsyncHTTPClient", package: "wuhu-ai"),
      ],
    ),
    .target(
      name: "WuhuServer",
      dependencies: [
        "WuhuCore",
        .product(name: "PiAI", package: "wuhu-ai"),
        .product(name: "PiAIAsyncHTTPClient", package: "wuhu-ai"),
        .product(name: "Mux", package: "wuhu-yamux"),
        .product(name: "MuxWebSocket", package: "wuhu-yamux"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "WSClient", package: "swift-websocket"),
        .product(name: "Yams", package: "Yams"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "OTel", package: "swift-otel"),
        .product(name: "WorkspaceEngine", package: "wuhu-workspace-engine"),
        .product(name: "WorkspaceScanner", package: "wuhu-workspace-engine"),
      ],
    ),
    .target(
      name: "WuhuRunner",
      dependencies: [
        "WuhuCore",
        .product(name: "Mux", package: "wuhu-yamux"),
        .product(name: "MuxWebSocket", package: "wuhu-yamux"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "Yams", package: "Yams"),
      ],
    ),
    .executableTarget(
      name: "wuhu",
      dependencies: [
        "WuhuClient",
        "WuhuCLIKit",
        "WuhuServer",
        "WuhuRunner",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Yams", package: "Yams"),
      ],
    ),
    .executableTarget(
      name: "WuhuBenchFind",
      dependencies: [
        "WuhuCore",
        .product(name: "PiAI", package: "wuhu-ai"),
      ],
    ),
    .testTarget(
      name: "WuhuCoreTests",
      dependencies: [
        "WuhuCore",
        "WuhuCoreClient",
        .product(name: "Mux", package: "wuhu-yamux"),
        .product(name: "MuxWebSocket", package: "wuhu-yamux"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "WSClient", package: "swift-websocket"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ],
    ),
    .testTarget(
      name: "WuhuClientTests",
      dependencies: [
        "WuhuClient",
      ],
    ),
    .testTarget(
      name: "WuhuServerTests",
      dependencies: [
        "WuhuServer",
      ],
    ),
    .testTarget(
      name: "WuhuCLITests",
      dependencies: [
        "wuhu",
      ],
    ),
    .testTarget(
      name: "WuhuAPITests",
      dependencies: [
        "WuhuAPI",
      ],
    ),
  ],
)
