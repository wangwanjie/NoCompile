# NoCompile 架构与原理

## 整体流程

一次热重载从保存文件到界面更新，经过这几步：

1. **文件监听**（Mac 端）：FSEvents 捕获到源文件保存（Xcode 保存是原子 rename）或新建。storyboard、xib、图片走单独的资源流程，见下文「资源热重载」。
2. **取编译命令**（Mac 端）：从 `.xcactivitylog` 解析出该文件所属模块/目标的编译命令。
3. **单文件重编**（Mac 端）：只编译这一个文件，生成 `.o`。
4. **链接**（Mac 端）：把 `.o` 链接成一个 dylib，未定义符号留到运行时解析。
5. **签名**（Mac 端）：模拟器免签，macOS 用 ad-hoc，真机用开发者身份。
6. **推送**（Mac → App）：模拟器/macOS 传路径，真机传 dylib 字节。
7. **注入**（App 进程内）：`dlopen` 后把新实现嫁接回旧实现。
8. **刷新**（App 进程内）：调用 `injected()` 回调并发出通知。

## 取编译命令：为什么这样做

现有工具有三条路线，各有短板：

- **纯正则扫日志**：写死正则匹配 `.xcactivitylog` 里的命令，Xcode 升级改格式就失效。
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

覆写前逐槽核对：同一下标上新旧实现必须是同名函数（用 `dladdr` 取符号名；字段偏移等非函数槽位跳过）。新旧 `classSize`（或 `classAddressPoint`）不一致，或某个槽位的函数名对不上（调换了方法声明顺序、改了方法名），都视为 vtable 布局变化，**不覆写**，见下文「布局变化时为何不动旧实例」。

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

## 只含分类的文件

分类文件（如 `UIViewController+Xxx.m`）没有 `_OBJC_CLASS_$_` 符号，也没有可改写的函数符号。`dlopen` 时 ObjC 运行时会把新分类的方法列表挂到宿主类方法列表的最前面，同名方法先于旧分类命中，改动随即生效。`NCInjector` 读取新镜像的 `__objc_catlist` 统计分类数（日志里的"分类 N"），有分类附加即视为注入成功；宿主类属于 App 时还会纳入受影响类，用于提示重进页面，系统类则不纳入。

## 类型判定修复

注入后，dylib 内 `[Foo new]` 得到"新 Foo"，App 其余代码持有"旧 Foo"，两者不是同一个 Class 对象，会让 `isKindOfClass:` / `as?` 判定失败。

处理办法（见 `NCDynamicCast.m`）：登记新类到其原始类的映射，并改写 `isKindOfClass:` / `isMemberOfClass:`，按"归一化后的原始类"比较。

## 零侵入刷新

注入完成后，主线程上会执行以下步骤（实现见 `NCSweeper.m`）：

1. 从各窗口的根控制器出发，收集当前可见的控制器。导航控制器只取栈顶，标签栏控制器只取选中项，另外包括被 present 的控制器和子控制器。
2. 以**类名**判断受影响的控制器。App 里的实例属于旧类，dylib 里的是新类，两者名字相同。命中条件是控制器自身的类被替换，或它的视图层级里有被替换的视图类。系统容器（导航、标签栏等）不重建。
3. 如果一个控制器都没命中（改的是模型、C/C++ 函数等非界面代码），就取最上层的可见业务控制器。
4. **默认不重建已加载的控制器**：命中的控制器类名作为 `pending` 回报，日志、HUD 与 Mac 控制台提示「退出页面后重新进入」，新建的实例直接使用新代码。在已加载的实例上重跑 `viewDidLoad` 容易带来重复注册通知 / KVO、状态丢失等副作用，所以只有开启 `autoReloadViewControllers`（偏好设置「自动重建已加载的页面」）后才执行第 5 步。
5. 重建步骤（需开启自动重建）：移除子控制器，清空根视图的子视图（重写了 `loadView` 的则重新 `loadView` 并替换原视图），再依次调用 `viewDidLoad`、`viewWillAppear`、`viewDidAppear`。根视图是 table / collection view 的，只 `reloadData`。界面来自 storyboard / xib 的控制器（`nibName` 非空）改为重新实例化 nib，见下文「资源热重载」；重新实例化失败时保持原样，不清空视图。
6. 发出 `NoCompileDidInjectNotification` 和兼容的 `INJECTION_BUNDLE_NOTIFICATION`，供 SwiftUI 等场景使用。

