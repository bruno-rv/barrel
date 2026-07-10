// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BarrelMac",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "BarrelMac", targets: ["BarrelMac"])
  ],
  targets: [
    .executableTarget(
      name: "BarrelMac",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    )
  ]
)
