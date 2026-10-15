# DemoMac —— 端到端验证示例

一个最小的 macOS 命令行程序，用来验证 NoCompile 的热重载链路。它每秒打印 `Greeter.message()` 和 `globalBanner()` 的返回值；注入新实现后，运行中的进程输出会立即变化。

## 运行

```bash
# 1. 生成并构建 demo（需要 xcodegen）
cd Examples/DemoMac
xcodegen generate
xcodebuild -project DemoMac.xcodeproj -scheme DemoMac -configuration Debug -derivedDataPath /tmp/DemoMacDD build

# 2. 启动 NoCompile 引擎（在仓库根目录）
cd ../..
swift build
.build/debug/nocompile --project "$(pwd)/Examples/DemoMac/DemoMac.xcodeproj" -d /tmp/DemoMacDD &

# 3. 运行 demo
/tmp/DemoMacDD/Build/Products/Debug/DemoMac
```

## 验证

程序开始打印：

```
[1] 你好，这是第 1 版实现  [banner v1]
```

此时编辑 `Sources/Greeter.swift`，把 `message()` 的返回值改一下并保存。几秒后，运行中的进程会自动打印出新内容，无需重启：

```
[9] 你好，这是第 2 版实现（热重载成功）  [banner v2]
```

`message()` 走 Swift vtable 覆写，`globalBanner()` 走符号重绑，两条路径一次验证。

## 关键配置

- `project.yml` 里 Debug 配置的 `OTHER_LDFLAGS: -Xlinker -interposable`
- 通过本地 SPM 包依赖 `NoCompile` 产品，`import NoCompileClient` 触发客户端自动启动
- DerivedData 放在 `/tmp/DemoMacDD`，避免落在被监听的工程目录内
