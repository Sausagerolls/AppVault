// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AppVault",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AppVaultCore"),
        .executableTarget(name: "AppVault", dependencies: ["AppVaultCore"]),
        // Developer check: round-trips a folder through TarPlan and /usr/bin/tar.
        .executableTarget(name: "tartest", dependencies: ["AppVaultCore"]),
    ]
)
