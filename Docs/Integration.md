# 接入指南

## 前置条件

- Xcode 15 及以上（已在 Xcode 27 验证）。
- 先在 Xcode 对目标工程完整构建过一次（NoCompile 需要从构建日志获取编译命令）。
- Debug 配置下关闭 Whole Module Optimization（Debug 默认就是关闭的）。

## 第一步：添加链接参数

在 App target 的 **Build Settings → Other Linker Flags**，给 **Debug** 配置添加：

```
-Xlinker -interposable
```

可以直接在 Build Settings 里按配置展开，只给 Debug 行填写。切勿加到 Release，`-interposable` 会影响优化，且上架构建不应包含它。

> 无论用下面哪种方式接入客户端，这一步都需要。CocoaPods 方式会自动加上。本地 SPM 包里的代码若也要支持热重载，同样需要给对应 target 的 Debug 配置加这个参数。

## 第二步：接入客户端（任选一种，仅 Debug）

| 方式 | 改动 | 真机 | 适合场景 |
|---|---|---|---|
| [A. Swift Package Manager](#方式-aswift-package-manager) | 加包依赖 | ✅ | 新工程、纯 SPM 工程 |
| [B. CocoaPods](#方式-bcocoapods) | Podfile 一行 | ✅ | 已用 CocoaPods 的工程 |
| [C. Carthage](#方式-ccarthage) | Cartfile + 一项排除设置 | ✅ | 已用 Carthage 的工程 |
| [D. 运行时加载 bundle](#方式-d运行时加载-bundle零依赖) | 一行加载代码 | 模拟器 / macOS | 不想动依赖管理，InjectionIII 用户 |
| [E. 拷贝 bundle 进 App](#方式-e拷贝-bundle-进-app零依赖支持真机) | Run Script + 一行加载代码 | ✅ | 零依赖且要支持真机 |
| [F. DYLD_INSERT_LIBRARIES](#方式-fdyld_insert_libraries零代码) | 只改 scheme 环境变量 | 模拟器 / macOS | 完全不改工程与代码 |
| [G. 手动链接](#方式-g手动链接) | 子工程 | ✅ | 想自己掌控构建 |

A/B/C/G 在镜像加载时自动启动；D/E 在 `load()` 时启动；F 在进程启动时启动，都不需要再调用 `NoCompile.start()`。同一进程里误接了多份客户端时，只有第一份生效，控制台会打印 `检测到重复加载的客户端`；此时 ObjC 运行时也会报 `Class NCxxx is implemented in both` 警告，去掉多余的那份即可。

### 方式 A：Swift Package Manager

1. File → Add Package Dependencies，填入 `https://github.com/wangwanjie/NoCompile`。
2. 把 `NoCompile` 库加到 App target。
3. Debug 的 Other Linker Flags 里加 `-ObjC`（或任意引用一次客户端），确保客户端的类被完整链接。
4. 客户端代码整体包在 `#if DEBUG` 里，Release 构建为空壳；仍建议在依赖层面隔离。

SPM 的模块名为 `NoCompileClient`，需要调用 API 时 `import NoCompileClient`。

### 方式 B：CocoaPods

```ruby
pod 'NoCompile', :configurations => ['Debug']
```

尚未发布到 Trunk 时可直接指向仓库：

```ruby
pod 'NoCompile', :git => 'https://github.com/wangwanjie/NoCompile.git', :branch => 'main', :configurations => ['Debug']
```

- Pod 会自动给引入它的配置加上 `-Xlinker -interposable`，第一步可以省略。
- 客户端由 `DEBUG` 宏控制，CocoaPods 会给 debug 类配置的 Pod target 定义 `DEBUG=1`。自定义配置名（如 `Dev`）需要在 Podfile 里声明为 debug 类型：`project 'App', 'Dev' => :debug`，并加入 `:configurations`。
- 静态库与 `use_frameworks!` 都支持。模块名为 `NoCompile`。
- Pod 的最低系统版本为 iOS / tvOS 15、macOS 12（Xcode 27 不再支持更低的部署目标）。

### 方式 C：Carthage

```
# Cartfile
github "wangwanjie/NoCompile"
```

```bash
carthage update NoCompile --use-xcframeworks
```

Carthage 默认以 Release 配置构建，因此 NoCompile 的 Carthage 产物不依赖 `DEBUG` 宏、始终包含客户端代码，需要在工程里把它限制在 Debug：

1. 把 `Carthage/Build/NoCompile.xcframework` 拖到 App target 的 Frameworks, Libraries, and Embedded Content，选 **Embed & Sign**。
2. Build Settings 里，给 **Release**（以及其他非调试配置）设置 Excluded Source File Names：

   ```
   EXCLUDED_SOURCE_FILE_NAMES = NoCompile.xcframework NoCompile.framework
   ```

   这样 Release 构建既不链接也不嵌入 NoCompile。
3. 按第一步给 Debug 加 `-Xlinker -interposable`。

模块名为 `NoCompile`。动态 framework 加载即自动启动，不需要 `-ObjC`。

### 方式 D：运行时加载 bundle（零依赖）

与 InjectionIII 的 `iOSInjection.bundle` 用法一致。NoCompile.app 内置了各平台的客户端 bundle：

| bundle | 平台 |
|---|---|
| `macOSNoCompile.bundle` | macOS |
| `iOSNoCompile.bundle` | iOS 模拟器 |
| `tvOSNoCompile.bundle` | tvOS 模拟器 |
| `iOSDeviceNoCompile.bundle` / `tvOSDeviceNoCompile.bundle` | 真机，见方式 E |

在 App 启动尽早的位置（例如 `application(_:didFinishLaunchingWithOptions:)`）加载：

```swift
#if DEBUG
#if os(macOS)
Bundle(path: "/Applications/NoCompile.app/Contents/Resources/macOSNoCompile.bundle")?.load()
#elseif os(tvOS)
Bundle(path: "/Applications/NoCompile.app/Contents/Resources/tvOSNoCompile.bundle")?.load()
#elseif targetEnvironment(simulator)
Bundle(path: "/Applications/NoCompile.app/Contents/Resources/iOSNoCompile.bundle")?.load()
#endif
#endif
```

Objective-C：

```objc
#if DEBUG
[[NSBundle bundleWithPath:@"/Applications/NoCompile.app/Contents/Resources/iOSNoCompile.bundle"] load];
#endif
```

- NoCompile.app 不在 `/Applications` 时改成实际路径。从源码构建的 App 在 `build/DerivedData/Build/Products/Release/NoCompile.app`，也可以直接用 `Scripts/build-client-bundles.sh` 单独构建出 `build/ClientBundles/`。
- macOS App 若开启了 Hardened Runtime，需在 Debug 的 entitlements 里加 `com.apple.security.cs.disable-library-validation`，否则系统会拒绝加载其他团队签名的 bundle；或者改用方式 E，由脚本用 App 自己的身份重签。
- 模拟器进程能直接访问 Mac 的文件系统，所以可以从 NoCompile.app 里加载；真机做不到，请用方式 E。

### 方式 E：拷贝 bundle 进 App（零依赖，支持真机）

1. 在 App target 的 Build Phases 末尾加一个 Run Script：

   ```bash
   "/Applications/NoCompile.app/Contents/Resources/nocompile_copy_bundle.sh"
   ```

   脚本按当前平台挑出对应的 bundle，拷到 App 资源目录并命名为 `NoCompile.bundle`，再用 App 的签名身份重签。默认只在名字含 `Debug` 的配置生效。若 target 开启了 `ENABLE_USER_SCRIPT_SANDBOXING`，需要关闭，否则脚本读不到 NoCompile.app。

2. 加载代码各平台相同：

   ```swift
   #if DEBUG
   if let path = Bundle.main.path(forResource: "NoCompile", ofType: "bundle") {
       Bundle(path: path)?.load()
   }
   #endif
   ```

脚本支持的环境变量：

| 变量 | 作用 |
|---|---|
| `NOCOMPILE_BUNDLES_DIR` | bundle 所在目录，默认为脚本所在目录 |
| `NOCOMPILE_COPY_CONFIGURATIONS` | 允许拷贝的配置名，逗号分隔，例如 `Debug,Dev` |
| `NOCOMPILE_DISABLE_COPY=1` | 临时关闭拷贝 |

### 方式 F：DYLD_INSERT_LIBRARIES（零代码）

bundle 的可执行文件是动态库，可以在 scheme 里直接注入，工程和代码都不用改。Edit Scheme → Run → Arguments → Environment Variables 添加：

| 平台 | `DYLD_INSERT_LIBRARIES` |
|---|---|
| iOS 模拟器 | `/Applications/NoCompile.app/Contents/Resources/iOSNoCompile.bundle/iOSNoCompile` |
| tvOS 模拟器 | `/Applications/NoCompile.app/Contents/Resources/tvOSNoCompile.bundle/tvOSNoCompile` |
| macOS | `/Applications/NoCompile.app/Contents/Resources/macOSNoCompile.bundle/Contents/MacOS/macOSNoCompile` |

macOS App 开启 Hardened Runtime 时，系统会忽略 `DYLD_*` 环境变量，需要在 Debug 的 entitlements 里加 `com.apple.security.cs.allow-dyld-environment-variables` 与 `com.apple.security.cs.disable-library-validation`。

### 方式 G：手动链接

把 `Client/NoCompileClient.xcodeproj` 拖进工程作为子工程，链接对应平台的 `NoCompile` framework，Release 配置同样用 `EXCLUDED_SOURCE_FILE_NAMES` 排除（参考方式 C）。该工程的 framework 与 bundle 都定义了 `NOCOMPILE_FORCE_ENABLE=1`，不依赖 `DEBUG` 宏。

---

SwiftUI Preview 和单元测试环境下客户端会自动跳过（需要在单测里启用时设置环境变量 `NOCOMPILE_ENABLE_IN_TESTS=1`）。

## 第三步：运行

### 启动 Mac 端

命令行：

```bash
nocompile --project /path/to/YourApp.xcworkspace
```

常用选项：

| 选项 | 说明 |
|---|---|
| `-p, --project` | `.xcodeproj` 或 `.xcworkspace` 路径 |
| `-d, --derived-data` | 自定义 DerivedData 路径（与 Xcode 设置一致时） |
| `--no-headers` | 不监听头文件变更 |
| `--manual` | 关闭保存即注入，仅手动触发 |

或运行菜单栏 App，点 ⚡ → 选择工程。

### 运行 App

`Command+R` 运行。编辑源文件并保存，Mac 端会重编并推送，App 内的 ⚡ 浮层会提示注入结果。

## 真机

1. 用数据线连接设备（USB 为主通道，走 usbmuxd）。
2. 真机注入需要 iOS 13+。
3. dylib 要用与 App 一致的开发者身份签名。NoCompile 会从构建日志自动提取签名身份，所以需要先在 Xcode 成功跑过一次真机构建。
4. 若要走 Wi-Fi，设置环境变量 `NOCOMPILE_HOST=<Mac 的 IP>` 后再运行 App。

## 界面如何刷新（零侵入）

业务代码不需要为热重载写任何代码。每次注入完成后，NoCompile 会自动：

1. 找到当前可见、且受本次改动影响的视图控制器。判断依据有两种：控制器自身的类被替换了，或它的视图层级里有被替换的视图类。
2. 清空这些控制器的视图，再依次调用 `viewDidLoad`、`viewWillAppear`、`viewDidAppear`，界面按新代码重新构建。重写了 `loadView` 的控制器会重新执行 `loadView`。
3. 如果改的是模型、工具类、C/C++ 函数这类非界面代码，就刷新最上层的可见业务页面，让新逻辑立即体现出来。

UIKit 和 AppKit 都支持。若想关闭自动刷新，可在调试代码里设置 `NoCompile.autoReloadViewControllers = NO`。

**兼容 InjectionIII 的 `injected()`（可选）**：如果某个类已经实现了 `-injected` / `+injected`，NoCompile 会调用它，替代默认的重建流程。从 InjectionIII 迁移过来的项目可以直接沿用。新项目不需要写。

## 资源与新增文件

除了源码，以下改动保存后也会热重载，无需额外接入（可在偏好设置的「热重载界面与图片资源」或命令行 `--no-resources` 关闭）：

- **storyboard / xib**：Mac 端用 ibtool 重新编译后下发，当前可见、由它加载的页面会按新 nib 重建；之后打开的页面也会使用新版本。
- **图片**：替换 Asset Catalog 图片集里的位图或工程中的图片文件后，`UIImage(named:)` / `NSImage(named:)` 和 nib 中引用的图片都会返回新图，当前页面会刷新。
- **新增源文件**：运行中新建的 Swift / ObjC / C / C++ 文件保存后会被编译注入，之后修改的已有文件可以直接使用其中的新类型和函数。

限制：

- 只覆盖主 bundle 中的资源；framework、资源 bundle 中的资源需要重新运行。
- App 图标、颜色集、矢量（PDF / SVG）图片、暗色等外观变体、`Localizable.strings` 不在热重载范围内。
- SwiftUI 的 `Image("name")` 不经过 `imageNamed:`，不会拿到新图。
- 新增的 ObjC 类要被 Swift 使用，需要修改桥接头并重新构建。

## SwiftUI 刷新

给需要热重载的视图加上社区的 `@ObserveInjection`（来自 Inject / HotSwiftUI 包）：

```swift
import SwiftUI
import Inject

struct ContentView: View {
    @ObserveInjection var inject
    var body: some View {
        Text("Hello")
            .enableInjection()
    }
}
```

NoCompile 注入后会发出 `INJECTION_BUNDLE_NOTIFICATION`，与这些包兼容，视图会自动重绘。

> SwiftUI 目前还做不到完全零侵入：`body` 的新实现已经被替换进去，但 SwiftUI 只会在状态变化时重新求值，需要上面的观察者来触发一次重绘。

## 环境变量

| 变量 | 作用 |
|---|---|
| `NOCOMPILE_HOST` | 真机走 Wi-Fi 时指定 Mac 的 IP |
| `NOCOMPILE_DISABLE=1` | 本次运行禁用客户端 |
| `NOCOMPILE_ENABLE_IN_TESTS=1` | 允许在单元测试环境下启用 |

## 常见问题

**提示"未替换任何实现"**：多半是没加 `-Xlinker -interposable`，或加到了 Release 而非 Debug。

**App 启动后 Mac 端一直没有"已连接"**：确认客户端确实被加载了。SPM / 静态库方式检查是否加了 `-ObjC`；bundle 方式检查 `load()` 的返回值和路径；`DYLD_INSERT_LIBRARIES` 方式检查 macOS App 是否开启了 Hardened Runtime。

**提示"未找到构建日志"**：先在 Xcode 完整构建一次；若用了自定义 DerivedData，用 `-d` 指定。

**真机提示签名失败**：先在 Xcode 成功跑一次真机构建，让构建日志里带上签名身份。

**改了属性/方法数量后崩溃或不生效**：这类改动改变了内存布局，需要重新运行 App。NoCompile 会尽量检测并拒绝注入，而不是放任崩溃。
