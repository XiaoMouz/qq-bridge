// swift-tools-version: 6.1
// QQBridgeKit：iOS 客户端里与界面无关的部分（docs/design.md 6.2）——协议、网络、同步引擎、本地库、媒体缓存。
// 不依赖 UIKit / SwiftUI，可以直接在 Mac 上 `swift test`；App 和各扩展（通知、分享）共用。
import PackageDescription

let package = Package(
  name: "QQBridgeKit",
  platforms: [.iOS("18.0"), .macOS("15.0")],
  products: [
    .library(name: "QQBridgeKit", targets: ["QQBridgeKit"]),
    .library(name: "QQBridgeProto", targets: ["QQBridgeProto"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.2.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
  ],
  targets: [
    // 由 packages/protocol 的 buf 生成（pnpm --filter @qqbridge/protocol generate:swift），不要手改。
    .target(
      name: "QQBridgeProto",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "Connect", package: "connect-swift"),
      ]
    ),
    .target(
      name: "QQBridgeKit",
      dependencies: [
        "QQBridgeProto",
        .product(name: "Connect", package: "connect-swift"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(name: "QQBridgeKitTests", dependencies: ["QQBridgeKit"]),
    // 命令行验收工具：swift run qqbridge-check（只在 Mac 上用）。
    .executableTarget(name: "qqbridge-check", dependencies: ["QQBridgeKit", "QQBridgeProto"]),
  ],
  swiftLanguageModes: [.v6]
)
