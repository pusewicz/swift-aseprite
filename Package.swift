// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
  .treatAllWarnings(as: .error),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "Aseprite",
  // Swift Testing is built for macOS 14; below that every test link warns.
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "Aseprite", targets: ["Aseprite"])
  ],
  targets: [
    .target(name: "Aseprite", swiftSettings: strict),
    .testTarget(
      name: "AsepriteTests",
      dependencies: ["Aseprite"],
      exclude: ["Fixtures"],
      swiftSettings: strict
    ),
  ],
  swiftLanguageModes: [.v6]
)
