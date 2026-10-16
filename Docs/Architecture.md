# NoCompile 架构与原理

## 整体流程

一次热重载从保存文件到界面更新，经过这几步：

1. **文件监听**（Mac 端）：FSEvents 捕获到源文件保存（Xcode 保存是原子 rename）。
2. **取编译命令**（Mac 端）：从 `.xcactivitylog` 解析出该文件所属模块/目标的编译命令。
3. **单文件重编**（Mac 端）：只编译这一个文件，生成 `.o`。
4. **链接**（Mac 端）：把 `.o` 链接成一个 dylib，未定义符号留到运行时解析。
5. **签名**（Mac 端）：模拟器免签，macOS 用 ad-hoc，真机用开发者身份。
6. **推送**（Mac → App）：模拟器/macOS 传路径，真机传 dylib 字节。
7. **注入**（App 进程内）：`dlopen` 后把新实现嫁接回旧实现。
8. **刷新**（App 进程内）：调用 `injected()` 回调并发出通知。

## 取编译命令：为什么这样做

现有工具有三条路线，各有短板：

- **纯正则扫日志**（CocoaHotReload）：写死正则匹配 `.xcactivitylog` 里的命令，Xcode 升级改格式就失效。
- **改 Xcode 工具链**（InjectionNext 的 Intercept 模式）：把 `swift-frontend` 换成脚本，破坏 Xcode 签名完整性，升级后要重打补丁。
- **解析 SourceKit 私有日志**（InjectionNext 主模式）：依赖未公开的 `SOURCEKIT_LOGGING` 格式，且必须由工具启动 Xcode。

NoCompile 的做法：从日志里只取**模块级别的 driver 命令**（`builtin-SwiftDriver -- swiftc ...`），这条命令稳定、信息完整。然后把它交给官方 `swiftc -###`，让编译器自己展开出每个文件的 frontend 命令，从中挑出目标文件那条执行。

好处：frontend 命令的具体参数由当前 Xcode 的编译器生成，Xcode 升级后参数怎么变都能自动跟随，无需我们维护正则。

实测在 Xcode 27 上，`-###` 展开耗时约 0.45 秒，单文件 Swift 重编（热模块缓存）约 1.7 秒，ObjC 约 2.6 秒。

### 清洗编译参数

driver 命令里有些参数会干扰单文件重编，需要去掉：

- 增量编译相关：`-incremental`、`-enable-batch-mode`、`-output-file-map`
- 整模块产物：`-emit-module`、`-emit-objc-header`、`-emit-dependencies` 及其 `-path`
- 会被清理的中间文件：`-dependency-scan-serialize-diagnostics-path`、`-clang-build-session-file`、`-ivfsstatcache`

展开出的 frontend 命令里，还要把 Xcode 16+ 的**显式模块**机制关掉（`-disable-implicit-swift-modules`、`-explicit-swift-module-map-file`、`-Xcc -fno-implicit-modules`）。因为它依赖的预编译 `.pcm` 会在构建之间被清理，改回隐式模块构建后，frontend 命令就能自给自足。

## 链接：flat namespace

```
clang -arch <arch> -isysroot <sdk> -dynamiclib \
      -undefined dynamic_lookup \
      -Xlinker -interposable \
      -fobjc-arc -fprofile-instr-generate \
      -L <swift运行时> \
      <object> -o <dylib>
```

关键是 `-undefined dynamic_lookup`：dylib 里对 App 已有类型和函数的引用全部留作未定义，`dlopen` 时从已加载的主程序里扁平查找。这样 dylib 只包含被改动的那个文件。

`-fprofile-instr-generate` 用来避免 `___llvm_profile_runtime` 符号缺失。

## 进程内注入：三层替换

被注入的 dylib 重新定义了同名的类和函数。要让运行中的 App 用上新实现，分三层处理（见 `NCInjector.m`）：

### 1. ObjC 方法替换

遍历新类的 method list，用 `class_replaceMethod` 把实现写回旧类（实例方法和类方法都处理）。ObjC 的消息派发是动态的，替换 IMP 立即生效。

### 2. Swift 类 vtable 覆写

Swift 类方法通过 vtable 静态派发。Swift 类的元数据布局（见 `NCSwiftMetadata.h`）里，vtable 紧跟在 `IVarDestroyer` 字段之后，长度由 `classSize` 决定。把新类元数据的 vtable 槽位逐个复制进旧类元数据即可。

