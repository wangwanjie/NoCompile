<div align="center">

<img src="assets/icon.png" width="160" alt="NoCompile">

# NoCompile

**iOS / macOS 热重载工具，支持 C、C++、Objective-C、Swift**

修改代码，保存，立即在运行中的 App 看到效果，无需等待整个工程重新编译。

**下载：[Apple 芯片（arm64）](https://github.com/wangwanjie/NoCompile/releases/latest/download/NoCompile_arm64.dmg) · [Intel（x86_64）](https://github.com/wangwanjie/NoCompile/releases/latest/download/NoCompile_x86_64.dmg)**

[主页](https://wangwanjie.github.io/NoCompile/) · [所有版本](https://github.com/wangwanjie/NoCompile/releases) · [接入指南](Docs/Integration.md) · [反馈问题](https://github.com/wangwanjie/NoCompile/issues)

</div>

## 主界面

<img src="assets/screenshot.png" alt="NoCompile 控制台与 iOS 模拟器中的示例 App：分别修改 Swift、Objective-C、C 文件并保存，0.3～0.8 秒即在运行中的 App 里生效">

控制台左侧是已连接的 App（模拟器、真机、macOS 各一台设备一个 App）与最近的注入记录（成功 / 失败数、平均耗时；右键可在 Xcode 中打开对应文件，编译失败时直接定位到出错行），右侧是按类别着色、可筛选和搜索的日志。顶栏可切换工程、开关「保存即注入」、手动「检查改动」。菜单栏的 ⚡ 图标提供同样的入口。

---

## 这是什么

大型工程一次编译动辄几分钟，改一行代码也要等很久。NoCompile 只重新编译你刚改动的那一个文件，链接成一个动态库（dylib），注入到正在运行的 App 里，把新实现替换掉旧实现。整个过程通常在 1~3 秒内完成。

它借鉴了 [InjectionIII](https://github.com/johnno1962/InjectionIII)、[HotReloading](https://github.com/johnno1962/HotReloading)、[InjectionNext](https://github.com/johnno1962/InjectionNext) 的核心原理，并针对它们的短板做了改进。

## 相比现有工具的改进

| 维度 | 现有工具的短板 | NoCompile 的做法 |
|---|---|---|
| **获取编译命令** | 纯正则扫描 `.xcactivitylog`，Xcode 升级后格式一变就失效；或改写 Xcode 工具链、依赖 SourceKit 私有日志 | 解析日志拿到模块的 driver 命令后，交给官方 `swiftc -###` 展开出单文件的 frontend 命令。参数由编译器自己生成，Xcode 升级能自动跟随 |
| **语言支持** | 部分工具不支持 C++，Swift 仅支持函数替换 | C / C++ / ObjC / Swift 统一支持。C/C++ 自由函数通过 GOT 重绑覆盖 |
| **进程内替换** | ObjC swizzle、Dobby inline hook、vtable patch 各自为政 | 统一三层：ObjC `class_replaceMethod` + Swift vtable 覆写 + fishhook 式符号重绑 |
| **触发方式** | 部分工具默认要手动按快捷键 | 保存即注入，FSEvents 自动触发；漏检时可点「检查改动」或按全局快捷键 ⌃⌥⌘R 补上 |
| **资源与新文件** | storyboard / xib 仅限模拟器且依赖 Xcode 先编译，不支持图片与新增文件 | storyboard、xib、图片保存即生效（含真机）；运行中新建的源文件也能注入 |
| **中文 / 空格路径** | 明确不支持中文路径，空格路径也会出错 | 全程用参数数组传递给子进程，不拼接 shell 字符串，天然支持 |
| **真机连接** | 靠 UDP 广播找 Mac，常连不上 | 以 USB（usbmuxd）为主通道，稳定可靠 |
| **类型判定** | 注入后 `isKindOfClass:` / `as?` 可能失效 | 登记新旧类等价关系并修正判定 |
| **界面刷新** | 需要在业务类里实现 `injected()` 等与业务无关的方法 | 零侵入：新代码保存即生效，已打开的页面退出重进即可看到（可选开启自动重建），`injected()` 仅作可选兼容 |

## 工作方式

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

- **Mac 端**：NoCompile.app（菜单栏 App，内置命令行工具），从 [Releases](https://github.com/wangwanjie/NoCompile/releases) 下载安装。
- **客户端**（`NoCompileClient`，即本仓库的源码）：以 Debug-only 的库形式链入 App（SPM / CocoaPods / Carthage），或以 bundle 形式在运行时加载，自动连接 Mac 端，收到 dylib 后在进程内完成替换。

## 快速开始

### 1. 安装 NoCompile

按芯片下载对应的 DMG，拖入「应用程序」即可：

| 芯片 | 下载（始终是最新版） |
|---|---|
| Apple 芯片（M 系列） | [NoCompile_arm64.dmg](https://github.com/wangwanjie/NoCompile/releases/latest/download/NoCompile_arm64.dmg) |
| Intel | [NoCompile_x86_64.dmg](https://github.com/wangwanjie/NoCompile/releases/latest/download/NoCompile_x86_64.dmg) |

不确定芯片类型：点击屏幕左上角的苹果菜单 → 关于本机，「芯片」一栏显示 Apple M 系列选 arm64，显示 Intel 选 x86_64。每个 Release 都附带 `SHA256SUMS.txt` 供核对。安装包已经过 Apple 公证，后续版本通过 Sparkle 自动更新，且只会收到同架构的更新；在 Apple 芯片上误装了 Intel 版时，下次更新会自动换成 arm64 版本。

首次运行时，如果工程在「文稿」「桌面」「下载」目录下，macOS 会弹窗询问是否允许 NoCompile 访问，请点「允许」。

### 2. 接入 App 工程

在 App 的 **Debug** 配置里（务必只在 Debug）：

**a. 添加链接参数** — Build Settings → Other Linker Flags（Debug）：

```
-Xlinker -interposable
```

这一步让 App 内部的函数调用走 GOT 间接寻址，才能在运行时把调用重定向到新实现。

**b. 接入客户端**，任选一种：

| 方式 | 写法 | 真机 |
|---|---|---|
| Swift Package Manager | 添加包 `https://github.com/wangwanjie/NoCompile`，把 `NoCompile` 库加到 App target | ✅ |
| CocoaPods | `pod 'NoCompile', :configurations => ['Debug']` | ✅ |
| Carthage | `github "wangwanjie/NoCompile"`，Release 配置用 `EXCLUDED_SOURCE_FILE_NAMES` 排除 | ✅ |
| 拷贝 bundle（零依赖，**推荐**） | Run Script 调用 `nocompile_copy_bundle.sh`，再加载 App 内的 `NoCompile.bundle` | ✅ |
| 从 NoCompile.app 加载 bundle | `Bundle(path: "/Applications/NoCompile.app/Contents/Resources/iOSNoCompile.bundle")?.load()` | ❌ 仅模拟器 / macOS |
| `DYLD_INSERT_LIBRARIES`（零代码） | 在 scheme 环境变量里指向 bundle 内的可执行文件 | ❌ 仅模拟器 / macOS |

> [!IMPORTANT]
> **要在真机上热重载，不能从 `/Applications/NoCompile.app` 加载客户端。** 这个路径只存在于 Mac 上：模拟器进程共享 Mac 的文件系统所以能加载，真机上 `bundleWithPath:` 返回 nil，`load` 静默失败，表现为模拟器正常、真机一直连不上。真机请用前四种方式之一；不想引入依赖就用「拷贝 bundle」，它在模拟器和真机上都能用：
>
> 1. App target 的 Build Phases 末尾加 Run Script：`"/Applications/NoCompile.app/Contents/Resources/nocompile_copy_bundle.sh"`
> 2. 加载 App 内的 bundle：
>
> ```objc
> #if DEBUG
> NSString *path = [[NSBundle mainBundle] pathForResource:@"NoCompile" ofType:@"bundle"];
> if (path) {
>     [[NSBundle bundleWithPath:path] load];
> }
> #endif
> ```
>
> ```swift
> #if DEBUG
> if let path = Bundle.main.path(forResource: "NoCompile", ofType: "bundle") {
>     Bundle(path: path)?.load()
> }
> #endif
> ```

> [!TIP]
> 接入改动不便提交、切换分支后要重新设置时，可以用一键脚本自动完成上面的「拷贝 bundle」接入（链接参数、Run Script、在 `didFinishLaunching` 最前面插入加载代码，自动区分 Swift / Objective-C 与平台），切分支前用 `--remove` 原样撤销：
>
> ```bash
> /Applications/NoCompile.app/Contents/Resources/nocompile_setup.py            # 在工程目录运行
> /Applications/NoCompile.app/Contents/Resources/nocompile_setup.py --remove   # 撤销
> ```
>
> 用 CocoaPods 的工程还可以用 `--install-pod-hook` 在 Podfile 加一个可提交的钩子，本机 `export IntegrateNoCompile=true` 后，`pod install` 会自动接入。详见 [接入指南 · 一键接入](Docs/Integration.md#一键接入脚本本地调试不提交)。

链接方式在镜像加载时自动启动，bundle 方式在 `load()` 时启动，都无需再写启动代码。各方式的完整步骤与注意事项见 [接入指南](Docs/Integration.md)，真机连不上时见 [真机排查](Docs/Integration.md#真机连不上)。

### 3. 选择工程

点击菜单栏的 ⚡ 图标 → 选择工程。

日志可在 ⚡ → 打开控制台 查看，同时写入 `~/Library/Logs/NoCompile/NoCompile.log`。遇到问题时点控制台日志栏的 📦 按钮（或菜单 ⚡ → 导出诊断包…）导出 zip，里面有各环节的诊断日志、编译失败的完整命令与输出、主线程卡顿时自动采集的调用栈，发给开发者即可排查。

然后 `Command+R` 运行你的 App。编辑任意源文件并保存，几秒后就能在 App 看到改动生效。

状态栏图标颜色：跟随菜单栏文字颜色表示就绪，橙色表示正在编译 / 注入，红色表示出错，灰色表示未在监听。

### 验证环境

不接入 App 也能先验证重编流水线是否正常（需先在 Xcode 完整构建过一次）。命令行工具内置在 App 里：

```bash
/Applications/NoCompile.app/Contents/Helpers/nocompile selftest /path/to/YourApp.xcworkspace macosx /path/to/SomeFile.swift
```

第三个参数可以是 `macosx` / `iphonesimulator` / `iphoneos`。

## 使用约束

热重载的主体是替换**函数体**，仅改方法体（不动方法/属性的数量与顺序）即时生效。以下改动会改变类的内存布局，NoCompile 为避免崩溃**不替换该类的实现**，并在日志与 App 浮层里提示重新运行 App：

- 增删、调换顺序或修改类型的存储属性 / ObjC 实例变量（旧实例按旧布局分配，新代码按新偏移读写会越界）；
- 增删或调换顺序的 Swift 方法（旧元数据的 vtable 已固定，按新槽位派发会调用到别的方法）；
- SwiftUI `some View` 返回的视图结构变了（具体类型不同，替换会破坏内存）。在 `body` 末尾加 `.enableInjection()`（或用 `AnyView` 包裹）即可热重载结构改动。

同一文件里布局没变的其他类、自由函数照常生效。

其他要点：

- 必须先在 Xcode 完整构建过一次，NoCompile 才能从构建日志拿到编译命令。
- storyboard、xib、图片与新增源文件也支持热重载，范围与限制见 [接入指南](Docs/Integration.md#资源与新增文件)。
- 支持 iOS / tvOS 15+（Xcode 27 的最低部署目标）、macOS 12+，Mac Catalyst 为实验性支持；真机注入需用与 App 一致的开发者身份签名（NoCompile 会从构建日志自动提取签名身份）。
- 暂不兼容 Whole Module Optimization 和编译缓存（`COMPILATION_CACHE_ENABLE_CACHING`），Debug 配置默认关闭它们即可。

## SwiftUI

SwiftUI 视图的刷新依赖通知。每次注入后，NoCompile 会发出 `NoCompileDidInjectNotification`（同时发出与 Inject / HotSwiftUI 兼容的 `INJECTION_BUNDLE_NOTIFICATION`）。配合社区的 `@ObserveInjection` 即可自动重绘；`body` 末尾的 `.enableInjection()` 把返回类型擦除成 `AnyView`，增删子视图这类结构改动才能热重载。

## 仓库内容

本仓库存放 NoCompile 的客户端 SDK 与发布文件，Mac 端 App 以安装包形式发布在 [Releases](https://github.com/wangwanjie/NoCompile/releases)。

```
Package.swift        Swift Package（只含 NoCompile 客户端库，零第三方依赖）
NoCompile.podspec    CocoaPods 描述文件
Client/              客户端的 Xcode 工程：Carthage 用的 framework
Sources/
  NoCompileClient/   App 进程内客户端（ObjC/C）
Tests/               客户端单元测试（swift test，macOS 上运行）
Docs/                接入指南
Scripts/             真机诊断脚本
appcast*.xml         Sparkle 更新源
release-notes/       各版本发布说明
index.html, assets/  主页
```

每个版本的 tag（`vX.Y.Z`）都指向包含该版本客户端 SDK 的提交，SPM、CocoaPods、Carthage 按 tag 拉取。

## Star 趋势

[![Star History Chart](https://api.star-history.com/svg?repos=wangwanjie/NoCompile&type=Date)](https://star-history.com/#wangwanjie/NoCompile&Date)

## 许可证

客户端 SDK 以 MIT License 开源，详见 [LICENSE](LICENSE)。
