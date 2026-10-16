// swift-tools-version:5.9
import PackageDescription

// NoCompile 客户端 SDK：接入 App 工程的进程内客户端（只在 Debug 生效）。
// Mac 端的 NoCompile.app 与命令行工具请从 Releases 下载安装包。
let package = Package(
    name: "NoCompile",
    platforms: [
        .macOS(.v12),
        .iOS(.v13),
        .tvOS(.v13),
    ],
    products: [
        // 接入 App 工程的客户端（只在 Debug 生效）
        .library(name: "NoCompile", targets: ["NoCompileClient"]),
    ],
    targets: [
        .target(
            name: "NoCompileClient",
            path: "Sources/NoCompileClient",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS])),
            ]
        ),
    ]
)
