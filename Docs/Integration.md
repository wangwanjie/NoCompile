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
| [D. 运行时加载 bundle](#方式-d运行时加载-bundle零依赖仅模拟器--macos) | 一行加载代码 | ❌ 仅模拟器 / macOS | 只用模拟器，InjectionIII 用户 |
| [E. 拷贝 bundle 进 App](#方式-e拷贝-bundle-进-app零依赖支持真机) | Run Script + 一行加载代码 | ✅ | 零依赖且要支持真机（**推荐**） |
| [F. DYLD_INSERT_LIBRARIES](#方式-fdyld_insert_libraries零代码仅模拟器--macos) | 只改 scheme 环境变量 | ❌ 仅模拟器 / macOS | 完全不改工程与代码 |
| [G. 手动链接](#方式-g手动链接) | 子工程 | ✅ | 想自己掌控构建 |

> [!IMPORTANT]
> D、F 从 Mac 上的 `/Applications/NoCompile.app` 加载客户端，这个路径在真机上不存在：真机上 bundle 加载静默失败，表现为模拟器正常、真机一直连不上。要在真机上热重载，请用 A / B / C / E / G。零依赖的工程用 E，它在模拟器和真机上写法相同。

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

### 方式 D：运行时加载 bundle（零依赖，仅模拟器 / macOS）

与 InjectionIII 的 `iOSInjection.bundle` 用法一致。**只适用于模拟器和 macOS App，真机请用方式 E。**NoCompile.app 内置了各平台的客户端 bundle：

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
#if TARGET_OS_OSX
[[NSBundle bundleWithPath:@"/Applications/NoCompile.app/Contents/Resources/macOSNoCompile.bundle"] load];
#elif TARGET_OS_TV && TARGET_OS_SIMULATOR
[[NSBundle bundleWithPath:@"/Applications/NoCompile.app/Contents/Resources/tvOSNoCompile.bundle"] load];
#elif TARGET_OS_SIMULATOR
[[NSBundle bundleWithPath:@"/Applications/NoCompile.app/Contents/Resources/iOSNoCompile.bundle"] load];
#endif
#endif
```

- NoCompile.app 不在 `/Applications` 时改成实际路径。
- macOS App 若开启了 Hardened Runtime，需在 Debug 的 entitlements 里加 `com.apple.security.cs.disable-library-validation`，否则系统会拒绝加载其他团队签名的 bundle；或者改用方式 E，由脚本用 App 自己的身份重签。
- 模拟器进程能直接访问 Mac 的文件系统，所以可以从 NoCompile.app 里加载。真机上没有这个路径，`bundleWithPath:` 返回 nil，不会有任何报错，Mac 端也不会出现「已连接」，请用方式 E。

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

   Objective-C：

   ```objc
   #if DEBUG
   NSString *path = [[NSBundle mainBundle] pathForResource:@"NoCompile" ofType:@"bundle"];
   if (path) {
       [[NSBundle bundleWithPath:path] load];
   }
   #endif
   ```

   从方式 D 迁移过来时，删掉原来从 `/Applications/NoCompile.app` 加载的代码，只保留上面这段，模拟器和真机都会生效。

脚本支持的环境变量：

| 变量 | 作用 |
|---|---|
| `NOCOMPILE_BUNDLES_DIR` | bundle 所在目录，默认为脚本所在目录 |
| `NOCOMPILE_COPY_CONFIGURATIONS` | 允许拷贝的配置名，逗号分隔，例如 `Debug,Dev` |
| `NOCOMPILE_DISABLE_COPY=1` | 临时关闭拷贝 |

#### 一键接入脚本（本地调试、不提交）

接入改动不想提交到仓库时，每次切换分支都要重新设置一遍。`nocompile_setup.py` 可以自动完成方式 E 的全部接入，并能原样撤销：

```bash
cd /path/to/YourProject   # 含 .xcworkspace 或 .xcodeproj 的目录
/Applications/NoCompile.app/Contents/Resources/nocompile_setup.py
```

脚本对每个 App 类型的 target、名字含 `Debug` 的配置做以下改动：

1. Other Linker Flags 追加 `-Xlinker -interposable`（project 级配置里已有且 target 级用 `$(inherited)` 继承时跳过）；`EXPORTED_SYMBOLS_FILE` 有值时清空（例如只导出 `_main` 的工程），不想清空就加 `--keep-exported-symbols`；
2. Build Phases 末尾添加 Run Script「[NoCompile] Copy Bundle」调用 `nocompile_copy_bundle.sh`，并在这些配置里设置 `ENABLE_USER_SCRIPT_SANDBOXING = NO`；
3. 在 `application:didFinishLaunchingWithOptions:`（iOS / tvOS）、`applicationDidFinishLaunching`（macOS）或 SwiftUI `App` 的 `init()` 最前面插入加载 `NoCompile.bundle` 的代码，按文件语言生成 Swift 或 Objective-C。模拟器与 macOS 上 App 内没有 bundle 时，代码会回退到从 NoCompile.app 加载对应平台的 bundle。

切换分支前撤销，切过去后再运行一次：

```bash
/Applications/NoCompile.app/Contents/Resources/nocompile_setup.py --remove
git checkout other-branch
/Applications/NoCompile.app/Contents/Resources/nocompile_setup.py
```

**配合 CocoaPods 自动接入**：每次切换分支后都要 `pod install` 的工程，可以在 Podfile 里加一个钩子，用环境变量 `IntegrateNoCompile` 作开关（写法与常见的 `integrateHotReload` 之类开关一致）：

```bash
/Applications/NoCompile.app/Contents/Resources/nocompile_setup.py --install-pod-hook   # 在 Podfile 加钩子，提交给团队
```

生成的钩子如下（Podfile 已有 `post_integrate` 时，调用会插到它的最前面）：

```ruby
post_integrate do |installer|
  nc_setup_script = ENV['NOCOMPILE_SETUP_SCRIPT'] || '/Applications/NoCompile.app/Contents/Resources/nocompile_setup.py'
  if File.exist?(nc_setup_script)
    nc_project_dir = File.dirname(File.expand_path(__FILE__))
    # 等所有钩子（包括插件的）执行完再运行，避免插件保存工程时覆盖脚本的修改
    at_exit do
      if $!.nil? || ($!.is_a?(SystemExit) && $!.success?)
        system('/usr/bin/python3', nc_setup_script, '--sync', nc_project_dir)
      end
    end
  end
end
```

钩子会在 `pod install` 成功结束时调用 `--sync`：`IntegrateNoCompile=true` 时接入，否则撤销之前接入的改动（本来没接入时不输出任何内容）。没装 NoCompile.app 的同事不受影响，钩子本身可以提交。要用的人在 shell 配置里打开开关：

```bash
export IntegrateNoCompile=true
```

之后切换分支的流程：

```bash
/Applications/NoCompile.app/Contents/Resources/nocompile_setup.py --remove   # 切换分支前撤销
git checkout other-branch
pod install                                                                   # 钩子自动重新接入
```

调用放在 `at_exit` 里，是因为 CocoaPods 插件的 `post_integrate`（例如 `cocoapods-arm64-to-sim`）在 Podfile 的钩子之后执行，并会把内存中的工程再保存一次；在钩子里直接调用脚本，脚本对 `project.pbxproj` 的修改会被覆盖，只剩源码里的加载代码。用 0.2.10 生成或手动照抄了旧钩子的，先删掉旧钩子再运行 `--install-pod-hook`。

`NOCOMPILE_SETUP_SCRIPT` 可以临时把钩子指向其他位置的脚本（例如 NoCompile 仓库里的开发版本），只在本机 shell 里设置，不要写进 Podfile。去掉钩子用 `--uninstall-pod-hook`。

- 改动都带标记：构建设置的原值记录在 `NOCOMPILE_SETUP_ADDED` 中，源码插入在 `>>> NoCompile setup` 与 `<<< NoCompile setup` 两行注释之间。`--remove` 只还原这些标记处，工程与源码里的其他改动不受影响；在没有其他改动时，撤销后 `git status` 是干净的。
- 重复运行是安全的，已接入的部分会跳过。已通过 CocoaPods 引入 NoCompile 的 target 整体跳过；已通过 SPM 链接客户端的 target 只补链接参数。源码里已有加载 `NoCompile.bundle` 的代码时不再插入。
- 目录下有多个 workspace 或工程时，把要接入的那个作为参数传入。
- 常用参数：`--configs Debug,Dev` 指定配置（同时会写入 `NOCOMPILE_COPY_CONFIGURATIONS`）、`--target App` 只处理某个 target、`--dry-run` 只预览不写文件。
- 运行前最好关闭工程或确认 Xcode 里没有未保存的工程设置改动，避免 Xcode 用内存中的旧工程覆盖脚本的修改。

### 方式 F：DYLD_INSERT_LIBRARIES（零代码，仅模拟器 / macOS）

只适用于模拟器和 macOS App，真机请用方式 E。bundle 的可执行文件是动态库，可以在 scheme 里直接注入，工程和代码都不用改。Edit Scheme → Run → Arguments → Environment Variables 添加：

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

0. 客户端必须打进 App 包里：用方式 A / B / C / E / G。方式 D、F 从 Mac 路径加载，真机上无效。
1. 用数据线连接设备（USB 为主通道，走 usbmuxd）。
2. 真机注入需要 iOS / tvOS 15+（Xcode 27 的最低部署目标）。
3. dylib 要用与 App 一致的开发者身份签名。NoCompile 会从构建日志自动提取签名身份，所以需要先在 Xcode 成功跑过一次真机构建。
4. 若要走 Wi-Fi，设置环境变量 `NOCOMPILE_HOST=<Mac 的 IP>` 后再运行 App。两端都开启了 TCP 保活：Mac 休眠、设备断网等情况下约 1 分钟内判定断开，App 随后自动重连，期间漏掉的改动会补推。

## Mac Catalyst（实验性）

Catalyst App 与 macOS App 一样主动连接本机的 NoCompile（端口 21890），按 `-target …-macabi` 的编译命令重编，使用临时签名，接入方式同 iOS（SPM / CocoaPods / bundle 均可）。

## 界面如何刷新（零侵入）

业务代码不需要为热重载写任何代码。每次注入完成后，新代码立即生效，NoCompile 会：

1. 找到当前可见、且受本次改动影响的视图控制器。判断依据有两种：控制器自身的类被替换了，或它的视图层级里有被替换的视图类。改的是模型、工具类、C/C++ 函数这类非界面代码时，取最上层的可见业务页面。
2. **默认不重建这些已加载的页面**，在日志、App 顶部浮层和 Mac 控制台提示「退出页面重进即可看到」。返回后重新进入页面（新建实例）就会按新代码构建，避免在旧实例上重跑 `viewDidLoad` 导致的重复注册通知 / KVO、页面状态丢失等问题。
3. 需要原地刷新（例如改的是无法退出的根页面）时，在偏好设置开启「自动重建已加载的页面」，或在调试代码里设置 `NoCompile.autoReloadViewControllers = YES`。开启后会清空这些控制器的视图，再依次调用 `viewDidLoad`、`viewWillAppear`、`viewDidAppear`；重写了 `loadView` 的控制器会重新执行 `loadView`，来自 storyboard / xib 的页面会重新加载 nib。

UIKit 和 AppKit 都支持。

**兼容 InjectionIII 的 `injected()`（可选）**：如果某个类已经实现了 `-injected` / `+injected`，NoCompile 会调用它，替代默认流程（无论是否开启自动重建）。从 InjectionIII 迁移过来的项目可以直接沿用。新项目不需要写。

## 资源与新增文件

除了源码，以下改动保存后也会热重载，无需额外接入（可在偏好设置的「热重载界面与图片资源」或命令行 `--no-resources` 关闭）：

- **storyboard / xib**：Mac 端用 ibtool 重新编译后下发，之后打开的页面使用新版本；当前可见的页面退出重进即可看到（开启自动重建后原地按新 nib 重建）。
- **图片**：替换 Asset Catalog 图片集里的位图或工程中的图片文件后，`UIImage(named:)` / `NSImage(named:)` 和 nib 中引用的图片都会返回新图，当前页面退出重进即可看到。
- **新增源文件**：运行中新建的 Swift / ObjC / C / C++ 文件保存后会被编译注入，之后修改的已有文件可以直接使用其中的新类型和函数。

另外：`.strings`（`NSLocalizedString`）、`json` / `plist` 等原样拷贝进 bundle 的资源，以及 Asset Catalog 颜色集（`UIColor(named:)`）保存后也会更新。

限制：

- 资源按构建日志里记录的拷贝 / 编译目标找到所属 bundle，因此 framework、资源 bundle 里的 xib、图片、strings、json 等同样支持（需要这份资源出现在最近解析过的完整构建日志里）。
- 颜色集只支持不带外观变体的通用颜色；App 图标、矢量（PDF / SVG）图片、暗色等外观变体不在热重载范围内。
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

`.enableInjection()` 同时把 `body` 的返回类型擦除成 `AnyView`。没有它时，`some View` 背后的具体类型随视图结构变化（如 `VStack` 里增删子视图），替换 `body` 会破坏内存，NoCompile 会跳过这类改动并提示；只改文字、颜色等不改变结构的改动不受影响。

> SwiftUI 目前还做不到完全零侵入：`body` 的新实现已经被替换进去，但 SwiftUI 只会在状态变化时重新求值，需要上面的观察者来触发一次重绘。

## 环境变量

| 变量 | 作用 |
|---|---|
| `NOCOMPILE_HOST` | 真机走 Wi-Fi 时指定 Mac 的 IP |
| `NOCOMPILE_DISABLE=1` | 本次运行禁用客户端 |
| `NOCOMPILE_ENABLE_IN_TESTS=1` | 允许在单元测试环境下启用 |

## 真机连不上

模拟器正常、真机一直没有「已连接」时，按下面的顺序排查：

1. **接入方式**：最常见的原因是用了方式 D（`bundleWithPath:@"/Applications/NoCompile.app/..."`）或 F。它们只适用于模拟器，真机请改用方式 E 或 CocoaPods / SPM。Mac 端检测到 USB 真机上持续没有客户端时，控制台会给出提示。
2. **客户端是否在设备上运行**：真机运行 App 后，Xcode 控制台应出现 `[NoCompile] 正在监听 127.0.0.1:21891`。没有这一行说明客户端没被加载：检查是否是 Debug 构建、方式 E 的 Run Script 是否在当前配置生效（配置名不含 `Debug` 时设置 `NOCOMPILE_COPY_CONFIGURATIONS`）。
3. **运行诊断脚本**：设备用数据线连好、App 在前台运行时执行 `bash Scripts/diagnose_device.sh`（脚本见 [Scripts/diagnose_device.sh](../Scripts/diagnose_device.sh)），结果保存在桌面的 `NoCompile-device-diagnose.txt`。看第 3 节：
   - 62078 成功、21891 返回 3：USB 通道正常，设备上没有客户端在监听，回到第 1、2 步。
   - 21891 返回 0 但仍未连接：在第 6 节日志里找「忽略」「搁置」，通常是 App 被判定为其他工程构建的。
   - 只有 Network 条目或 62078 也失败：设备没有通过 USB 连到 usbmuxd，换数据线 / 直连 Mac 的接口后重试。
   - 无法使用 usbmuxd：重启 Mac。

## 常见问题

**提示"未替换任何实现"**：多半是没加 `-Xlinker -interposable`，或加到了 Release 而非 Debug。

**App 启动后 Mac 端一直没有"已连接"**：确认客户端确实被加载了。SPM / 静态库方式检查是否加了 `-ObjC`；bundle 方式检查 `load()` 的返回值和路径（真机不能用方式 D / F，见[真机连不上](#真机连不上)）；`DYLD_INSERT_LIBRARIES` 方式检查 macOS App 是否开启了 Hardened Runtime。

**注入失败：存在未解析符号（symbol not found in flat namespace '_OBJC_CLASS_$_Foo'）**：注入的 dylib 引用的 App 符号没有被 App 导出。最常见的是工程在 Debug 下也设置了 `EXPORTED_SYMBOLS_FILE`（例如只导出 `_main`）或 `GCC_SYMBOLS_PRIVATE_EXTERN = YES`（`-fvisibility=hidden`），App 里的类、函数、常量在符号表里都变成了 `non-external (was a private external)`。NoCompile 会从 DerivedData 中与 App 相同 UUID 的二进制里找到这些符号，按 App 运行时的地址生成一个小的「符号桥接」dylib，先于注入 dylib 加载，日志里会显示「桥接 N 个 App 未导出的符号」。这需要 App 内的客户端在握手时上报镜像的 slide，App 里还是旧客户端时会提示重新编译运行 App；用方式 E 接入的，升级 NoCompile 后要重新构建一次，让 Run Script 把新 bundle 拷进 App（握手日志里的「客户端 x.y.z」应与 Mac 端一致）。Swift 的 `private` / `fileprivate` 符号不在桥接范围内，引用了其他文件私有符号的改动仍需重新运行 App。

**提示"未找到构建日志"**：先在 Xcode 完整构建一次；若用了自定义 DerivedData，用 `-d` 指定。

**真机提示签名失败**：先在 Xcode 成功跑一次真机构建，让构建日志里带上签名身份。

**提示"NoCompile 版本不一致，请重新编译 App"**：App 里的客户端与正在运行的 Mac 端不是同一版本，最常见的是用方式 E 把 bundle 拷进了 App，之后 Mac 端升级了、App 却没重新编译，包里还是旧 bundle。Mac 端握手时会比对客户端修订号（`clientRevision`），它只在客户端代码或协议发生不兼容变化时才递增，与发版的版本号无关：只升级版本号、客户端没有变化的新版本，不需要重新编译 App。不一致时不会向该 App 推送热重载，重新编译运行 App（必要时先 Clean Build Folder）即可。

**本地 Pod / 子模块拉取代码后没有触发热重载**：NoCompile 监听工程目录，以及 `Podfile.lock` 里以 `:path` 引用的、位于工程目录之外的本地 Pod。一次 git 操作改动的文件会合并成一批处理。改动的头文件会找到引用它的实现文件一起重编；如果被超过 10 个文件引用，就只重编与它同名的实现文件，避免改一个公共头文件就重编成百上千个文件。一批改动的源文件超过 100 个（通常是切换了分支）时跳过热重载，这时请重新编译 App。

**排查问题**：在控制台日志栏点 📦 按钮（或菜单 ⚡ → 导出诊断包…）导出 zip。里面包括：
- `Diagnostics.log`：监听、解析日志、编译、链接、签名、发送、注入、连接各环节的明细
- `Failures/`：每次失败的完整命令行（可复制到终端复现）和完整输出
- `Hangs/`：Mac 端主线程卡顿超过 2 秒时自动采集的调用栈
- `Summary.txt`：系统、Xcode 版本、工程与 DerivedData、监听目录、已连接 App 的握手信息、最近的注入记录

**改了属性 / 方法后提示「内存布局变了，请重新运行 App」**：增删、调换顺序的存储属性 / 实例变量 / Swift 方法改变了类的内存布局。旧实例按旧布局分配，新代码（包括 `viewWillAppear:` 这类 @objc override、outlet 的 getter、`dealloc`）按新偏移读写成员、按新 vtable 槽位派发，放到旧实例上会越界或调用到别的方法而崩溃，所以 NoCompile 不替换这个类的实现，重新运行 App 后生效。同一文件里布局没变的其他类、函数照常热重载。

**保存后没有触发热重载**：FSEvents 偶尔会漏报（目录权限、网络盘、事件被合并等）。点控制台顶栏的「检查改动」，或在任意 App（如 Xcode）里按全局快捷键 ⌃⌥⌘R（可在偏好设置中更换或关闭），NoCompile 会扫描工程目录，把漏掉的改动补上。

**连接了多台设备**：同一工程可同时连接多台模拟器 / 真机（每台设备接入一个 App），热重载只推给左侧标为「当前」的设备。点击其他设备即可切换，NoCompile 会把这台设备缺少的改动（本次会话中、晚于其构建时间的）自动补推过去。App 重新运行后连上时同样会补推。其他工程构建的 App 会被忽略，不出现在列表里。
