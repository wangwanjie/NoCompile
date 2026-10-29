/* NoCompile 主页脚本：三语切换、三态主题、首屏「闪电热替换」演示、复制、接入标签页、滚动渐入 */
(function () {
  'use strict';

  var doc = document.documentElement;
  var reduceMQ = matchMedia('(prefers-reduced-motion: reduce)');
  var darkMQ = matchMedia('(prefers-color-scheme: dark)');
  var query = new URLSearchParams(location.search);

  // ---------- 文案 ----------
  var I18N = {
    'zh-CN': {
      title: 'NoCompile — iOS / macOS 热重载工具',
      desc: 'NoCompile 只重新编译改动的那个文件并注入运行中的 App，保存即生效。支持 C、C++、Objective-C、Swift，覆盖模拟器、真机与 macOS，客户端 SDK 以 MIT 开源。',
      ogDesc: '修改代码，保存，立即在运行中的 App 看到效果。支持 C、C++、Objective-C、Swift。',
      skip: '跳到正文', brandAria: 'NoCompile 首页', navAria: '页面导航',
      navHow: '原理', navFeatures: '特性', navIntegrate: '接入', navDownload: '下载',
      langAria: '语言', themeAria: '主题', themeLight: '浅色', themeDark: '深色', themeSystem: '跟随系统',
      eyebrow: 'iOS / macOS 热重载 · C · C++ · Objective-C · Swift',
      heroTitle: '改完代码，按下 <kbd>⌘S</kbd>，<br><em>它已经在 App 里生效</em>',
      heroLede: 'NoCompile 只重新编译你刚改动的那一个文件，链接成 dylib 注入正在运行的 App，把新实现换上去。不用停 App，也不用等整个工程重新编译。',
      dlArm: '下载 · Apple 芯片', dlIntel: 'Intel 版',
      metaLatest: '最新版本', metaReq: 'macOS 12+ · Apple 公证 · Sparkle 自动更新 · 客户端 SDK MIT 开源',
      stageAria: '演示：修改 Swift 代码并保存，闪电划过，模拟器里的界面立即更新',
      stageNote: '演示动画。示例工程实测：单个 Swift / Objective-C / C 文件保存后 0.3～0.8 秒生效，整个过程通常在 1～3 秒内完成。',
      howKicker: '原理', howTitle: '一次保存，五步注入',
      howSub: 'Mac 端监听文件变化，只重编改动的文件；App 进程内的客户端收到 dylib 后完成替换。模拟器与 macOS 走本机 TCP，真机走 USB（usbmuxd）。',
      flow1: 'FSEvents 捕获保存', flow2: '从构建日志还原单文件编译命令', flow3: '只编译这一个文件并链接', flow4: '用 App 的身份签名后推送', flow5: '进程内替换为新实现',
      layer1: 'Objective-C 方法替换', layer2: 'Swift 类的虚函数表覆写', layer3: 'C / C++ 自由函数与符号重绑',
      featKicker: '特性', featTitle: '为日常开发打磨的热重载',
      f1t: '四种语言，一套机制', f1d: 'C、C++、Objective-C、Swift 统一支持：ObjC 方法、Swift 类方法、C/C++ 自由函数都能替换，后者通过 GOT 重绑覆盖。',
      f2t: '编译命令跟随 Xcode', f2d: '解析构建日志拿到 driver 命令，再交给官方 <code>swiftc -###</code> 展开单文件命令。参数由编译器自己生成，Xcode 升级自动跟随。',
      f3t: '保存即注入', f3d: 'FSEvents 自动触发，无需按快捷键。漏检时点「检查改动」或按全局快捷键 <kbd>⌃⌥⌘R</kbd> 补上。',
      f4t: '真机走 USB', f4d: '以 usbmuxd 为主通道连接真机，不依赖局域网广播；从构建日志自动提取签名身份。',
      f5t: '资源与新文件', f5d: 'storyboard、xib、图片保存即生效（含真机）；运行中新建的源文件也能注入。',
      f6t: '零侵入刷新', f6d: '业务类不必实现 <code>injected()</code>。已打开的页面退出重进即可看到，也可开启自动重建；SwiftUI 配合 <code>@ObserveInjection</code> 监听注入通知自动重绘。',
      f7t: '类型判定不失效', f7d: '登记新旧类的等价关系，注入后 <code>isKindOfClass:</code> 与 <code>as?</code> 照常工作。',
      f8t: '中文与空格路径', f8d: '全程用参数数组调用子进程，不拼接 shell 字符串，工程放在任何目录都能用。',
      f9t: '布局变化时主动保护', f9d: '增删存储属性、调换 Swift 方法顺序、SwiftUI 视图结构变化会改变内存布局。NoCompile 检测到后不替换该类，并在日志与 App 浮层提示重新运行；同文件里其他类和函数照常生效。SwiftUI 在 <code>body</code> 末尾加 <code>.enableInjection()</code> 即可热重载结构改动。',
      shotKicker: '控制台', shotTitle: '每一次注入都看得见',
      shotSub: '左侧是已连接的 App 与最近的注入记录（成功 / 失败数、平均耗时），右侧是按类别着色、可筛选搜索的日志。编译失败时右键即可在 Xcode 中定位到出错行；遇到问题可一键导出诊断包。',
      shotAlt: 'NoCompile 控制台与 iOS 模拟器中的示例 App：分别修改 Swift、Objective-C、C 文件并保存，0.3～0.8 秒即在运行中的 App 里生效',
      intKicker: '接入', intTitle: '两步接入，只在 Debug 生效',
      intSub: '客户端 SDK 就在本仓库，零第三方依赖，支持 iOS / tvOS 15+ 与 macOS 12+。',
      s1t: 'Debug 配置添加链接参数',
      s1d: 'Build Settings → Other Linker Flags，只给 <b>Debug</b> 填写。它让 App 内部的函数调用走 GOT 间接寻址，运行时才能重定向到新实现。CocoaPods 方式会自动加上。',
      copy: '复制', copied: '已复制到剪贴板', copyFail: '复制失败，请手动选择',
      s2t: '接入客户端，任选一种', s2d: '以下方式都支持真机，镜像加载或 <code>load()</code> 时自动启动，无需写启动代码。',
      tabsAria: '接入方式', tabBundle: '拷贝 bundle', rec: '零依赖',
      spm1: 'Xcode：File → Add Package Dependencies，填入下面的地址，把 <code>NoCompile</code> 库加到 App target。',
      spm2: '或写进 <code>Package.swift</code>：', spmCm: '// target 的 dependencies',
      spm3: 'Debug 的 Other Linker Flags 再加 <code>-ObjC</code>，确保客户端的类被完整链接。模块名为 <code>NoCompileClient</code>。',
      pod1: '在 Podfile 里只给 Debug 配置引入，然后 <code>pod install</code>：',
      pod2: 'Pod 会自动给 Debug 合并 <code>-Xlinker -interposable</code>，Release 不受影响。其他调试配置名（如 Dev）用 <code>project \'App\', \'Dev\' =&gt; :debug</code> 声明。',
      cart1: 'Cartfile 加一行，然后构建 xcframework：',
      cart2: '把 <code>Carthage/Build/NoCompile.xcframework</code> 以 Embed &amp; Sign 加到 App target，再给 <b>Release</b> 等非调试配置设置排除：',
      bun1: '不引入任何依赖：App target 的 Build Phases 末尾加一个 Run Script，它会把对应平台的 bundle 拷进 App 并重签（默认只在 Debug 配置生效）：',
      bun2: '在启动尽早的位置加载，模拟器与真机写法相同：',
      bun3: '也可以在工程目录运行 <code>nocompile_setup.py</code> 自动完成以上接入，切分支前用 <code>--remove</code> 原样撤销。',
      s3t: '选择工程，运行 App', s3d: '在 Xcode 完整构建过一次后，点菜单栏 ⚡ → 选择工程，再 <kbd>⌘R</kbd> 运行 App。之后编辑任意源文件并保存即可。',
      guide: '完整接入指南：Mac Catalyst、DYLD_INSERT_LIBRARIES、真机排查 →',
      dlTitle: '下载 NoCompile',
      dlSub: '按芯片选择安装包，拖入「应用程序」即可。安装包已经过 Apple 公证，之后通过 Sparkle 自动更新，只接收同架构的更新。',
      dlArm2: 'Apple 芯片（M 系列）', dlIntel2: 'Intel 芯片',
      dlFine: '不确定芯片类型：苹果菜单 → 关于本机，「芯片」显示 Apple M 系列选 arm64，显示 Intel 选 x86_64。每个版本附带 <code>SHA256SUMS.txt</code> 供核对。',
      allReleases: '所有版本与更新说明',
      footAria: '页脚链接', more: 'VanJay 的更多作品', feedback: '反馈问题', license: '客户端 SDK · MIT',
      demoTitle: ['你好，NoCompile', '保存即生效 ⚡'], demoBtn: ['开始使用', '立即发布'],
      demoLog: '注入 HomeViewController.swift 已生效（iPhone 模拟器）'
    },
    'en': {
      title: 'NoCompile — Hot reload for iOS & macOS',
      desc: 'NoCompile recompiles only the file you changed and injects it into your running app. Save, and it is live. C, C++, Objective-C and Swift on Simulator, device and macOS. The client SDK is MIT-licensed.',
      ogDesc: 'Edit code, save, and see it in your running app right away. C, C++, Objective-C and Swift.',
      skip: 'Skip to content', brandAria: 'NoCompile home', navAria: 'Page navigation',
      navHow: 'How it works', navFeatures: 'Features', navIntegrate: 'Integrate', navDownload: 'Download',
      langAria: 'Language', themeAria: 'Theme', themeLight: 'Light', themeDark: 'Dark', themeSystem: 'System',
      eyebrow: 'Hot reload for iOS / macOS · C · C++ · Objective-C · Swift',
      heroTitle: 'Change the code, hit <kbd>⌘S</kbd>.<br><em>It’s already live in your app.</em>',
      heroLede: 'NoCompile recompiles just the one file you touched, links it into a dylib, injects it into the running app and swaps in the new implementation. No relaunch, no full rebuild.',
      dlArm: 'Download · Apple silicon', dlIntel: 'Intel',
      metaLatest: 'Latest', metaReq: 'macOS 12+ · Notarized by Apple · Sparkle auto-updates · MIT-licensed client SDK',
      stageAria: 'Demo: a Swift edit is saved, a lightning bolt strikes, and the Simulator UI updates instantly',
      stageNote: 'Animated demo. Measured in the sample project: a saved Swift / Objective-C / C file goes live in 0.3–0.8 s; the whole round trip usually takes 1–3 s.',
      howKicker: 'How it works', howTitle: 'One save, five steps to live code',
      howSub: 'The Mac app watches your files and recompiles only what changed; the client inside your app loads the dylib and swaps implementations. Simulator and macOS connect over local TCP, devices over USB (usbmuxd).',
      flow1: 'FSEvents catches the save', flow2: 'Single-file compile command rebuilt from the build log', flow3: 'Compile and link just that file', flow4: 'Signed with your app’s identity, then pushed', flow5: 'Swapped in-process',
      layer1: 'Objective-C method replacement', layer2: 'Swift class vtable overwrite', layer3: 'C / C++ free functions via symbol rebinding',
      featKicker: 'Features', featTitle: 'Hot reload built for everyday work',
      f1t: 'Four languages, one mechanism', f1d: 'C, C++, Objective-C and Swift all work: ObjC methods, Swift class methods and C/C++ free functions can be replaced, the latter through GOT rebinding.',
      f2t: 'Compile commands that track Xcode', f2d: 'The driver command comes from the build log and the official <code>swiftc -###</code> expands it into a single-file command. The compiler writes its own flags, so Xcode upgrades just work.',
      f3t: 'Inject on save', f3d: 'FSEvents triggers automatically, no hotkey required. If a change slips through, click “Check Changes” or press the global shortcut <kbd>⌃⌥⌘R</kbd>.',
      f4t: 'Devices over USB', f4d: 'usbmuxd is the main channel to physical devices, with no reliance on LAN broadcast; the signing identity is read from the build log.',
      f5t: 'Resources and new files', f5d: 'Storyboards, XIBs and images take effect on save, devices included. Source files created while the app runs can be injected too.',
      f6t: 'Zero-intrusion refresh', f6d: 'No <code>injected()</code> needed in your classes. Leave and reopen a screen to see the change, or turn on automatic rebuild; SwiftUI redraws with <code>@ObserveInjection</code> listening for the injection notification.',
      f7t: 'Type checks keep working', f7d: 'Old and new classes are registered as equivalent, so <code>isKindOfClass:</code> and <code>as?</code> behave after injection.',
      f8t: 'Any path, any characters', f8d: 'Subprocesses get argument arrays, never concatenated shell strings, so projects in CJK or space-containing paths work.',
      f9t: 'Guards against layout changes', f9d: 'Adding or reordering stored properties, reordering Swift methods, or changing a SwiftUI view’s structure alters memory layout. NoCompile skips that class and asks you to relaunch via the log and an in-app overlay; other classes and functions in the file still update. Add <code>.enableInjection()</code> at the end of a SwiftUI <code>body</code> to hot reload structural changes.',
      shotKicker: 'Console', shotTitle: 'Every injection, in plain sight',
      shotSub: 'Connected apps and recent injections (successes, failures, average time) on the left; color-coded, filterable, searchable logs on the right. Right-click a failed build to jump to the error line in Xcode, and export a diagnostics bundle in one click.',
      shotAlt: 'The NoCompile console next to the sample app in the iOS Simulator: Swift, Objective-C and C files edited and saved, each live in the running app within 0.3–0.8 s',
      intKicker: 'Integrate', intTitle: 'Two steps, Debug only',
      intSub: 'The client SDK lives in this repository with zero third-party dependencies. iOS / tvOS 15+ and macOS 12+.',
      s1t: 'Add a linker flag to Debug',
      s1d: 'Build Settings → Other Linker Flags, <b>Debug</b> only. It routes in-app function calls through the GOT so they can be redirected to new implementations at runtime. CocoaPods adds it for you.',
      copy: 'Copy', copied: 'Copied to clipboard', copyFail: 'Copy failed, please select manually',
      s2t: 'Add the client, any one way', s2d: 'All of these work on physical devices and start automatically on image load or <code>load()</code>, with no startup code.',
      tabsAria: 'Integration method', tabBundle: 'Copy bundle', rec: 'No deps',
      spm1: 'In Xcode: File → Add Package Dependencies, enter the URL below and add the <code>NoCompile</code> library to your app target.',
      spm2: 'Or in <code>Package.swift</code>:', spmCm: '// in your target’s dependencies',
      spm3: 'Also add <code>-ObjC</code> to Debug Other Linker Flags so the client classes are fully linked. The module name is <code>NoCompileClient</code>.',
      pod1: 'Add it to the Debug configuration only in your Podfile, then run <code>pod install</code>:',
      pod2: 'The pod merges <code>-Xlinker -interposable</code> into Debug automatically; Release is untouched. For other debug configurations (e.g. Dev), declare <code>project \'App\', \'Dev\' =&gt; :debug</code>.',
      cart1: 'Add one line to your Cartfile, then build the xcframework:',
      cart2: 'Add <code>Carthage/Build/NoCompile.xcframework</code> to the app target with Embed &amp; Sign, then exclude it from <b>Release</b> and other non-debug configurations:',
      bun1: 'No dependencies at all: add a Run Script at the end of the app target’s Build Phases. It copies the right bundle for the platform into the app and re-signs it (Debug configurations only by default):',
      bun2: 'Load it as early as possible; the same code works on Simulator and device:',
      bun3: 'You can also run <code>nocompile_setup.py</code> in the project folder to do all of this automatically, and <code>--remove</code> to undo it before switching branches.',
      s3t: 'Pick the project, run the app', s3d: 'After one full build in Xcode, choose the project from the ⚡ menu bar icon and run the app with <kbd>⌘R</kbd>. From then on, edit any source file and save.',
      guide: 'Full integration guide: Mac Catalyst, DYLD_INSERT_LIBRARIES, device troubleshooting →',
      dlTitle: 'Download NoCompile',
      dlSub: 'Pick the build for your chip and drag it into Applications. Builds are notarized by Apple and update through Sparkle, always staying on the same architecture.',
      dlArm2: 'Apple silicon (M series)', dlIntel2: 'Intel',
      dlFine: 'Not sure which chip? Apple menu → About This Mac: “Chip” showing Apple M-series means arm64, Intel means x86_64. Every release ships a <code>SHA256SUMS.txt</code> for verification.',
      allReleases: 'All releases and release notes',
      footAria: 'Footer links', more: 'More by VanJay', feedback: 'Feedback', license: 'Client SDK · MIT',
      demoTitle: ['Hello, NoCompile', 'Saved. Live. ⚡'], demoBtn: ['Get Started', 'Ship It'],
      demoLog: 'Injected HomeViewController.swift (iPhone Simulator)'
    },
    'zh-TW': {
      title: 'NoCompile — iOS / macOS 熱重載工具',
      desc: 'NoCompile 只重新編譯改動的那個檔案並注入執行中的 App，儲存即生效。支援 C、C++、Objective-C、Swift，涵蓋模擬器、實機與 macOS，用戶端 SDK 以 MIT 開源。',
      ogDesc: '修改程式碼，儲存，立即在執行中的 App 看到效果。支援 C、C++、Objective-C、Swift。',
      skip: '跳到正文', brandAria: 'NoCompile 首頁', navAria: '頁面導覽',
      navHow: '原理', navFeatures: '特色', navIntegrate: '整合', navDownload: '下載',
      langAria: '語言', themeAria: '主題', themeLight: '淺色', themeDark: '深色', themeSystem: '跟隨系統',
      eyebrow: 'iOS / macOS 熱重載 · C · C++ · Objective-C · Swift',
      heroTitle: '改完程式碼，按下 <kbd>⌘S</kbd>，<br><em>它已經在 App 裡生效</em>',
      heroLede: 'NoCompile 只重新編譯你剛改動的那一個檔案，連結成 dylib 注入正在執行的 App，把新實作換上去。不用停止 App，也不用等整個專案重新編譯。',
      dlArm: '下載 · Apple 晶片', dlIntel: 'Intel 版',
      metaLatest: '最新版本', metaReq: 'macOS 12+ · Apple 公證 · Sparkle 自動更新 · 用戶端 SDK MIT 開源',
      stageAria: '示範：修改 Swift 程式碼並儲存，閃電劃過，模擬器裡的介面立即更新',
      stageNote: '示範動畫。範例專案實測：單一 Swift / Objective-C / C 檔案儲存後 0.3～0.8 秒生效，整個過程通常在 1～3 秒內完成。',
      howKicker: '原理', howTitle: '一次儲存，五步注入',
      howSub: 'Mac 端監聽檔案變化，只重新編譯改動的檔案；App 行程內的用戶端收到 dylib 後完成替換。模擬器與 macOS 走本機 TCP，實機走 USB（usbmuxd）。',
      flow1: 'FSEvents 捕捉儲存', flow2: '從建置記錄還原單檔編譯指令', flow3: '只編譯這一個檔案並連結', flow4: '以 App 的身分簽署後推送', flow5: '在行程內替換為新實作',
      layer1: 'Objective-C 方法替換', layer2: 'Swift 類別的虛擬函式表覆寫', layer3: 'C / C++ 自由函式與符號重新綁定',
      featKicker: '特色', featTitle: '為日常開發打磨的熱重載',
      f1t: '四種語言，一套機制', f1d: 'C、C++、Objective-C、Swift 統一支援：ObjC 方法、Swift 類別方法、C/C++ 自由函式都能替換，後者透過 GOT 重新綁定覆蓋。',
      f2t: '編譯指令跟隨 Xcode', f2d: '解析建置記錄取得 driver 指令，再交給官方 <code>swiftc -###</code> 展開單檔指令。參數由編譯器自己產生，Xcode 升級自動跟上。',
      f3t: '儲存即注入', f3d: 'FSEvents 自動觸發，不必按快速鍵。漏偵測時點「檢查改動」或按全域快速鍵 <kbd>⌃⌥⌘R</kbd> 補上。',
      f4t: '實機走 USB', f4d: '以 usbmuxd 為主要通道連接實機，不依賴區域網路廣播；從建置記錄自動擷取簽署身分。',
      f5t: '資源與新檔案', f5d: 'storyboard、xib、圖片儲存即生效（含實機）；執行中新建的原始碼檔案也能注入。',
      f6t: '零侵入重新整理', f6d: '業務類別不必實作 <code>injected()</code>。已開啟的頁面退出再進入即可看到，也可開啟自動重建；SwiftUI 搭配 <code>@ObserveInjection</code> 監聽注入通知自動重繪。',
      f7t: '型別判斷不失效', f7d: '登記新舊類別的等價關係，注入後 <code>isKindOfClass:</code> 與 <code>as?</code> 照常運作。',
      f8t: '中文與空格路徑', f8d: '全程以參數陣列呼叫子行程，不拼接 shell 字串，專案放在任何目錄都能用。',
      f9t: '版面配置變化時主動保護', f9d: '增刪儲存屬性、調換 Swift 方法順序、SwiftUI 視圖結構變化會改變記憶體配置。NoCompile 偵測到後不替換該類別，並在記錄與 App 浮層提示重新執行；同一檔案裡的其他類別和函式照常生效。SwiftUI 在 <code>body</code> 結尾加上 <code>.enableInjection()</code> 即可熱重載結構改動。',
      shotKicker: '控制台', shotTitle: '每一次注入都看得見',
      shotSub: '左側是已連線的 App 與最近的注入記錄（成功 / 失敗數、平均耗時），右側是依類別著色、可篩選搜尋的記錄。編譯失敗時按右鍵即可在 Xcode 中定位到出錯行；遇到問題可一鍵匯出診斷包。',
      shotAlt: 'NoCompile 控制台與 iOS 模擬器中的範例 App：分別修改 Swift、Objective-C、C 檔案並儲存，0.3～0.8 秒即在執行中的 App 裡生效',
      intKicker: '整合', intTitle: '兩步整合，只在 Debug 生效',
      intSub: '用戶端 SDK 就在本儲存庫，零第三方依賴，支援 iOS / tvOS 15+ 與 macOS 12+。',
      s1t: 'Debug 設定加入連結參數',
      s1d: 'Build Settings → Other Linker Flags，只為 <b>Debug</b> 填寫。它讓 App 內部的函式呼叫走 GOT 間接定址，執行時才能重新導向到新實作。CocoaPods 方式會自動加上。',
      copy: '複製', copied: '已複製到剪貼簿', copyFail: '複製失敗，請手動選取',
      s2t: '整合用戶端，任選一種', s2d: '以下方式都支援實機，映像載入或 <code>load()</code> 時自動啟動，不必撰寫啟動程式碼。',
      tabsAria: '整合方式', tabBundle: '複製 bundle', rec: '零依賴',
      spm1: 'Xcode：File → Add Package Dependencies，填入下方網址，把 <code>NoCompile</code> 程式庫加到 App target。',
      spm2: '或寫進 <code>Package.swift</code>：', spmCm: '// target 的 dependencies',
      spm3: 'Debug 的 Other Linker Flags 再加上 <code>-ObjC</code>，確保用戶端的類別完整連結。模組名稱為 <code>NoCompileClient</code>。',
      pod1: '在 Podfile 裡只為 Debug 設定引入，然後 <code>pod install</code>：',
      pod2: 'Pod 會自動為 Debug 合併 <code>-Xlinker -interposable</code>，Release 不受影響。其他偵錯設定名稱（如 Dev）用 <code>project \'App\', \'Dev\' =&gt; :debug</code> 宣告。',
      cart1: 'Cartfile 加一行，然後建置 xcframework：',
      cart2: '把 <code>Carthage/Build/NoCompile.xcframework</code> 以 Embed &amp; Sign 加到 App target，再為 <b>Release</b> 等非偵錯設定加入排除：',
      bun1: '不引入任何依賴：在 App target 的 Build Phases 結尾加一個 Run Script，它會把對應平台的 bundle 複製進 App 並重新簽署（預設只在 Debug 設定生效）：',
      bun2: '在啟動時盡早載入，模擬器與實機寫法相同：',
      bun3: '也可以在專案目錄執行 <code>nocompile_setup.py</code> 自動完成以上整合，切換分支前用 <code>--remove</code> 原樣復原。',
      s3t: '選擇專案，執行 App', s3d: '在 Xcode 完整建置過一次後，點選單列 ⚡ → 選擇專案，再按 <kbd>⌘R</kbd> 執行 App。之後編輯任一原始碼檔案並儲存即可。',
      guide: '完整整合指南：Mac Catalyst、DYLD_INSERT_LIBRARIES、實機疑難排解 →',
      dlTitle: '下載 NoCompile',
      dlSub: '依晶片選擇安裝檔，拖進「應用程式」即可。安裝檔已通過 Apple 公證，之後透過 Sparkle 自動更新，只接收相同架構的更新。',
      dlArm2: 'Apple 晶片（M 系列）', dlIntel2: 'Intel 晶片',
      dlFine: '不確定晶片類型：蘋果選單 → 關於這台 Mac，「晶片」顯示 Apple M 系列選 arm64，顯示 Intel 選 x86_64。每個版本附有 <code>SHA256SUMS.txt</code> 供核對。',
      allReleases: '所有版本與更新說明',
      footAria: '頁尾連結', more: 'VanJay 的更多作品', feedback: '回報問題', license: '用戶端 SDK · MIT',
      demoTitle: ['你好，NoCompile', '儲存即生效 ⚡'], demoBtn: ['開始使用', '立即發佈'],
      demoLog: '注入 HomeViewController.swift 已生效（iPhone 模擬器）'
    }
  };

  // ---------- 語言 ----------
  function pickLang() {
    var q = query.get('lang');
    if (I18N[q]) {
      return q;
    }
    var saved = null;
    try {
      saved = localStorage.getItem('nc-lang');
    } catch (e) {}
    if (I18N[saved]) {
      return saved;
    }
    var list = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || 'en'];
    for (var i = 0; i < list.length; i++) {
      var l = String(list[i]).toLowerCase();
      if (/^zh-(tw|hk|mo)|^zh-hant/.test(l)) {
        return 'zh-TW';
      }
      if (l.indexOf('zh') === 0) {
        return 'zh-CN';
      }
      if (l.indexOf('en') === 0) {
        return 'en';
      }
    }
    return 'en';
  }

  var lang = pickLang();
  var T = I18N[lang];

  function setMeta(sel, val) {
    var m = document.querySelector(sel);
    if (m) {
      m.setAttribute('content', val);
    }
  }

  function applyLang(next, save) {
    lang = next;
    T = I18N[lang];
    doc.lang = lang;
    document.title = T.title;
    setMeta('meta[name="description"]', T.desc);
    setMeta('meta[property="og:title"]', T.title);
    setMeta('meta[property="og:description"]', T.ogDesc);
    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      var v = T[el.getAttribute('data-i18n')];
      if (typeof v === 'string') {
        el.innerHTML = v;
      }
    });
    document.querySelectorAll('[data-i18n-aria]').forEach(function (el) {
      var v = T[el.getAttribute('data-i18n-aria')];
      if (v) {
        el.setAttribute('aria-label', v);
        if (el.tagName === 'BUTTON') {
          el.setAttribute('title', v);
        }
      }
    });
    document.querySelectorAll('[data-i18n-alt]').forEach(function (el) {
      el.alt = T[el.getAttribute('data-i18n-alt')] || el.alt;
    });
    document.querySelectorAll('[data-lang]').forEach(function (b) {
      b.setAttribute('aria-pressed', String(b.getAttribute('data-lang') === lang));
    });
    if (save) {
      try {
        localStorage.setItem('nc-lang', lang);
      } catch (e) {}
    }
    renderDemo();
  }

  // ---------- 主題 ----------
  var themePref = doc.getAttribute('data-theme-pref') || 'system';

  function applyTheme() {
    var dark = themePref === 'dark' || (themePref === 'system' && darkMQ.matches);
    doc.setAttribute('data-theme', dark ? 'dark' : 'light');
    doc.setAttribute('data-theme-pref', themePref);
    setMeta('meta[name="theme-color"]', dark ? '#08070f' : '#f7f5fd');
    document.querySelectorAll('[data-theme-set]').forEach(function (b) {
      b.setAttribute('aria-pressed', String(b.getAttribute('data-theme-set') === themePref));
    });
  }

  document.querySelectorAll('[data-theme-set]').forEach(function (b) {
    b.addEventListener('click', function () {
      themePref = b.getAttribute('data-theme-set');
      try {
        localStorage.setItem('nc-theme', themePref);
      } catch (e) {}
      applyTheme();
    });
  });
  darkMQ.addEventListener('change', function () {
    if (themePref === 'system') {
      applyTheme();
    }
  });
  document.querySelectorAll('[data-lang]').forEach(function (b) {
    b.addEventListener('click', function () {
      applyLang(b.getAttribute('data-lang'), true);
    });
  });

  // ---------- 首屏演示：代碼改動 → 閃電 → 介面瞬變 ----------
  var stage = document.getElementById('stage');
  var canvas = document.getElementById('bolt');
  var ctx = canvas ? canvas.getContext('2d') : null;
  var $ = function (id) {
    return document.getElementById(id);
  };
  var COLORS = ['systemIndigo', 'systemYellow'];
  // 三行可编辑代码各自的当前取值（0 / 1 两种状态来回切换）
  var demo = [0, 0, 0];
  var typingLine = -1;

  function lineText(i, s) {
    if (i === 0) {
      return T.demoTitle[s];
    }
    if (i === 1) {
      return COLORS[s];
    }
    return T.demoBtn[s];
  }

  function renderPhoneLine(i) {
    if (i === 0) {
      $('p0').textContent = T.demoTitle[demo[0]];
    } else if (i === 1) {
      $('p1').setAttribute('data-c', demo[1] ? 'yellow' : 'indigo');
    } else {
      $('p2').textContent = T.demoBtn[demo[2]];
      $('p2').classList.toggle('alt', demo[2] === 1);
    }
  }

  function renderDemo() {
    if (!stage) {
      return;
    }
    for (var i = 0; i < 3; i++) {
      if (i !== typingLine) {
        $('v' + i).textContent = lineText(i, demo[i]);
      }
      renderPhoneLine(i);
    }
    $('logtext').textContent = T.demoLog;
  }

  // 可暂停的等待：首屏离开视口或页面隐藏时，动画循环停在当前步骤
  var active = true;
  var waiters = [];
  function setActive(v) {
    active = v;
    if (v) {
      waiters.splice(0).forEach(function (f) {
        f();
      });
    }
  }
  function sleep(ms) {
    return new Promise(function (r) {
      setTimeout(r, ms);
    }).then(function () {
      if (active) {
        return null;
      }
      return new Promise(function (r) {
        waiters.push(r);
      });
    });
  }

  // 画布尺寸跟随舞台
  var dpr = 1;
  function sizeCanvas() {
    if (!canvas) {
      return;
    }
    var r = stage.getBoundingClientRect();
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.height * dpr);
  }

  // 中点位移法生成锯齿闪电路径
  function boltPath(x1, y1, x2, y2, rough) {
    var pts = [[x1, y1], [x2, y2]];
    var disp = rough;
    for (var k = 0; k < 6; k++) {
      var next = [pts[0]];
      for (var i = 0; i < pts.length - 1; i++) {
        var a = pts[i], b = pts[i + 1];
        var dx = b[0] - a[0], dy = b[1] - a[1];
        var len = Math.hypot(dx, dy) || 1;
        var off = (Math.random() - 0.5) * disp;
        next.push([(a[0] + b[0]) / 2 - dy / len * off, (a[1] + b[1]) / 2 + dx / len * off]);
        next.push(b);
      }
      pts = next;
      disp *= 0.55;
    }
    return pts;
  }

  function strokePts(pts, upto) {
    ctx.beginPath();
    ctx.moveTo(pts[0][0], pts[0][1]);
    for (var i = 1; i < upto; i++) {
      ctx.lineTo(pts[i][0], pts[i][1]);
    }
    ctx.stroke();
  }

  // 一道闪电从改动的代码划到手机界面；onHit 在击中瞬间回调
  function strike(fromEl, toEl, onHit) {
    return new Promise(function (resolve) {
      sizeCanvas();
      var s = stage.getBoundingClientRect();
      var a = fromEl.getBoundingClientRect();
      var b = toEl.getBoundingClientRect();
      var stacked = b.top > a.bottom + 20 && Math.abs(b.left - a.left) < s.width / 3;
      var x1 = stacked ? a.left + a.width / 2 - s.left : a.right + 10 - s.left;
      var y1 = stacked ? a.bottom + 6 - s.top : a.top + a.height / 2 - s.top;
      var x2 = b.left + b.width / 2 - s.left;
      var y2 = b.top + b.height / 2 - s.top;
      var dist = Math.hypot(x2 - x1, y2 - y1);
      var main = boltPath(x1, y1, x2, y2, Math.min(150, dist * 0.32));
      var forks = [];
      for (var f = 0; f < 3; f++) {
        var at = main[Math.floor(main.length * (0.25 + Math.random() * 0.5))];
        var ang = Math.atan2(y2 - y1, x2 - x1) + (Math.random() - 0.5) * 1.6;
        var fl = dist * (0.12 + Math.random() * 0.14);
        forks.push(boltPath(at[0], at[1], at[0] + Math.cos(ang) * fl, at[1] + Math.sin(ang) * fl, fl * 0.5));
      }
      var dark = doc.getAttribute('data-theme') === 'dark';
      var t0 = performance.now();
      var DRAW = 150, HOLD = 90, FADE = 300;
      var hit = false;
      function frame(now) {
        var t = now - t0;
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        var p = Math.min(1, t / DRAW);
        var alpha = t < DRAW + HOLD ? 1 : Math.max(0, 1 - (t - DRAW - HOLD) / FADE);
        // 停留期间轻微闪烁
        if (t > DRAW && t < DRAW + HOLD && Math.floor(t / 30) % 2 === 1) {
          alpha = 0.55;
        }
        var upto = Math.max(2, Math.ceil(main.length * p));
        ctx.lineJoin = 'round';
        ctx.lineCap = 'round';
        ctx.globalCompositeOperation = dark ? 'lighter' : 'source-over';
        ctx.globalAlpha = alpha;
        // 外层紫色辉光
        ctx.shadowBlur = 28;
        ctx.shadowColor = dark ? 'rgba(168,85,247,.9)' : 'rgba(124,58,237,.6)';
        ctx.strokeStyle = dark ? 'rgba(168,85,247,.45)' : 'rgba(124,58,237,.35)';
        ctx.lineWidth = 12;
        strokePts(main, upto);
        // 中层电光黄
        ctx.shadowBlur = 18;
        ctx.shadowColor = 'rgba(255,214,10,.95)';
        ctx.strokeStyle = dark ? '#ffe14d' : '#ffc400';
        ctx.lineWidth = 4.5;
        strokePts(main, upto);
        if (p === 1) {
          ctx.lineWidth = 2;
          forks.forEach(function (fk) {
            strokePts(fk, fk.length);
          });
        }
        // 白色内芯
        ctx.shadowBlur = 0;
        ctx.strokeStyle = dark ? '#fffbe6' : '#fff7cc';
        ctx.lineWidth = 1.6;
        strokePts(main, upto);
        ctx.globalAlpha = 1;
        if (p === 1 && !hit) {
          hit = true;
          onHit();
        }
        if (t < DRAW + HOLD + FADE) {
          requestAnimationFrame(frame);
        } else {
          ctx.clearRect(0, 0, canvas.width, canvas.height);
          resolve();
        }
      }
      requestAnimationFrame(frame);
    });
  }

  // 计时徽标：0.00 → 0.30
  function countTimer() {
    var el = $('tval');
    var t0 = performance.now();
    var DUR = 300;
    $('timer').classList.add('on');
    function tick(now) {
      var p = Math.min(1, (now - t0) / DUR);
      el.textContent = (0.3 * p).toFixed(2);
      if (p < 1) {
        requestAnimationFrame(tick);
      } else {
        var tm = $('timer');
        tm.classList.add('pop');
        setTimeout(function () {
          tm.classList.remove('pop');
        }, 160);
      }
    }
    el.textContent = '0.00';
    requestAnimationFrame(tick);
  }

  async function typeLine(i, nextState) {
    var v = $('v' + i);
    typingLine = i;
    v.classList.add('typing');
    $('dirty').classList.add('on');
    var chars = Array.from(v.textContent);
    while (chars.length) {
      chars.pop();
      v.textContent = chars.join('');
      await sleep(28);
    }
    await sleep(160);
    var target = Array.from(lineText(i, nextState));
    for (var k = 0; k < target.length; k++) {
      v.textContent = target.slice(0, k + 1).join('');
      await sleep(i === 0 || i === 2 ? 70 : 45);
    }
    v.classList.remove('typing');
    typingLine = -1;
    // 语言可能在打字过程中切换，最终以当前语言为准
    v.textContent = lineText(i, nextState);
  }

  async function loop() {
    var order = [0, 1, 2];
    var n = 0;
    await sleep(900);
    for (;;) {
      var i = order[n % 3];
      var next = demo[i] ? 0 : 1;
      $('edlog').classList.remove('on');
      $('timer').classList.remove('on');
      await typeLine(i, next);
      await sleep(260);
      // ⌘S 保存
      var key = $('keycap');
      key.classList.add('on');
      await sleep(180);
      key.classList.add('press');
      $('dirty').classList.remove('on');
      await sleep(120);
      key.classList.remove('press');
      var v = $('v' + i);
      v.classList.add('hot');
      countTimer();
      await strike(v, $('p' + i), function () {
        demo[i] = next;
        renderPhoneLine(i);
        var fl = $('flash');
        fl.className = 'ph-flash on';
        $('screen').classList.add('hit');
        requestAnimationFrame(function () {
          requestAnimationFrame(function () {
            fl.className = 'ph-flash off';
            $('screen').classList.remove('hit');
          });
        });
        $('edlog').classList.add('on');
      });
      v.classList.remove('hot');
      key.classList.remove('on');
      await sleep(2000);
      n++;
    }
  }

  function startDemo() {
    if (!stage) {
      return;
    }
    if (reduceMQ.matches) {
      // 减少动态效果：直接展示改动后的静态结果
      demo = [1, 1, 1];
      renderDemo();
      $('tval').textContent = '0.30';
      $('timer').classList.add('on');
      $('edlog').classList.add('on');
      return;
    }
    var heroVisible = true;
    var update = function () {
      setActive(heroVisible && !document.hidden);
    };
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (es) {
        heroVisible = es[0].isIntersecting;
        update();
      }).observe(stage);
    }
    document.addEventListener('visibilitychange', update);
    window.addEventListener('resize', sizeCanvas);
    loop();
  }

  // ---------- 复制 ----------
  var toast = $('toast');
  var toastTimer = 0;
  function showToast(msg) {
    toast.textContent = msg;
    toast.classList.add('on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      toast.classList.remove('on');
    }, 1600);
  }
  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try {
      ok = document.execCommand('copy');
    } catch (e) {}
    document.body.removeChild(ta);
    return ok;
  }
  document.querySelectorAll('[data-copy]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var text = $(btn.getAttribute('data-copy')).textContent;
      var done = function (ok) {
        // 临时 textarea 会抢走焦点，复制后还给按钮
        btn.focus({ preventScroll: true });
        showToast(ok ? T.copied : T.copyFail);
        if (ok) {
          btn.classList.add('done');
          btn.textContent = '✓';
          setTimeout(function () {
            btn.classList.remove('done');
            btn.textContent = T.copy;
          }, 1400);
        }
      };
      // 先在点击的同步阶段用 execCommand 复制（各浏览器都可靠），失败再走异步剪贴板 API
      if (fallbackCopy(text)) {
        done(true);
      } else if (navigator.clipboard && window.isSecureContext) {
        // 剪贴板权限请求可能一直挂起，超时后给出失败提示
        var settled = false;
        var finish = function (ok) {
          if (!settled) {
            settled = true;
            done(ok);
          }
        };
        setTimeout(function () {
          finish(false);
        }, 1500);
        navigator.clipboard.writeText(text).then(function () {
          finish(true);
        }, function () {
          finish(false);
        });
      } else {
        done(false);
      }
    });
  });

  // ---------- 接入方式标签页 ----------
  var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
  function selectTab(tab, focus) {
    tabs.forEach(function (t) {
      var on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      $(t.getAttribute('aria-controls')).hidden = !on;
    });
    if (focus) {
      tab.focus();
    }
  }
  tabs.forEach(function (t, idx) {
    t.addEventListener('click', function () {
      selectTab(t, false);
    });
    t.addEventListener('keydown', function (e) {
      var d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (d) {
        e.preventDefault();
        selectTab(tabs[(idx + d + tabs.length) % tabs.length], true);
      }
    });
  });

  // ---------- 卡片光斑跟随指针 ----------
  document.querySelectorAll('.card').forEach(function (c) {
    c.addEventListener('pointermove', function (e) {
      var r = c.getBoundingClientRect();
      c.style.setProperty('--mx', (e.clientX - r.left) + 'px');
      c.style.setProperty('--my', (e.clientY - r.top) + 'px');
    });
  });

  // ---------- 滚动渐入 ----------
  var reveals = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !reduceMQ.matches) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.classList.add('in');
          io.unobserve(e.target);
        }
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    reveals.forEach(function (el) {
      io.observe(el);
    });
  } else {
    reveals.forEach(function (el) {
      el.classList.add('in');
    });
  }

  // ---------- 最新版本号（失败时保留页面里的默认值） ----------
  function showVersion(tag) {
    document.querySelectorAll('[data-version]').forEach(function (el) {
      el.textContent = tag;
    });
    document.querySelectorAll('[data-ver-plain]').forEach(function (el) {
      el.textContent = tag.replace(/^v/, '');
    });
  }
  (function () {
    var cached = null;
    try {
      cached = sessionStorage.getItem('nc-tag');
    } catch (e) {}
    if (cached) {
      showVersion(cached);
      return;
    }
    if (!window.fetch) {
      return;
    }
    fetch('https://api.github.com/repos/wangwanjie/NoCompile/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
      .then(function (r) {
        return r.ok ? r.json() : null;
      })
      .then(function (j) {
        if (j && /^v?\d+(\.\d+)+$/.test(j.tag_name || '')) {
          showVersion(j.tag_name);
          try {
            sessionStorage.setItem('nc-tag', j.tag_name);
          } catch (e) {}
        }
      })
      .catch(function () {});
  })();

  $('yr').textContent = String(new Date().getFullYear());
  applyTheme();
  applyLang(lang, false);
  startDemo();
})();
