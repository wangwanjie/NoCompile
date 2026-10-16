// swift-tools-version:5.9
import PackageDescription

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
        // Mac 端引擎，供 CLI 与菜单栏 App 复用
        .library(name: "NoCompileKit", targets: ["NoCompileKit"]),
        // 命令行工具（Mac App 见 App/project.yml，单独集成 Sparkle，避免接入方解析多余依赖）
        .executable(name: "nocompile", targets: ["nocompile"]),
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
        .target(
            name: "NoCompileKit",
            path: "Sources/NoCompileKit"
        ),
        .executableTarget(
            name: "nocompile",
            dependencies: ["NoCompileKit"],
            path: "Sources/nocompile"
        ),
    ]
)