兼容项：类或控制器如果实现了 InjectionIII 风格的 `+injected` / `-injected`，会优先调用它们（无论是否开启自动重建），不走默认流程。

## 布局变化时为何不动旧实例

增删方法改变 vtable 槽位数，增删存储属性改变实例大小。这两者都在旧实例分配时就定死了：旧元数据的 vtable 缓冲区无法扩容，旧对象的内存块无法扩容。曾尝试两条路线，都会崩溃，已放弃：

- 覆写旧 vtable 的共有前缀：Debug 下 `self.新方法()` 走 vtable 静态派发，覆写后的旧方法体一旦调用新增方法，就按新槽位下标访问越界（`EXC_BAD_ACCESS`）。
- 用新类重新实例化换进容器：Swift 控制器常自定义 `init()` 而不继承 `init(nibName:bundle:)`，调用未继承的初始化器会触发 Swift 运行时陷阱（`EXC_BREAKPOINT`），而且这是陷阱不是 ObjC 异常，`@try` 拦不住，直接杀进程。

替换 ObjC / `@objc` 方法同样不安全：被替换的方法体（`viewWillAppear:` 的 override、outlet 的 getter、`dealloc`、`.cxx_destruct`）按新镜像的字段偏移读写成员、按新槽位派发，在按旧布局分配的旧实例上同样越界。函数级重绑（直接调用的 final 方法、分配构造器 `fC`）也一样。

所以布局变化（实例大小、ivar 名字 / 偏移 / 类型、vtable 槽位数或顺序任一变化）时的策略是：这个类的实现一律不替换（ObjC 方法、vtable、该类成员符号的函数级重绑都跳过），只登记类别名、给新类补齐方法，让新镜像内部创建的实例能通过类型判定；日志与浮层提示重新运行 App。同一文件里布局没变的其他类、自由函数照常替换。这与 InjectionIII 的取舍一致。

另外两类同样会破坏内存的情况也在替换前拦下：

- 类的分配构造器 `fC` 不做函数级重绑（只重绑初始化构造器 `fc`）：否则旧代码里的 `Foo()` 会分配出「新类」实例，旧代码对它做 `as? Foo` 按元数据指针比较会失败甚至崩溃。结构体 / 枚举只有 `fC`，照常重绑。
- 返回 `some View` 等不透明类型的函数：比较新旧不透明类型描述符（`…QOMQ`）里具体类型的 mangled 名（符号引用解析成符号名），不同就不重绑。

分类在 `+load` 里 swizzle 宿主类（如 `UIViewController+Track.m`）时，重新加载会让新旧函数体互相调用陷入无限递归。dlopen 后按函数名修正宿主类上的方法：被交换过的旧条目改指向新函数体，新条目沿用旧条目当前（交换后）的实现，交换关系得以保持。加载期间对 `method_exchangeImplementations` 的拦截覆盖所有 App 镜像，`+load` 经其他文件里的工具方法间接交换也能拦住。

整个注入过程（dlopen、替换、刷新）都在主线程串行执行，避免和 UI 代码并发。

## 新增文件

构建日志里只有已存在文件的编译命令。运行期间新建的文件按以下方式补齐：

- **Swift**：选源文件目录与新文件最接近的模块，把新文件追加进模块的输入列表（有 `@filelist` 时写一份追加后的副本），再照常用 `-###` 展开出它的 frontend 命令。编译通过后登记到该模块，之后重编同模块的其他文件时也把它一并作为输入，否则引用不到新文件里声明的类型。
- **C / ObjC / C++**：借用同平台、目录最接近、优先同语言的已有文件的 clang 命令，替换 `-c` 后的源文件；语言不同时改写 `-x` 并去掉 `-std=`。

App 端以 `RTLD_GLOBAL` 加载新文件生成的 dylib：新文件里的符号在 App 中不存在，之后注入的 dylib（如引用了新类型的旧文件）靠全局符号查找链接到它。没有可替换的实现也视为成功。再次修改新文件时，旧引用会照常通过符号重绑指向新实现。

