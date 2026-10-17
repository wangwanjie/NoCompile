#
# manifest.py —— 端到端场景清单。
#
# 每个场景 = 若干步骤（steps）。步骤里先执行 edits（改文件 / 新建文件 / 拷贝文件），
# 再按 checks 判断 App 里的探针输出是否变化。
#
# 约定：源文件里有一个版本令牌 "@@v1@@"，默认把它改成 "@@v2@@"，期望探针输出里出现 N 次 "@@v2@@"。
#

V1 = "@@v1@@"
V2 = "@@v2@@"


def tok(sid, file, n=1, key=None, group=None, **extra):
    """最常见的场景：令牌 v1 → v2，探针输出里应出现 n 次 v2"""
    scenario = {
        "id": sid,
        "group": group,
        "steps": [{
            "edits": [{"file": file, "from": V1, "to": V2, "all": True}],
            "checks": [{"key": key or sid, "expect": {V2: n}}],
        }],
    }
    scenario.update(extra)
    return scenario


def custom(sid, file, old, new, expect, key=None, group=None, **extra):
    """自定义替换文本 + 自定义期望"""
    scenario = {
        "id": sid,
        "group": group,
        "steps": [{
            "edits": [{"file": file, "from": old, "to": new, "all": True}],
            "checks": [{"key": key or sid, "expect": expect}],
        }],
    }
    scenario.update(extra)
    return scenario


def copy_png(sid, files, source, signature, key=None, **extra):
    """用预置图片覆盖目标图片文件，期望探针里的像素签名变成 signature"""
    return {
        "id": sid,
        "steps": [{
            "edits": [{"file": f, "copyFrom": source} for f in files],
            "checks": [{"key": key or sid, "expect": {signature: 1}}],
        }],
        **extra,
    }


APP = "Scenarios"
MOD = "Modules"

