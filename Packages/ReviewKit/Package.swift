// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReviewKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "ReviewCore", targets: ["ReviewCore"]),
        .library(name: "Sync", targets: ["Sync"]),
        .library(name: "Workspace", targets: ["Workspace"]),
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    targets: [
        .target(name: "GitHubKit"),
        .target(name: "Persistence"),
        .target(name: "ReviewCore", dependencies: ["GitHubKit"]),
        .target(name: "Sync", dependencies: ["GitHubKit", "ReviewCore", "Persistence"]),
        .target(name: "Workspace", dependencies: ["ReviewCore"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "ReviewCoreTests", dependencies: ["ReviewCore"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync"]),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace"]),
    ]
)
