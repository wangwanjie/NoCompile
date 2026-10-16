# NoCompileExample

同一个工程里有两个 App，分别用来在 iOS（真机 / 模拟器）和 macOS 上验证热重载：

| Target | 平台 | 覆盖的场景 |
|---|---|---|
| `ExampleiOS` | iOS 15+，真机与模拟器 | Swift 页面、ObjC 页面、ObjC 自定义视图、Swift / ObjC / C / C++ 函数、storyboard / xib 页面、图片资源、新增文件 |
| `ExampleMac` | macOS 12+ | Swift 页面（自定义 `loadView`）、Swift / ObjC / C / C++ 函数 |

业务代码里没有任何 NoCompile 相关的 `import`、调用或 `injected()` 方法。客户端随 Debug 构建链入后会自动启动，热重载后新代码立即生效，已打开的页面退出重进即可看到。

## 运行步骤

### 1. 生成工程（已生成可跳过）

```bash
cd Examples/NoCompileExample
xcodegen generate
```

### 2. 启动 NoCompile（在仓库根目录）

```bash
Scripts/build-app.sh --open --project "$(pwd)/Examples/NoCompileExample/NoCompileExample.xcodeproj"
```

NoCompile 以菜单栏 App 运行（右上角 ⚡），不需要也不要在 Xcode 里打开它。一个 NoCompile 实例可以同时服务真机、模拟器和 Mac 三个 App。首次运行若弹出「访问“文稿”文件夹」的授权框，请点「允许」。

### 3. 在 Xcode 运行 App

打开 `NoCompileExample.xcodeproj`：

- **真机**：选 `ExampleiOS` scheme 和你的 iPhone，⌘R。
  - 签名团队已预填为 `X6B6C6U6QV`。如果 Bundle ID 冲突，到 Signing & Capabilities 改一下 `PRODUCT_BUNDLE_IDENTIFIER`。
  - 需要用数据线连接；NoCompile 通过 usbmuxd 连上设备。
- **模拟器**：选 `ExampleiOS` scheme 和任意模拟器，⌘R。
- **Mac**：选 `ExampleMac` scheme，⌘R。

App 启动后，NoCompile 终端会打印 `🔌 已连接：ExampleiOS（真机…）` 之类的日志。

## 验证清单

每项改完都按 ⌘S 保存，约 1~3 秒后 App 顶部浮层提示「已生效」。NoCompile 默认不重建已打开的页面，浮层会提示「退出页面重进即可看到」：子页面返回后重新进入即可。首页是根页面无法退出，验证 1~6、8、11 前先在 NoCompile 偏好设置开启「自动重建已加载的页面」，界面会原地刷新，顶部卡片的「界面构建于 HH:mm:ss」时间随之更新。

| # | 改什么 | 文件 | 预期 |
|---|---|---|---|
| 1 | `message()` 的返回值 | `Shared/SwiftGreeter.swift` | Swift 卡片文案变化（Swift 静态函数，走函数重绑） |
| 2 | `+message` 的返回值 | `Shared/ObjCGreeter.m` | Objective-C 卡片文案变化（ObjC 类方法替换） |
| 3 | `c_greeting()` 的返回值 | `Shared/CGreeting.c` | C 卡片文案变化（C 函数重绑） |
| 4 | `describe()` 的返回值 | `Shared/CppCounter.cpp` | C++ 卡片文案变化（C++ 成员函数重绑） |
| 5 | `themeColor()` / `headline()` | `iOS/HomeViewController.swift` | 首页主题色、标语变化（Swift 页面重建） |
| 6 | `buildContent` 中的颜色 / 文案 | `iOS/ObjCBadgeView.m` | 首页橙色卡片变化（视图类被替换 → 所在页面重建） |
| 7 | 进入「打开 Objective-C 页面」，改 `viewDidLoad` | `iOS/DetailViewController.m` | 返回后重新进入该页即可看到背景色、文案变化 |
| 8 | `themeColor()` / `headline()` | `macOS/MainViewController.swift` | Mac 窗口内容变化（自定义 `loadView` 也能重建） |
| 9 | 进入「打开 Storyboard 页面」，改文案或背景色 | `iOS/Base.lproj/StoryboardDemo.storyboard` | 返回后重新进入该页即可看到新界面 |
| 10 | 进入「打开 Xib 页面」，改文案或背景色 | `iOS/XibDemoViewController.xib` | 返回后重新进入该页即可看到新界面 |
| 11 | 替换图片 | `iOS/Assets.xcassets/DemoBadge.imageset`、`iOS/Images/loose_icon@2x.png` | 首页图片行及 storyboard / xib 页面中的图片更新 |
| 12 | 新建一个 Swift 文件（如 `iOS/NewHelper.swift`，声明 `enum NewHelper { static func text() -> String }`），再在 `SwiftGreeter.swift` 中调用它 | 新文件 + `Shared/SwiftGreeter.swift` | 新文件保存后即被注入，Swift 卡片显示新文件返回的文案 |

两个 App 都在运行时修改 `Shared/` 下的文件，NoCompile 会分别为 iOS 和 macOS 各编译一份并推送，两边同时生效。

## 关键配置

在 `project.yml` 的 Debug 配置里：

- `OTHER_LDFLAGS: -Xlinker -interposable -ObjC`
  - `-interposable` 让 App 内部的函数调用走符号指针，C / C++ / Swift 静态函数才能在运行时被重定向。
  - `-ObjC` 确保客户端库被完整链入，它靠 `+load` 自动启动，业务代码不需要引用它。
- `SWIFT_COMPILATION_MODE: singlefile`：Debug 不使用整模块优化。
- macOS target 使用 "Sign to Run Locally" 签名，未开启 Hardened Runtime，这样能加载 ad-hoc 签名的注入 dylib。

## 已知限制

- 增删方法或存储属性改变了内存布局：ObjC/@objc 方法的增删即时生效；纯 Swift 的增删方法/属性会安全加载但不动屏幕上的旧实例（旧实例布局已固定，改动会越界），重新运行 App 后由新实例体现。NoCompile 不再拒绝注入，也不会崩溃。
- 默认不重建已打开的页面，退出页面重新进入（新建实例）后才使用新代码。
- 开启自动重建后会重新执行 `viewDidLoad`。如果其中注册了通知或 KVO，热重载后可能出现重复注册（仅影响调试会话）；且只重建当前可见的页面，导航栈里被盖住的页面仍需重新进入。