SCENARIOS = [
    # ---- 原有示例 ----
    custom("E01", "Shared/SwiftGreeter.swift", "第 1 版", "第 2 版", {"第 2 版": 1}),
    custom("E02", "Shared/ObjCGreeter.m", "第 1 版", "第 2 版", {"第 2 版": 1}),
    custom("E03", "Shared/CGreeting.c", "第 1 版", "第 2 版", {"第 2 版": 1}),
    custom("E04", "Shared/CppCounter.cpp", "第 1 版", "第 2 版", {"第 2 版": 1}),
    custom("E05", "iOS/ObjCBadgeView.m", "第 1 版", "第 2 版", {"第 2 版": 1}),
    custom("E06", "iOS/DetailViewController.m", "这是 ObjC 写的页面", "这是 ObjC 写的页面 v2", {"页面 v2": 1}),

    # ---- A：Swift ----
    tok("A01", f"{APP}/Swift/A01SwiftFreeFunctions.swift"),
    tok("A02", f"{APP}/Swift/A02SwiftStruct.swift"),
    tok("A03", f"{APP}/Swift/A03SwiftClassVTable.swift", n=2),
    tok("A04", f"{APP}/Swift/A04SwiftFinalSingleton.swift", monotonic=[("A04", r"calls=(\d+)")]),
    tok("A05", f"{APP}/Swift/A05ExtensionModel+Extra.swift"),
    tok("A05b", f"{APP}/Swift/A05StringArrayExtension.swift"),
    tok("A05c", f"{APP}/Swift/A05UIKitExtension.swift"),
    custom("A05d", f"{APP}/Swift/A05UIKitExtension.swift", "green: 0.2,", "green: 0.8,", {"1ACC4D": 1}, key="A05c"),
    tok("A06", f"{APP}/Swift/A06ProtocolDefault.swift"),
    tok("A06b", f"{APP}/Swift/A06bProtocolWitness.swift", n=2),
    tok("A07", f"{APP}/Swift/A07SwiftGenerics.swift", n=2),
    tok("A08", f"{APP}/Swift/A08SwiftEnum.swift"),
    # lazy var 在第一次访问时已求值，不会随热重载重算，所以 v1 留 1 次
    custom("A09", f"{APP}/Swift/A09SwiftClosures.swift", V1, V2, {V2: 2, V1: 1}),
    tok("A10", f"{APP}/Swift/A10SwiftStaticState.swift", monotonic=[("A10", r"n=(\d+)"), ("A10", r"r=(\d+)")]),
    custom("A11", f"{APP}/Swift/A11SwiftPropertyWrapper.swift", "prefix(5)", "prefix(3)", {"A11:abc|": 1}),
    tok("A12", f"{APP}/Swift/A12SwiftCodable.swift"),
    tok("A13", f"{APP}/Swift/A13SwiftAsync.swift", monotonic=[("A13", r"n=(\d+)")]),
    tok("A14", f"{APP}/Swift/A14SwiftKVO.swift"),
    tok("A15", f"{APP}/Swift/A15SwiftOverrideObjC.swift"),
    tok("A16", f"{APP}/Swift/A16SwiftSyntaxSugar.swift"),
    tok("A17", f"{APP}/Swift/A17SwiftCombine.swift"),
    tok("A18", f"{APP}/Swift/A18SwiftUIView.swift", n=2),
    custom("A18b", f"{APP}/Swift/A18bSwiftUIRender.swift", "Color(red: 0.2,", "Color(red: 0.8,", {"red=CC": 1}),

    # ---- B：ObjC ----
    tok("B01", f"{APP}/ObjC/B01ObjCBasic.m"),
    tok("B02", f"{APP}/ObjC/B02ObjCHost+Extra.m"),
    tok("B03", f"{APP}/ObjC/B03NSStringCategory.m"),
    tok("B04", f"{APP}/ObjC/B04ObjCBlocks.m"),
    tok("B05", f"{APP}/ObjC/B05ObjCSingleton.m", monotonic=[("B05", r"hits=(\d+)"), ("B05", r"n=(\d+)")]),
    tok("B06", f"{APP}/ObjC/B06ObjCLoad.m", monotonic=[("B06", r"load=(\d+)"), ("B06", r"init=(\d+)")]),
    tok("B07", f"{APP}/ObjC/B07SwizzleHost.m"),
    tok("B08", f"{APP}/ObjC/B08ObjCTypes.m"),
    tok("B09", f"{APP}/ObjC/B09ObjCProperties.m"),
    tok("B10", f"{APP}/ObjC/B10CFunctionTable.m"),
    tok("B11", f"{APP}/ObjC/B11ObjCConstants.m"),
    tok("B12", f"{APP}/ObjC/B12ObjCConcurrency.m", monotonic=[("B12", r"ticks=(\d+)")], xfail="static 状态是一次性拷贝：启动时创建的定时器 block 仍是旧代码，继续写旧存储，新代码读到的是拷贝出来的快照"),
    tok("B13", f"{APP}/ObjC/B13ObjCException.m"),
    tok("B14", f"{APP}/ObjC/B14ObjCRuntime.m"),

    # ---- C：C / C++ ----
    tok("C01", f"{APP}/Cpp/C01Shape.cpp", n=2),
    tok("C02", f"{APP}/Cpp/C02Template.hpp"),
    tok("C03", f"{APP}/Cpp/C03Thrower.cpp", extra_expect_not=["base-only"], xfail="自定义 C++ 异常类型由新镜像抛出时 typeinfo 指针与旧镜像不同，旧镜像的 catch 只能按基类捕获（镜像内对 typeinfo 的引用是直接寻址，无法重绑）"),
    tok("C04", f"{APP}/Cpp/C04CPlain.c"),
    tok("C05", f"{APP}/Cpp/C05ObjCpp.mm", n=2),

    # ---- H：头文件 ----
    tok("H01", f"{APP}/Header/H01Macros.h", n=3),
    tok("H01b", f"{MOD}/ExCore/Public/ExMacros.h", n=2),
    {
        "id": "H02",
        "steps": [{
            "edits": [{"file": f"{APP}/Header/H02Inline.h", "from": V1, "to": V2, "all": True}],
            "checks": [{"key": "H02", "expect": {V2: 1}}, {"key": "H02b", "expect": {V2: 1}}],
        }],
    },
    tok("H02c", f"{MOD}/ExCore/Public/ExInline.h", n=2),
    custom("H03", f"{APP}/Header/H03Enums.h", "H03KindB = 2", "H03KindB = 3", {"kind=3": 1}),
    tok("H04", f"{APP}/Header/ExampleCommonPrefix.h"),
    custom("H06", f"{MOD}/ExCore/Public/ExConstants.h", "ExPlayModeShuffle,", "ExPlayModeShuffle = 9,", {"shuffle=9": 1}),
    tok("H07", f"{MOD}/ExPlayer/Sources/ExRingBuffer.hpp"),

    # ---- M：跨模块 ----
    tok("M01", f"{MOD}/ExCore/Private/ExLogger.m", monotonic=[("M01", r"lines=(\d+)")]),
    tok("M02", f"{MOD}/ExCore/Private/ExMath.c"),
    tok("M03", f"{MOD}/ExKit/Swift/ExFormatter.swift"),
    tok("M04", f"{APP}/Module/M04ListViewModelSubclass.swift", n=2),
    tok("M04b", f"{MOD}/ExKit/Swift/ExListViewModel.swift", key="M04b",
        xfail="framework 里的泛型 open class：已实例化的泛型元数据在运行时拷贝过 vtable，覆写不到"),
    tok("M05", f"{MOD}/ExKit/Private/ExBaseViewController.m"),
    tok("M06", f"{MOD}/ExKit/Private/ExObjCUser.m"),
    tok("M06b", f"{MOD}/ExKit/Swift/ExSwiftBridge.swift"),
    tok("M07", f"{MOD}/ExKit/Swift/ExService.swift"),
    tok("M07b", f"{APP}/Module/M07ServiceConformance.swift"),
    tok("M08", f"{MOD}/ExPlayer/Sources/ExPlayerEngine.mm", n=2),
    tok("M08c", f"{MOD}/ExPlayer/Sources/ExPlaylist.cpp"),
    tok("M08d", f"{MOD}/ExPlayer/Sources/ExAudioMath.c"),
    tok("M09", f"{MOD}/ExNetwork/Sources/ExNetwork/ExHTTPClient.swift"),
    tok("M09b", f"{MOD}/ExNetwork/Sources/ExNetwork/ExCache.swift"),
    tok("M10", f"{APP}/Module/Target_Player.m"),
    tok("M10b", f"{APP}/Module/M10MediatorTargets.swift"),
    # @inlinable 的函数体已被拷贝进调用方：只有 plain 能更新（期望 1 次），inlinable 仍是旧值
    tok("M11", f"{MOD}/ExKit/Swift/ExInlinable.swift", n=2),  # Debug(-Onone) 下 @inlinable 不会内联；Release 才有此限制
    tok("M12", f"{MOD}/ExKit/Swift/ExPlayerState.swift"),
    tok("M13", f"{MOD}/ExNetwork/Sources/ExNetwork/ExVersion.swift"),
    tok("M14", f"{MOD}/ExCore/Private/NSArray+ExSafe.m"),
    tok("M15", f"{MOD}/ExCore/Private/ExEventBus.m"),
    tok("M16", f"{MOD}/ExCore/Private/ExSwizzleTarget.m", monotonic=[("M16", r"load=(\d+)")]),
    tok("M17", f"{MOD}/ExCore/Private/ExConstants.m"),
    tok("M18", f"{MOD}/ExCore/Private/NSString+ExPath.m"),
    tok("M19", f"{MOD}/ExKit/Private/ExBadgeLabel.m"),
    tok("M20", f"{MOD}/ExKit/Private/ExCardCell.m"),
    custom("M21", f"{MOD}/ExKit/Swift/ExStyle.swift", "green: 0.45", "green: 0.85", {"accent=33D9F2": 1}),

    # ---- U：界面 ----
    tok("U01", f"{APP}/UI/U01ProfileViewController.swift"),
    tok("U02", f"{APP}/UI/U02ObjCViewController.m"),
    tok("U03", f"{APP}/UI/U03TableViewController.swift"),
    tok("U04", f"{APP}/UI/U04CollectionViewController.swift"),
    tok("U05", f"{APP}/UI/U05CustomView.swift"),
    tok("U06", f"{APP}/UI/U06ContainerViewController.swift"),
    tok("U08", f"{APP}/UI/U08NotificationObserver.swift", n=2),

    # ---- R：资源 ----
    tok("R01", "iOS/Base.lproj/StoryboardDemo.storyboard"),
    tok("R02", "iOS/XibDemoViewController.xib"),
    copy_png("R03", ["iOS/Assets.xcassets/DemoBadge.imageset/DemoBadge@2x.png", "iOS/Assets.xcassets/DemoBadge.imageset/DemoBadge@3x.png"],
             "E2E/assets/solid_0C2238.png", "0C2238"),
    copy_png("R04", ["iOS/Images/loose_icon@2x.png", "iOS/Images/loose_icon@3x.png"], "E2E/assets/solid_0C2238.png", "0C2238"),
    tok("R05", f"{MOD}/ExKit/Resources/ExKitBanner.xib"),
    tok("R06", f"{MOD}/ExKit/Resources/ExKit.strings"),
    tok("R07", f"{MOD}/ExKit/Resources/kit_config.json"),
    copy_png("R08", [f"{MOD}/ExKit/Resources/ExKit.xcassets/KitSquare.imageset/KitSquare@2x.png"], "E2E/assets/solid_0C2238.png", "0C2238"),
    tok("R09", f"{APP}/Resources/en.lproj/Localizable.strings"),
    tok("R10", f"{APP}/Resources/main_config.json"),
    custom("R11", "iOS/Assets.xcassets/ThemeColor.colorset/Contents.json", '"red" : "0x99"', '"red" : "0xAA"', {"AA6633": 1}),
    tok("R12", f"{APP}/Resources/XibCardView.xib"),
    custom("R13", f"{MOD}/ExKit/Resources/ExKitBanner.xib", 'red="0.10000000000000001"', 'red="0.60000000000000009"', {"99334D": 1}),

    # ---- S：结构变化 ----
    custom("S01", f"{APP}/Structural/S01AddObjCMethod.swift", "// S01-DECL",
           '@objc func extra() -> String {\n        return "S01-extra"\n    }', {"extra=S01-extra": 1}),
    {
        "id": "S02",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Structural/S02AddSwiftMethodFinal.swift", "from": "// S02-DECL",
                 "to": 'func extra() -> String {\n        return "S02-extra"\n    }'},
                {"file": f"{APP}/Structural/S02AddSwiftMethodFinal.swift", "from": "longLived.base() // S02-CALL",
                 "to": "longLived.base() + longLived.extra()"},
            ],
            "checks": [{"key": "S02", "expect": {"S02-base": 1, "S02-extra": 1}}],
        }],
    },
    {
        "id": "S03",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Structural/S03AddStoredProperty.swift", "from": "// S03-DECL", "to": "var age = 41"},
                {"file": f"{APP}/Structural/S03AddStoredProperty.swift", "from": "return name // S03-USE",
                 "to": 'return name + "-\\(age)"'},
            ],
            # 新建的实例用新布局，应读到 age；旧实例的布局已固定，只要求不崩溃
            "checks": [{"key": "S03", "expect": {"new[S03-name-41]": 1}}],
        }],
    },
    {
        "id": "S04",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Structural/S04AddObjCMethod.h", "from": "// S04-HDR", "to": "- (NSString *)extra;"},
                {"file": f"{APP}/Structural/S04AddObjCMethod.m", "from": "// S04-IMPL",
                 "to": "- (NSString *)extra {\n    return @\"S04-extra\";\n}"},
                {"file": f"{APP}/Structural/S04AddObjCMethod.m", "from": "[longLived base]; // S04-CALL", "to": "[longLived extra];"},
            ],
            "checks": [{"key": "S04", "expect": {"S04-extra": 1}}],
        }],
    },
    {
        "id": "S05",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Structural/S05AddObjCProperty.h", "from": "// S05-HDR",
                 "to": "@property (nonatomic, copy) NSString *extraName;"},
                {"file": f"{APP}/Structural/S05AddObjCProperty.m", "from": "return longLived.name; // S05-USE",
                 "to": "longLived.extraName = @\"S05-extra\";\n    return longLived.extraName ?: longLived.name;"},
            ],
            # 旧实例的 ivar 布局没有 extraName：能安全降级（不崩溃）即可，值不做要求
            "checks": [{"key": "S05", "expect": {}}],
            "settle": 6,
        }],
    },
    {
        "id": "S06",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Structural/S06AddEnumCase.swift", "from": "// S06-DECL", "to": "case pause"},
                {"file": f"{APP}/Structural/S06AddEnumCase.swift", "from": "// S06-CASE",
                 "to": 'case .pause:\n            return "pause"'},
                {"file": f"{APP}/Structural/S06AddEnumCase.swift", "from": "[.start, .stop(reason: \"r\")]",
                 "to": "[.start, .stop(reason: \"r\"), .pause]"},
            ],
            "checks": [{"key": "S06", "expect": {"pause": 1}}],
        }],
    },
    {
        "id": "S07",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Structural/S07ChangeSignatureCallee.swift", "from": "_ value: Int) -> String { // S07-SIG",
                 "to": "_ value: Int, extra: String) -> String {"},
                {"file": f"{APP}/Structural/S07ChangeSignatureCallee.swift", "from": 'return "S07-\\(value)" // S07-BODY',
                 "to": 'return "S07-\\(value)-\\(extra)"'},
                {"file": f"{APP}/Structural/S07ChangeSignatureCaller.swift", "from": "s07Compute(1) // S07-CALL",
                 "to": 's07Compute(1, extra: "x")'},
            ],
            "checks": [{"key": "S07", "expect": {"S07-1-x": 1}}],
        }],
    },
    {
        "id": "S08",
        "steps": [
            {
                "edits": [{"file": f"{APP}/Structural/S08NewFile.swift", "create":
                           "import Foundation\n\nenum S08Helper {\n    static func text() -> String {\n        return \"S08-new\"\n    }\n}\n"}],
                "checks": [],
                "settle": 5,
            },
            {
                "edits": [{"file": f"{APP}/Structural/S08NewFileHost.swift", "from": '"S08 base" // S08-CALL',
                           "to": '"S08 base " + S08Helper.text()'}],
                "checks": [{"key": "S08", "expect": {"S08-new": 1}}],
            },
        ],
        "cleanup": [f"{APP}/Structural/S08NewFile.swift"],
    },
    {
        "id": "S09",
        "steps": [
            {
                "edits": [
                    {"file": f"{APP}/Structural/S09NewClass.h", "create":
                     "#import <Foundation/Foundation.h>\n\n@interface S09NewClass : NSObject\n+ (NSString *)text;\n@end\n"},
                    {"file": f"{APP}/Structural/S09NewClass.m", "create":
                     "#import \"S09NewClass.h\"\n\n@implementation S09NewClass\n\n+ (NSString *)text {\n    return @\"S09-new\";\n}\n\n@end\n"},
                ],
                "checks": [{"key": "S09", "expect": {"S09-new": 1}}],
            },
        ],
        "cleanup": [f"{APP}/Structural/S09NewClass.h", f"{APP}/Structural/S09NewClass.m"],
    },
    {
        "id": "S10",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Structural/S10RemoveFunction.swift", "from": V1, "to": V2, "all": True},
                {"file": f"{APP}/Structural/S10RemoveFunction.swift",
                 "from": 'func s10Removable() -> String {\n    return "removable"\n}', "to": ""},
            ],
            "checks": [{"key": "S10", "expect": {V2: 1}}],
        }],
    },

    # ---- F：失败路径 ----
    {
        "id": "F01",
        "steps": [
            {   # 1) 故意写错：旧值保留，引擎要报错
                "edits": [{"file": f"{APP}/Failure/F01CompileErrorSwift.swift", "from": 'let value: String = "F01(@@v1@@)"',
                           "to": 'let value: String = 1 + "F01(@@v2@@)"'}],
                "checks": [{"key": "F01", "expect": {V1: 1}, "stay": True}],
                "expectLog": r"❌|失败|error",
                "settle": 6,
            },
            {   # 2) 修好：恢复热重载
                "edits": [{"file": f"{APP}/Failure/F01CompileErrorSwift.swift", "from": 'let value: String = 1 + "F01(@@v2@@)"',
                           "to": 'let value: String = "F01(@@v3@@)"'}],
                "checks": [{"key": "F01", "expect": {"@@v3@@": 1}}],
            },
        ],
    },
    {
        "id": "F02",
        "steps": [
            {
                "edits": [{"file": f"{APP}/Failure/F02CompileErrorObjC.m", "from": 'NSString *value = @"F02(@@v1@@)";',
                           "to": 'NSString *value = @"F02(@@v2@@)"'}],
                "checks": [{"key": "F02", "expect": {V1: 1}, "stay": True}],
                "expectLog": r"❌|失败|error",
                "settle": 6,
            },
            {
                "edits": [{"file": f"{APP}/Failure/F02CompileErrorObjC.m", "from": 'NSString *value = @"F02(@@v2@@)"',
                           "to": 'NSString *value = @"F02(@@v3@@)";'}],
                "checks": [{"key": "F02", "expect": {"@@v3@@": 1}}],
            },
        ],
    },
    {
        "id": "F03",
        "steps": [{
            "edits": [{"file": f"{APP}/Failure/F03CommentOnly.swift", "from": "// COMMENT-1", "to": "// COMMENT-2 只改了注释"}],
            "checks": [{"key": "F03", "expect": {V1: 1}, "stay": True}],
            "forbidLog": r"❌",
            "settle": 5,
        }],
    },
    {
        "id": "F04",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Failure/F04RapidSaves.swift", "from": V1, "to": V2, "all": True, "gap": 0.12},
                {"file": f"{APP}/Failure/F04RapidSaves.swift", "from": V2, "to": "@@v3@@", "all": True, "gap": 0.12},
                {"file": f"{APP}/Failure/F04RapidSaves.swift", "from": "@@v3@@", "to": "@@v4@@", "all": True},
            ],
            "checks": [{"key": "F04", "expect": {"@@v4@@": 1}}],
        }],
    },
    {
        "id": "F05",
        "steps": [{
            "edits": [
                {"file": f"{APP}/Failure/F05MultiFileA.swift", "from": V1, "to": V2, "all": True},
                {"file": f"{APP}/Failure/F05MultiFileB.m", "from": V1, "to": V2, "all": True},
                {"file": f"{APP}/Failure/F05MultiFileC.cpp", "from": V1, "to": V2, "all": True},
            ],
            "checks": [{"key": "F05", "expect": {V2: 3}}],
        }],
    },
    {
        "id": "Z01",
        "steps": [
            {
                "edits": [{"file": f"{APP}/Failure/Z01CrossFileLib.swift", "from": V1, "to": V2, "all": True}],
                "checks": [{"key": "Z01", "expect": {V2: 1}}],
            },
            {   # 再改调用方：新 dylib 里的 z01Lib 引用必须指向上一步注入的最新实现，而不是 App 里的原始版本
                "edits": [{"file": f"{APP}/Failure/Z01CrossFileCaller.swift", "from": '"caller:"', "to": '"caller2:"'}],
                "checks": [{"key": "Z01", "expect": {"caller2:lib(" + V2: 1}}],
            },
        ],
    },
    {
        "id": "F06",
        "steps": [{
            "edits": [{"file": f"{APP}/NotInTarget/F06NotInTarget.swift", "from": V1, "to": V2, "all": True}],
            "checks": [],
            "settle": 5,
            "forbidLog": r"崩溃|Fatal",
        }],
    },
]
