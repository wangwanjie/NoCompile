//
//  main.swift
//  nocompile 命令行工具：启动引擎，监听工程并热重载。
//
//  用法：
//    nocompile --project <path> [--derived-data <path>] [--no-headers] [--no-resources] [--manual]
//    nocompile <path/to/App.xcworkspace>          # 工程路径也可以直接作为位置参数
//    nocompile selftest <project> <platform> <file> [derivedData] [--arch <arm64|x86_64>]
//    nocompile --version
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

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    /// 输出到终端时按级别着色（重定向到文件时不加颜色控制符）
    private let usesColor = isatty(STDOUT_FILENO) != 0

    func engine(_ engine: Engine, didLog entry: EngineLog) {
        let line = "[\(formatter.string(from: Date()))] \(entry.plainText)"
        guard usesColor else {
            print(line)
            return
        }
        // 成功绿、警告黄、错误红、App 日志青，普通信息不着色
        let color: String
        switch entry.level {
        case 1: color = "\u{1B}[32m"
        case 2: color = "\u{1B}[33m"
        case 3: color = "\u{1B}[31m"
        default: color = entry.category == .app ? "\u{1B}[36m" : ""
        }
        print(color.isEmpty ? line : color + line + "\u{1B}[0m")
    }

    func engine(_ engine: Engine, didUpdateClientCount count: Int) {
        print("🔌 当前已连接 App 数量：\(count)")
    }
}

func parseArguments(_ args: [String]) -> (project: String?, derivedData: String?, headers: Bool, resources: Bool, manual: Bool) {
    var project: String? = nil
    var derivedData: String? = nil
    var headers = true
    var resources = true
    var manual = false
    /// 取选项的值；缺失时报错退出，避免把下一个选项误当成值或静默忽略
    func value(after index: Int) -> String {
        guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else {
            fail("选项 \(args[index]) 缺少参数值")
        }
        return args[index + 1]
    }
    var i = 1
    while i < args.count {
        let argument = args[i]
        switch argument {
        case "--project", "-p":
            project = value(after: i)
            i += 1
        case "--derived-data", "-d":
            derivedData = value(after: i)
            i += 1
        case "--no-headers":
            headers = false
        case "--no-resources":
            resources = false
        case "--manual":
            manual = true
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--version", "-v":
            print("nocompile \(NCProtocol.clientVersion)")
            exit(0)
        default:
            // 直接给出工程路径也可以
            let ext = (argument as NSString).pathExtension
            if !argument.hasPrefix("-"), project == nil, ext == "xcodeproj" || ext == "xcworkspace" {
                project = argument
            } else {
                // 拼错的选项（如 --derived-dat）不能静默忽略，否则用户以为设置生效了
                fail("无法识别的参数：\(argument)（nocompile --help 查看用法）")
            }
        }
        i += 1
    }
    return (project, derivedData, headers, resources, manual)
}

/// 输出错误并以非零状态退出
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("❌ " + message + "\n").utf8))
    exit(1)
}

func printUsage() {
    print("""
    NoCompile —— iOS / macOS 热重载工具

    用法：
      nocompile --project <工程路径> [选项]
      nocompile <工程路径> [选项]
      nocompile selftest <工程路径> <iphonesimulator|iphoneos|macosx> <源文件> [DerivedData] [--arch <arm64|x86_64>]

    选项：
      -p, --project <path>        .xcodeproj / .xcworkspace 路径（必填）
      -d, --derived-data <path>   自定义 DerivedData 路径
          --no-headers            不监听头文件变更
          --no-resources          不热重载 storyboard / xib / 图片资源
          --manual                关闭保存即注入，仅手动触发
      -v, --version               显示版本
      -h, --help                  显示帮助

    接入 App：在 Debug 配置的 Other Linker Flags 添加
      -Xlinker -interposable
    再任选一种方式接入客户端（仅 Debug）：SPM / CocoaPods / Carthage，
    或加载 NoCompile.app 内置的 bundle（Contents/Resources/*NoCompile.bundle）。
    详见 https://github.com/wangwanjie/NoCompile/blob/main/Docs/Integration.md
    """)
}

/// 本机架构（uname machine），模拟器 / macOS App 与之一致
func hostArch() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
        String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return machine.hasPrefix("x86") ? "x86_64" : "arm64"
}

// 自检：nocompile selftest <project> <platform> <file> [derivedData] [--arch <arm64|x86_64>]
// 跑一遍"定位日志 → 解析命令 → 单文件重编 → 链接 → 签名"，用于验证环境
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "selftest" {
    // 先取出 --arch，剩下的按位置参数解析
    var arguments = CommandLine.arguments
    var arch = hostArch()
    if let idx = arguments.firstIndex(of: "--arch"), idx + 1 < arguments.count {
        arch = arguments[idx + 1]
        arguments.removeSubrange(idx...(idx + 1))
    }
    guard arguments.count >= 5 else {
        print("用法：nocompile selftest <project> <platform> <file> [derivedData] [--arch <arm64|x86_64>]")
        exit(1)
    }
    let project = arguments[2]
    let platformName = arguments[3]   // iphonesimulator / macosx / iphoneos
    let file = arguments[4]
    let derivedData = arguments.count >= 6 ? arguments[5] : nil
    guard let buildLog = BuildLog.locate(projectPath: project, customDerivedData: derivedData) else {
        print("❌ 未找到构建日志")
        exit(1)
    }
    print("✅ DerivedData：\(buildLog.derivedDataPath)")
    let parseStart = Date()
    let commands = buildLog.parseAll()
    let identity = commands.signingIdentity
    print("签名身份：\(identity ?? "（无）")，解析用时 \(String(format: "%.2f", Date().timeIntervalSince(parseStart)))s")
    print("✅ 解析：\(commands.swiftModules(for: platformName, arch: arch).count) 个 \(platformName) Swift 模块（架构 \(arch)），\(commands.clangFileCount) 个 C/ObjC/C++ 文件")
    guard let sdk = ProjectInfo.sdkPath(for: platformName) else {
        print("❌ 找不到 \(platformName) SDK")
        exit(1)
    }
    let platform = Platform(name: platformName, sdkPath: sdk, arch: arch,
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
guard FileManager.default.fileExists(atPath: project) else {
    fail("工程不存在：\(project)")
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
engine.watchesResources = parsed.resources
engine.start()

print("NoCompile 正在监听：\(project)")
print("按 Ctrl+C 退出")

// Ctrl+C / kill 时先停止引擎（关闭端口与连接、停止监听），再退出
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        print("\n正在退出…")
        engine.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

// 保持运行
RunLoop.main.run()
