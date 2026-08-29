// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FinderTwo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FinderTwo", targets: ["FinderTwo"]),
        .library(name: "RascalFileOperations", targets: ["RascalFileOperations"]),
        .executable(name: "FileOpsCrashProbe", targets: ["FileOpsCrashProbe"])
    ],
    targets: [
        .target(
            name: "RascalFileOperations",
            path: "Sources/RascalFileOperations",
            exclude: ["TestSupport"],
            sources: ["Core", "Interfaces", "Native", "Copy"]
        ),
        // Test support is deliberately not a product and is never linked by FinderTwo.
        .target(
            name: "RascalFileOperationsTestSupport",
            dependencies: ["RascalFileOperations"],
            path: "Sources/RascalFileOperations/TestSupport"
        ),
        .executableTarget(
            name: "FinderTwo",
            dependencies: ["RascalFileOperations"],
            path: "Sources/FinderTwo",
            linkerSettings: [
                // NetFSMountURLSync for SMB / FTP / AFP / WebDAV mounts.
                .linkedFramework("NetFS"),
                // SecCode* APIs for detecting ad-hoc signing (PermissionsManager).
                .linkedFramework("Security")
            ]
        ),
        // M1 only establishes the process boundary. Crash orchestration arrives in M3.
        .executableTarget(
            name: "FileOpsCrashProbe",
            dependencies: ["RascalFileOperations"],
            path: "Sources/FileOpsCrashProbe"
        ),
        .testTarget(
            name: "RascalFileOperationsTests",
            dependencies: ["RascalFileOperations", "RascalFileOperationsTestSupport"],
            path: "Tests/RascalFileOperationsTests"
        ),
        .testTarget(
            name: "RascalFileOperationsIntegrationTests",
            dependencies: ["RascalFileOperations", "RascalFileOperationsTestSupport"],
            path: "Tests/RascalFileOperationsIntegrationTests"
        )
    ]
)
