// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaDockMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "QuotaDock",
            targets: ["QuotaDockMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "QuotaDockMac",
            path: "Sources/QuotaDockMac"
        )
    ]
)
