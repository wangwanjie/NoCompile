<div align="center">

# ⚡ NoCompile

**iOS / macOS 热重载工具，支持 C、C++、Objective-C、Swift**

修改代码，保存，立即在运行中的 App 看到效果，无需等待整个工程重新编译。

</div>

---

## 这是什么

大型工程一次编译动辄几分钟，改一行代码也要等很久。NoCompile 的做法是：只重新编译你刚改动的那一个文件，链接成一个动态库（dylib），注入到正在运行的 App 里，把新实现替换掉旧实现。整个过程通常在 1~3 秒内完成。

它借鉴了 [InjectionIII](https://github.com/johnno1962/InjectionIII)、[HotReloading](https://github.com/johnno1962/HotReloading)、[InjectionNext](https://github.com/johnno1962/InjectionNext) 的核心原理，并针对它们的短板做了改进。

## 相比现有工具的改进

| 维度 | 现有工具的短板 | NoCompile 的做法 |
|---|---|---|
| **获取编译命令** | 纯正则扫描 `.xcactivitylog`，Xcode 升级后格式一变就失效；或改写 Xcode 工具链、依赖 SourceKit 私有日志 | 解析日志拿到模块的 driver 命令后，交给官方 `swiftc -###` 展开出单文件的 frontend 命令。参数由编译器自己生成，Xcode 升级能自动跟随 |
| **语言支持** | 内部工具不支持 C++，Swift 仅支持函数替换 | C / C++ / ObjC / Swift 统一支持。C/C++ 自由函数通过 GOT 重绑覆盖 |
| **进程内替换** | ObjC swizzle、Dobby inline hook、vtable patch 各自为政 | 统一三层：ObjC `class_replaceMethod` + Swift vtable 覆写 + fishhook 式符号重绑 |
| **触发方式** | 部分工具默认要手动按快捷键 | 保存即注入，FSEvents 自动触发 |
| **中文 / 空格路径** | 明确不支持中文路径，空格路径也会出错 | 全程用参数数组传递给子进程，不拼接 shell 字符串，天然支持 |
| **真机连接** | 靠 UDP 广播找 Mac，常连不上 | 以 USB（usbmuxd）为主通道，稳定可靠 |
| **类型判定** | 注入后 `isKindOfClass:` / `as?` 可能失效 | 登记新旧类等价关系并修正判定 |
| **界面刷新** | 需要在业务类里实现 `injected()` 等与业务无关的方法 | 零侵入：自动重建受影响的可见页面，`injected()` 仅作可选兼容 |

## 架构

```
┌─────────────────────┐         socket          ┌──────────────────────┐
│   Mac 端（引擎）     │ ◄──── 模拟器/macOS ────► │   App 进程内客户端    │
│                     │      TCP 21890           │   (NoCompile.framework)│
│  · 监听文件变化      │                          │                       │
│  · 解析构建日志      │ ◄──── 真机 USB ────────► │  · dlopen 新 dylib    │
│  · 单文件重编 → dylib│   usbmuxd → 21891        │  · ObjC 方法替换       │
│  · 签名 → 推送       │                          │  · Swift vtable 覆写   │
│                     │                          │  · 符号 GOT 重绑       │
│  CLI / 菜单栏 App    │                          │  · 遍历实例 injected() │
└─────────────────────┘                          └──────────────────────┘
```

- **Mac 端引擎**（`NoCompileKit`）：定位 DerivedData、解析 `.xcactivitylog`、单文件重编、链接、签名、通过 socket 推送。被命令行工具 `nocompile` 和菜单栏 App `NoCompileApp` 共用。
- **客户端**（`NoCompileClient`）：以 Debug-only 的库形式链入 App，自动连接 Mac 端，收到 dylib 后在进程内完成替换。

详见 [Docs/Architecture.md](Docs/Architecture.md)。

## 快速开始

### 1. 构建并启动 NoCompile

```bash
Scripts/build-app.sh --open
```

脚本用 SwiftPM 命令行打包出 `build/NoCompile.app`（菜单栏 App，内含命令行工具 `Contents/Helpers/nocompile`），全程不经过 Xcode。加 `--install` 会安装到 `/Applications`。

> 不要在 Xcode 里打开 NoCompile 的 `Package.swift` 来运行它。Xcode 不允许同一个本地包同时被两个窗口打开，而你的 App 工程以本地包方式引用 NoCompile 时会和它冲突。

首次运行时，如果工程在「文稿」「桌面」「下载」目录下，macOS 会弹窗询问是否允许 NoCompile 访问，请点「允许」。脚本会优先用钥匙串里的 Apple Development 证书签名，授权一次后重新打包也不会再问。

### 2. 接入 App 工程

在 App 的 **Debug** 配置里（务必只在 Debug）：

**a. 添加链接参数** — Build Settings → Other Linker Flags（Debug）：

```
-Xlinker -interposable
```

这一步让 App 内部的函数调用走 GOT 间接寻址，才能在运行时把调用重定向到新实现。

**b. 通过 SPM 依赖客户端库**，并确保只在 Debug 链接。例如在你的调试入口：

```swift
import NoCompile   // 仅在 Debug target 可用
```

客户端会在镜像加载时自动启动，无需写任何调用代码。

### 3. 选择工程

点击菜单栏的 ⚡ 图标 → 选择工程，或者启动时直接指定：

```bash
Scripts/build-app.sh --open --project /path/to/YourApp.xcworkspace
```

日志可在 ⚡ → 显示日志 查看，同时写入 `~/Library/Logs/NoCompile/NoCompile.log`。

然后 `Command+R` 运行你的 App。编辑任意源文件并保存，几秒后就能在 App 看到改动生效。

状态栏图标颜色：绿色表示就绪，黄色表示执行中，红色表示出错。

### 验证环境

不接入 App 也能先验证重编流水线是否正常（需先在 Xcode 完整构建过一次）：

```bash
nocompile selftest /path/to/YourApp.xcworkspace macosx /path/to/SomeFile.swift
```

第三个参数可以是 `macosx` / `iphonesimulator` / `iphoneos`。

## 使用约束

热重载替换的是**函数体**。以下改动需要重新运行 App 才能生效：

- 增删存储属性（改变了对象内存布局）
- 给非 final 类增删或重排方法（改变了 vtable 布局）
- 修改类型的内存大小

NoCompile 会检测到布局变化并拒绝注入，以避免崩溃，而不是让 App 崩掉。

其他要点：

- 必须先在 Xcode 完整构建过一次，NoCompile 才能从构建日志拿到编译命令。
- 真机注入需要 iOS 13+，并用与 App 一致的开发者身份签名（NoCompile 会从构建日志自动提取签名身份）。
- 暂不兼容 Whole Module Optimization 和编译缓存（`COMPILATION_CACHE_ENABLE_CACHING`），Debug 配置默认关闭它们即可。

## SwiftUI

SwiftUI 视图的刷新依赖通知。每次注入后，NoCompile 会发出 `NoCompileDidInjectNotification`（同时发出与 Inject / HotSwiftUI 兼容的 `INJECTION_BUNDLE_NOTIFICATION`）。配合社区的 `@ObserveInjection` 即可自动重绘。

## 目录结构

```
Sources/
  NoCompileClient/   App 进程内客户端（ObjC/C）
  NoCompileKit/      Mac 端引擎（Swift）
  nocompile/         命令行工具
  NoCompileApp/      菜单栏 App
Docs/
  Architecture.md    架构与原理
  Integration.md     详细接入指南
```

## 许可证

MIT License，详见 [LICENSE](LICENSE)。
