// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExNetwork",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ExNetwork", targets: ["ExNetwork"]),
    ],
    targets: [
        // 本地 SPM 包静态链入 App，App 的 -interposable 链接参数对它同样生效
        .target(name: "ExNetwork"),
    ]
)
