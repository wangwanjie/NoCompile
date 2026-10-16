//
//  main.swift
//  nocompile 命令行工具：启动引擎，监听工程并热重载。
//
//  用法：
//    nocompile --project <path> [--derived-data <path>] [--no-headers] [--manual]
//    nocompile <file.swift> ...   # 在运行中的实例外，一次性重编指定文件（配合 --project）
//

import Foundation
import NoCompileKit

// 关闭 stdout 缓冲，便于实时查看日志
setvbuf(stdout, nil, _IONBF, 0)

final class CLIDelegate: EngineDelegate {
    func engine(_ engine: Engine, didChangeState state: EngineState) {
        switch state {
        case .idle:
            break
        case .working:
            break
        case .error(let message):
            FileHandle.standardError.write(Data(("⚠️  " + message + "\n").utf8))
        }
    }

    func engine(_ engine: Engine, didLog message: String, level: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        print("[\(formatter.string(from: Date()))] \(message)")
    }

    func engine(_ engine: Engine, didUpdateClientCount count: Int) {
        print("🔌 当前已连接 App 数量：\(count)")
    }
}

func parseArguments(_ args: [String]) -> (project: String?, derivedData: String?, headers: Bool, manual: Bool) {
    var project: String? = nil
    var derivedData: String? = nil
    var headers = true
    var manual = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--project", "-p":
            i += 1
            if i < args.count { project = args[i] }
        case "--derived-data", "-d":
            i += 1
            if i < args.count { derivedData = args[i] }
        case "--no-headers":
            headers = false
        case "--manual":
            manual = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            break
        }
        i += 1
    }
    return (project, derivedData, headers, manual)
}

func printUsage() {
    print("""
    NoCompile —— iOS / macOS 热重载工具

    用法：
      nocompile --project <工程路径> [选项]

    选项：
      -p, --project <path>        .xcodeproj / .xcworkspace 路径（必填）
      -d, --derived-data <path>   自定义 DerivedData 路径
          --no-headers            不监听头文件变更
          --manual                关闭保存即注入，仅手动触发
      -h, --help                  显示帮助

    接入 App：在 Debug 配置的 Other Linker Flags 添加
      -Xlinker -interposable
    再任选一种方式接入客户端（仅 Debug）：SPM / CocoaPods / Carthage，
    或加载 NoCompile.app 内置的 bundle（Contents/Resources/*NoCompile.bundle）。
    详见 https://github.com/wangwanjie/NoCompile/blob/main/Docs/Integration.md
    """)
}

// 自检：nocompile selftest <project> <platform> <file> [derivedData]
// 跑一遍"定位日志 → 解析命令 → 单文件重编 → 链接 → 签名"，用于验证环境
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "selftest" {
    let project = CommandLine.arguments[2]
    let platformName = CommandLine.arguments[3]   // iphonesimulator / macosx / iphoneos
    let file = CommandLine.arguments[4]
    let derivedData = CommandLine.arguments.count >= 6 ? CommandLine.arguments[5] : nil
    guard let buildLog = BuildLog.locate(projectPath: project, customDerivedData: derivedData) else {
        print("❌ 未找到构建日志")
        exit(1)
    }
    print("✅ DerivedData：\(buildLog.derivedDataPath)")
    let text = buildLog.extractPlainText()
    let identity = ProjectInfo.signingIdentity(fromPlainText: text)
    print("签名身份：\(identity ?? "（无）")")
    let commands = BuildLog.parse(plainText: text)
    print("✅ 解析：\(commands.swiftModules(for: platformName).count) 条 \(platformName) Swift 模块命令，\(commands.clangFileCount) 个 C/ObjC/C++ 文件")
    guard let sdk = ProjectInfo.sdkPath(for: platformName) else {
        print("❌ 找不到 \(platformName) SDK")
        exit(1)
    }
    let platform = Platform(name: platformName, sdkPath: sdk, arch: "arm64",
                            isSimulator: platformName == "iphonesimulator",
                            isDevice: platformName == "iphoneos")
    let recompiler = Recompiler(outputDirectory: NSTemporaryDirectory() + "NoCompileSelfTest")
    print("⏳ 重编：\(file)")
    let start = Date()
    let result = recompiler.recompile(sourceFile: file, commands: commands, platform: platform, codesignIdentity: identity)
    let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
    if let dylib = result.dylibPath {
        let size = ((try? FileManager.default.attributesOfItem(atPath: dylib))?[.size] as? Int) ?? 0
        print("✅ 成功，用时 \(elapsed)s → \(dylib)（\(size) 字节）")
    } else {
        print("❌ 失败：\(result.error ?? "")")
        print(result.log)
        exit(1)
    }
    exit(0)
}

let parsed = parseArguments(CommandLine.arguments)
guard let project = parsed.project else {
    printUsage()
    exit(1)
}

// 统一用绝对路径，确保 FSEvents 监听正确
func absolutePath(_ path: String) -> String {
    if (path as NSString).isAbsolutePath {
        return (path as NSString).standardizingPath
    }
    return (FileManager.default.currentDirectoryPath + "/" + path as NSString).standardizingPath
}

let delegate = CLIDelegate()
let engine = Engine(projectPath: absolutePath(project),
                    customDerivedData: parsed.derivedData.map(absolutePath))
engine.delegate = delegate
engine.injectsOnSave = !parsed.manual
engine.watchesHeaders = parsed.headers
engine.start()

print("NoCompile 正在监听：\(project)")
print("按 Ctrl+C 退出")

// 保持运行
RunLoop.main.run()