限制：新增 ObjC 类要被 Swift 使用，需要改桥接头，仍需重新构建。

## 资源热重载

资源文件不经过编译命令，由 `ResourceCompiler.swift` 整理成资源包，以 `resource` 消息下发：

| 资源 | Mac 端 | 资源包中的位置 |
|---|---|---|
| `.storyboard` / `.xib` | `ibtool --compile` 编译，优先沿用构建日志里该文件的 ibtool 参数（`--module`、`--target-device` 等），没有时按平台推断 | `[xx.lproj/]名字.storyboardc` / `名字.nib` |
| 工程中的图片文件 | 连同同目录下同名的其他倍率一起下发 | 与 bundle 中的相对路径一致 |
| Asset Catalog 图片集 | 读取 `Contents.json`，下发当前平台可用的位图变体及倍率、模板渲染属性 | 只登记名字，不覆盖 bundle 条目 |

界面文件按 `targetRuntime` 区分平台，不下发给另一平台的 App。App 图标、颜色集、矢量图片与外观（暗色）变体运行时无法替换，会跳过或提示重新运行。

App 端（`NCResources.m`）：

1. **镜像 bundle**：真机的 App bundle 只读，因此不改写 bundle，而是在 `tmp/NoCompileResources/mirror_N/` 下生成镜像：被更新的条目指向新文件，其余条目软链接回原 bundle。只有被更新条目的上级目录是真实目录，生成开销与 bundle 大小无关。每次换新路径，避免 `NSBundle` 按路径缓存旧实例。Assets.car 等也在镜像中，nib 里引用的图片照常解析。
2. **加载入口 hook**：`storyboardWithName:bundle:`、`nibWithNibName:bundle:`（AppKit 为 `initWithNibNamed:bundle:`）、`loadNibNamed:...` 在请求主 bundle 中已更新的资源时改用镜像 bundle；`pathForResource:ofType:`、`URLForResource:withExtension:` 返回新文件路径。之后新打开的页面、UIKit 自己的 `loadView` 都会拿到新 nib。
3. **图片**：按名字登记新图，hook `imageNamed:` 系列方法直接返回。nib 中的图片在解码时由 `UIImageNibPlaceholder` 生成、不经过 `imageNamed:`，因此另外交换它的 `initWithCoder:`，按 coder 中的 `UIResourceName` 返回新图。
4. **刷新可见页面**（需开启自动重建，默认只提示退出页面重进）：storyboard / xib 刷新由它加载、当前可见的控制器；xib 没有对应控制器（如用于 cell）或图片更新时刷新最上层的可见业务控制器。重建方式是重新实例化 nib，把新根视图换到旧视图的位置，再走生命周期。storyboard 的视图 nib 不以 File's Owner 引用控制器，而是引用场景中的"上游占位对象"：UIKit 在控制器的 `_externalObjectsTableForViewLoading` 中保存了这张表，作为 `UINibExternalObjects` 传入；AppKit 没有这张表，也没有传入外部对象的公开接口，因此重载期间交换 `NSNibExternalObjectPlaceholder` 的 `initWithCoder:`，把 `UpstreamPlaceholder-1` 映射到控制器。重载成功后把控制器的 storyboard 换成新实例，之后的 segue 也使用新版本。

这部分依赖 UIKit / AppKit 的私有行为，所有调用都做了响应性检查和异常保护，失败时只记录日志并保持原界面。

## 通信协议

帧格式（小端）见 `NCProtocol.h` 与 `Protocol.swift`，两边必须一致：

```
magic("NCMP") | type(u32) | jsonLen(u32) | dataLen(u64) | json | data
```

- `inject`（10）携带 dylib，`resource`（12）携带资源包：json 描述资源类型、名字、需要覆盖的 bundle 条目与图片变体；模拟器 / macOS 给出 Mac 端已拷进 App tmp 目录的路径，真机则把各文件内容按 `files` 列表顺序拼接在 data 中。
- 模拟器 / macOS：客户端主动连 Mac 的 21890 端口。
- 真机：客户端在回环监听 21891，Mac 经 usbmuxd（`DeviceBridge.swift`）连入。
