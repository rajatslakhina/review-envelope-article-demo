// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReviewEnvelope",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReviewEnvelope", targets: ["ReviewEnvelope"]),
    ],
    targets: [
        .target(name: "ReviewEnvelope"),
        .testTarget(name: "ReviewEnvelopeTests", dependencies: ["ReviewEnvelope"]),
    ]
)
