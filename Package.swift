// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "zmd-mac",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "zmd-dev", targets: ["Development"])],
  targets: [.executableTarget(name: "Development", path: "Sources/Development")]
)
