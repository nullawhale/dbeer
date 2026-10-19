// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DBeer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DBeer", targets: ["DBeer"])],
    targets: [
        .executableTarget(name: "DBeer", resources: [
            .copy("Resources/postgresql-logo.svg"),
            .copy("Resources/mysql-logo.svg"),
            .copy("Resources/EditorThemes"),
        ]),
        .testTarget(name: "DBeerTests", dependencies: ["DBeer"]),
    ]
)
