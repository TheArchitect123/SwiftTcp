// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "SwiftTcp",
    products: [
        .library(
            name: "SwiftTcp",
            targets: ["SwiftTcp"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftTcp",
            dependencies: []
        )
    ]
)
