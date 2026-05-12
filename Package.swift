// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FinderTwo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FinderTwo", targets: ["FinderTwo"])
    ],
    targets: [
        .executableTarget(
            name: "FinderTwo",
            path: "Sources/FinderTwo"
        )
    ]
)
