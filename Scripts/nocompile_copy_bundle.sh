#!/bin/bash
#
# nocompile_copy_bundle.sh
# 供接入方在 Xcode「Run Script」构建阶段调用：按当前平台把 NoCompile 客户端 bundle 拷进 App 并签名。
# 真机只能加载 App 包内、且与 App 同一身份签名的代码，所以真机走 bundle 方式时必须用它；模拟器 / macOS 也可以用。
#
# 用法（Build Phases → New Run Script Phase，放在最后）：
#   "/Applications/NoCompile.app/Contents/Resources/nocompile_copy_bundle.sh"
#
# 拷贝后在 App 资源目录里统一名为 NoCompile.bundle，各平台加载代码相同：
#   #if DEBUG
#   if let path = Bundle.main.path(forResource: "NoCompile", ofType: "bundle") {
#       Bundle(path: path)?.load()
#   }
#   #endif
#
# 可选环境变量（在 Run Script 里 export，或写进 Build Settings）：
#   NOCOMPILE_BUNDLES_DIR                  bundle 所在目录，默认为本脚本所在目录
#   NOCOMPILE_COPY_CONFIGURATIONS          允许拷贝的配置名，逗号分隔，默认只在名字含 Debug 的配置拷贝
#   NOCOMPILE_DISABLE_COPY=1               临时关闭拷贝
#
# 若 target 开启了 ENABLE_USER_SCRIPT_SANDBOXING，需要关闭它，或把 bundle 目录加到脚本的 Input Files。
#

set -euo pipefail

log() {
    echo "[NoCompile] $*"
}

if [ "${NOCOMPILE_DISABLE_COPY:-0}" = "1" ]; then
    log "NOCOMPILE_DISABLE_COPY=1，跳过"
    exit 0
fi

CONFIG="${CONFIGURATION:-}"
if [ -n "${NOCOMPILE_COPY_CONFIGURATIONS:-}" ]; then
    if [[ ",${NOCOMPILE_COPY_CONFIGURATIONS}," != *",${CONFIG},"* ]]; then
        log "配置 $CONFIG 不在 NOCOMPILE_COPY_CONFIGURATIONS 中，跳过"
        exit 0
    fi
elif [[ "$CONFIG" != *Debug* ]]; then
    # 默认只在 Debug 类配置拷贝，避免客户端进入 Release / 上架包
    log "配置 $CONFIG 不是 Debug，跳过"
    exit 0
fi

if [ "${IS_MACCATALYST:-NO}" = "YES" ]; then
    log "暂不支持 Mac Catalyst，跳过"
    exit 0
fi

case "${PLATFORM_NAME:-}" in
    macosx)           SOURCE_NAME="macOSNoCompile" ;;
    iphonesimulator)  SOURCE_NAME="iOSNoCompile" ;;
    iphoneos)         SOURCE_NAME="iOSDeviceNoCompile" ;;
    appletvsimulator) SOURCE_NAME="tvOSNoCompile" ;;
    appletvos)        SOURCE_NAME="tvOSDeviceNoCompile" ;;
    *)
        log "不支持的平台 ${PLATFORM_NAME:-未知}，跳过"
        exit 0
        ;;
esac

BUNDLES_DIR="${NOCOMPILE_BUNDLES_DIR:-$(cd "$(dirname "$0")" && pwd)}"
SOURCE="$BUNDLES_DIR/$SOURCE_NAME.bundle"
if [ ! -d "$SOURCE" ]; then
    echo "error: [NoCompile] 未找到 $SOURCE。请确认 NoCompile.app 版本支持 bundle 方式，或用 NOCOMPILE_BUNDLES_DIR 指定目录"
    exit 1
fi

# UNLOCALIZED_RESOURCES_FOLDER_PATH：iOS 为 X.app，macOS 为 X.app/Contents/Resources
DEST_DIR="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
DEST="$DEST_DIR/NoCompile.bundle"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$SOURCE" "$DEST"
log "已拷贝 $SOURCE_NAME.bundle → $DEST"

# 用与 App 相同的身份重签，真机与开启了库校验的 macOS App 才能加载；没有身份时用 ad-hoc
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] || [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
    IDENTITY="-"
fi
/usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$DEST"
log "已签名（$IDENTITY）"

# 提醒：缺少 -interposable 时函数级替换不会生效
if [[ " ${OTHER_LDFLAGS:-} " != *"-interposable"* ]]; then
    echo "warning: [NoCompile] 当前配置的 Other Linker Flags 未包含 -Xlinker -interposable，函数替换可能不生效"
fi