如果新旧 `classSize` 不一致，说明增删了方法或改了布局，这时拒绝覆写并上报，避免崩溃。

### 3. 符号重绑（interpose）

C / C++ 自由函数、Swift 的全局函数和静态派发函数，既不走 ObjC 消息也不在 vtable 里。处理办法是改写 GOT：

以 `-interposable` 链接后，App 内部对自己全局符号的调用也会经过 `__got` / `__la_symbol_ptr` 间接寻址。NoCompile 自实现了 fishhook 的思路（见 `NCRebind.m`）：遍历所有"属于 App 的"镜像的 `__DATA` / `__DATA_CONST` 段，找到指向旧符号的指针，改写成新实现的地址。

哪些符号可替换由 mangled 名后缀判断（`NCInjectableSymbol`）：函数 `F`、getter/setter `vg`/`vs`、析构 `fD` 等；C++ 的 `_ZN` 一律放行。

## 保留静态状态

默认情况下，dylib 里的全局/静态变量寻址器（`vau` 后缀）会被重绑到新 dylib，相当于单例被重建。开启"保留静态状态"（默认开）后，加载前记下旧寻址器，再把新镜像里的引用重绑回旧实现，单例和全局状态就不会丢。

## +load 死循环防护

dylib 被 `dlopen` 时会重新执行类和分类的 `+load`。如果 `+load` 里做了 `method_exchangeImplementations`，再次交换会让 hook 链自我指向，造成无限递归。

防护办法（见 `NCSwizzleGuard.m`）：注册 dyld 的 add-image 回调。该回调在新镜像完成符号绑定之后、执行 `+load` 之前触发，这时把新镜像对 `method_exchangeImplementations` 的引用重绑为一个空操作版本，让重复的交换不再发生，已有的 hook 链就能保持不变。

已知局限：如果被重编的是对**其他类**做 swizzle 的分类文件（比如 `UIViewController+Tracking.m`），分类方法本身会被 runtime 重新附加。这种情况可能破坏 hook 链，建议改完后重新运行 App。

## 类型判定修复

注入后，dylib 内 `[Foo new]` 得到"新 Foo"，App 其余代码持有"旧 Foo"，两者不是同一个 Class 对象，会让 `isKindOfClass:` / `as?` 判定失败。

处理办法（见 `NCDynamicCast.m`）：登记新类到其原始类的映射，并改写 `isKindOfClass:` / `isMemberOfClass:`，按"归一化后的原始类"比较。

## 零侵入刷新

注入完成后，主线程上会执行以下步骤（实现见 `NCSweeper.m`）：

1. 从各窗口的根控制器出发，收集当前可见的控制器。导航控制器只取栈顶，标签栏控制器只取选中项，另外包括被 present 的控制器和子控制器。
2. 以**类名**判断受影响的控制器。App 里的实例属于旧类，dylib 里的是新类，两者名字相同。命中条件是控制器自身的类被替换，或它的视图层级里有被替换的视图类。系统容器（导航、标签栏等）不重建。
3. 如果一个控制器都没命中（改的是模型、C/C++ 函数等非界面代码），就刷新最上层的可见业务控制器。
4. 重建步骤：移除子控制器，清空根视图的子视图（重写了 `loadView` 的则重新 `loadView` 并替换原视图），再依次调用 `viewDidLoad`、`viewWillAppear`、`viewDidAppear`。根视图是 table / collection view 的，只 `reloadData`。
5. 发出 `NoCompileDidInjectNotification` 和兼容的 `INJECTION_BUNDLE_NOTIFICATION`，供 SwiftUI 等场景使用。

兼容项：类或控制器如果实现了 InjectionIII 风格的 `+injected` / `-injected`，会优先调用它们，不走默认重建。

整个注入过程（dlopen、替换、刷新）都在主线程串行执行，避免和 UI 代码并发。

## 通信协议

帧格式（小端）见 `NCProtocol.h` 与 `Protocol.swift`，两边必须一致：

```
magic("NCMP") | type(u32) | jsonLen(u32) | dataLen(u64) | json | data
```

- 模拟器 / macOS：客户端主动连 Mac 的 21890 端口。
- 真机：客户端在回环监听 21891，Mac 经 usbmuxd（`DeviceBridge.swift`）连入。
