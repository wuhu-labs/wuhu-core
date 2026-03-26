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
    .package(url: "https://github.com/wuhu-labs/wuhu-ai.git", exact: "0.5.1"),
    .package(url: "https://github.com/wuhu-labs/wuhu-fetch.git", exact: "0.2.0"),
    .package(url: "https://github.com/wuhu-labs/wuhu-serve.git", revision: "cab564da8ce634a34c2462efe1bb9df9c6d423c7"),
    .package(url: "https://github.com/wuhu-labs/wuhu-workspace-engine.git", exact: "0.1.3"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    // Keep this aligned with the released wuhu-fetch adapter package.
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.30.3"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.9.0"),
    .package(
      url: "https://github.com/sideeffect-io/AsyncExtensions.git",
      revision: "b97d381f6156e8c34b718bddfb9481f957a07edc",
    ),
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.0"),
    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.2.0"),
    .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
  ],
  targets: [
    .target(
      name: "WuhuAPI",
      dependencies: [
        .product(name: "WuhuAI", package: "wuhu-ai"),
        .product(name: "WorkspaceContracts", package: "wuhu-workspace-engine"),
      ],
    ),
    .target(
      name: "WuhuCLIKit",
      dependencies: [
        .product(name: "WuhuAI", package: "wuhu-ai"),
        "WuhuAPI",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
    ),
    .target(
      name: "WuhuCoreClient",
      dependencies: [
        "WuhuAPI",
        .product(name: "WuhuAI", package: "wuhu-ai"),
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
        .product(name: "FetchAsyncHTTPClient", package: "wuhu-fetch"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
      ],
    ),
    .target(
      name: "WuhuCore",
      dependencies: [
        "WuhuCoreClient",
        "WuhuAPI",
        .product(name: "WuhuAI", package: "wuhu-ai"),
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "AsyncExtensions", package: "AsyncExtensions"),
        .product(name: "Tracing", package: "swift-distributed-tracing"),
      ],
    ),
    .target(
      name: "WuhuClient",
      dependencies: [
        "WuhuAPI",
        "WuhuCoreClient",
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
      ],
    ),
    .target(
      name: "WuhuServer",
      dependencies: [
        "WuhuCore",
        .product(name: "WuhuAI", package: "wuhu-ai"),
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "Hummingbird", package: "hummingbird"),
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
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "Serve", package: "wuhu-serve"),
        .product(name: "ServeNIO", package: "wuhu-serve"),
        .product(name: "ServeRouting", package: "wuhu-serve"),
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
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
        .product(name: "Yams", package: "Yams"),
      ],
    ),
    .executableTarget(
      name: "WuhuBenchFind",
      dependencies: [
        "WuhuCore",
        .product(name: "WuhuAI", package: "wuhu-ai"),
      ],
    ),
    .testTarget(
      name: "WuhuCoreTests",
      dependencies: [
        "WuhuCore",
        "WuhuCoreClient",
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ],
    ),
    .testTarget(
      name: "WuhuClientTests",
      dependencies: [
        "WuhuClient",
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
      ],
    ),
    .testTarget(
      name: "WuhuServerTests",
      dependencies: [
        "WuhuServer",
      ],
    ),
    .testTarget(
      name: "WuhuRunnerTests",
      dependencies: [
        "WuhuRunner",
        "WuhuCore",
        .product(name: "FetchAsyncHTTPClient", package: "wuhu-fetch"),
        .product(name: "ServeTesting", package: "wuhu-serve"),
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
