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

> 本地 SPM 包里的代码若也要支持热重载，同样需要给对应 target 的 Debug 配置加这个参数。

## 第二步：链接客户端库（仅 Debug）

### 方式 A：Swift Package Manager（推荐）

1. File → Add Package Dependencies，填入 NoCompile 仓库地址。
2. 把 `NoCompile` 库加到 App target。
3. 确保只在 Debug 生效。客户端代码整体包在 `#if DEBUG` 里，Release 构建为空壳，但仍建议在依赖层面隔离。

### 方式 B：手动链接

把构建出的 `NoCompile.framework`（或静态库）加入工程，并在 Debug 的 Other Linker Flags 里 `-force_load` 它。

接好后无需写任何启动代码，客户端会在镜像加载时自动连接 Mac 端。SwiftUI Preview 和单元测试环境下会自动跳过（需要在单测里启用时设置环境变量 `NOCOMPILE_ENABLE_IN_TESTS=1`）。

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

**提示"未找到构建日志"**：先在 Xcode 完整构建一次；若用了自定义 DerivedData，用 `-d` 指定。

**真机提示签名失败**：先在 Xcode 成功跑一次真机构建，让构建日志里带上签名身份。

**改了属性/方法数量后崩溃或不生效**：这类改动改变了内存布局，需要重新运行 App。NoCompile 会尽量检测并拒绝注入，而不是放任崩溃。
