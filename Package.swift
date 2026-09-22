// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "LocalProxy",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "LocalProxyCore", targets: ["LocalProxyCore"]),
        .library(name: "ProxyAppsCore", targets: ["ProxyAppsCore"]),
        .executable(name: "localproxy", targets: ["LocalProxyCLI"]),
        .executable(name: "LocalProxyApp", targets: ["LocalProxyApp"]),
    ],
    targets: [
        .target(name: "LocalProxyCore", exclude: ["ProxyAppsModels.swift"]),
        .target(name: "ProxyAppsCore", resources: [.process("Resources")]),
        .executableTarget(
            name: "LocalProxyCLI",
            dependencies: ["LocalProxyCore"]
        ),
        .executableTarget(
            name: "LocalProxyApp",
            dependencies: ["ProxyAppsCore"],
            exclude: [
                "ContentView.swift",
                "ProxyController.swift",
                "ProxyManager.swift",
                "RulesView.swift",
            ],
            sources: [
                "ApplicationDelegate.swift",
                "LocalProxyApp.swift",
                "ProxyAppsContentView.swift",
                "ProxyAppsController.swift",
                "ProxyAppsManager.swift",
                "PACServer.swift",
                "SystemPACManager.swift",
            ]
        ),
        .testTarget(
            name: "LocalProxyCoreTests",
            dependencies: ["LocalProxyCore", "ProxyAppsCore", "LocalProxyApp"]
        ),
    ]
)
