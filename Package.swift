// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BarrelMac",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "BarrelCore", targets: ["BarrelCore"]),
    .executable(name: "BarrelMac", targets: ["BarrelMac"])
  ],
  targets: [
    .target(
      name: "BarrelCore",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "BarrelMac",
      dependencies: ["BarrelCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "BarrelCoreTests",
      dependencies: ["BarrelCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "BarrelMacTests",
      dependencies: ["BarrelMac"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
