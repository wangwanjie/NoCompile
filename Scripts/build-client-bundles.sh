#!/bin/bash
#
# build-client-bundles.sh
# 构建 InjectionIII 风格的客户端 bundle，供接入方免依赖加载（Bundle.load() / DYLD_INSERT_LIBRARIES / 拷贝进 App）。
# build-app.sh 与 build_dmg.sh 会先调用本脚本，产物随 NoCompile.app 放进 Contents/Resources。
#
# 产物（默认输出到 build/ClientBundles）：
#   macOSNoCompile.bundle        macOS
#   iOSNoCompile.bundle          iOS 模拟器
#   iOSDeviceNoCompile.bundle    iOS 真机（需由 nocompile_copy_bundle.sh 拷进 App 并重签）
#   tvOSNoCompile.bundle         tvOS 模拟器
#   tvOSDeviceNoCompile.bundle   tvOS 真机
#
# 用法：
#   Scripts/build-client-bundles.sh                     # 构建全部（未安装的 SDK 自动跳过）
#   Scripts/build-client-bundles.sh --output DIR        # 指定输出目录
#   Scripts/build-client-bundles.sh --only iOSNoCompile,macOSNoCompile   # 只构建指定 bundle
#   Scripts/build-client-bundles.sh --require-all       # 缺少任一 SDK 即失败（发布打包使用）
#
# 输出目录里只保留本次构建的 bundle：用 --only 时，未列出的 bundle 会被删除，
# 防止 App 的 Embed Client Bundles 阶段把上次遗留的旧版客户端一起打包。
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Client/NoCompileClient.xcodeproj"
OUTPUT="$ROOT/build/ClientBundles"
WORK="$ROOT/build/ClientBundlesBuild"
ONLY=""
REQUIRE_ALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --output)
            shift
            OUTPUT="${1:?缺少输出目录}"
            ;;
        --only)
            shift
            ONLY="${1:?缺少 bundle 名}"
            ;;
        --require-all)
            REQUIRE_ALL=1
            ;;
        -h|--help)
            grep '^#' "$0" | head -20
            exit 0
            ;;
        *)
            echo "未知参数：$1"
            exit 1
            ;;
    esac
    shift
done

if [ ! -d "$PROJECT" ]; then
    command -v xcodegen >/dev/null 2>&1 || { echo "错误：未找到 $PROJECT，且没有 xcodegen 可以生成它"; exit 1; }
    (cd "$ROOT/Client" && xcodegen generate >/dev/null)
fi

mkdir -p "$OUTPUT"
# 清掉不在本次构建范围内的旧产物（见文件头说明）
if [ -n "$ONLY" ]; then
    for EXISTING in "$OUTPUT"/*.bundle; do
        [ -e "$EXISTING" ] || continue
        EXISTING_NAME="$(basename "$EXISTING" .bundle)"
        if [[ ",$ONLY," != *",$EXISTING_NAME,"* ]]; then
            rm -rf "$EXISTING"
        fi
    done
fi

# 每行：bundle 名  target  SDK
VARIANTS="
macOSNoCompile       NoCompileBundle-macOS  macosx
iOSNoCompile         NoCompileBundle-iOS    iphonesimulator
iOSDeviceNoCompile   NoCompileBundle-iOS    iphoneos
tvOSNoCompile        NoCompileBundle-tvOS   appletvsimulator
tvOSDeviceNoCompile  NoCompileBundle-tvOS   appletvos
"

BUILT=0
while read -r NAME TARGET SDK; do
    if [ -z "$NAME" ]; then
        continue
    fi
    if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$NAME,"* ]]; then
        continue
    fi
    # 没装对应平台（例如 tvOS）时跳过，不影响其他产物
    if ! xcrun --sdk "$SDK" --show-sdk-path >/dev/null 2>&1; then
        if [ "$REQUIRE_ALL" -eq 1 ]; then
            echo "❌ 未安装 $SDK SDK，无法构建 $NAME（发布包必须包含全部客户端 bundle）"
            exit 1
        fi
        # 删掉上次留下的同名产物，避免把旧版客户端打进 App
        rm -rf "$OUTPUT/$NAME.bundle"
        echo "⏭  未安装 $SDK SDK，跳过 $NAME"
        continue
    fi

    echo "⚙️  构建 $NAME.bundle（$SDK）…"
    LOG="$WORK/$NAME.log"
    mkdir -p "$WORK"
    # 产物只用于调试；不在这里签名，由拷贝方（App 打包 / nocompile_copy_bundle.sh）按需签名
    if ! xcodebuild -project "$PROJECT" \
        -target "$TARGET" \
        -configuration Release \
        -sdk "$SDK" \
        SYMROOT="$WORK/$NAME/Products" \
        OBJROOT="$WORK/$NAME/Intermediates" \
        PRODUCT_NAME="$NAME" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO \
        build >"$LOG" 2>&1; then
        grep -E "error:" "$LOG" || tail -20 "$LOG"
        echo "❌ $NAME 构建失败，完整日志：$LOG"
        exit 1
    fi

    PRODUCT="$(find "$WORK/$NAME/Products" -maxdepth 2 -type d -name "$NAME.bundle" | head -1)"
    if [ -z "$PRODUCT" ]; then
        echo "❌ 未找到 $NAME.bundle，完整日志：$LOG"
        exit 1
    fi
    rm -rf "$OUTPUT/$NAME.bundle"
    cp -R "$PRODUCT" "$OUTPUT/$NAME.bundle"
    BUILT=$((BUILT + 1))
done <<< "$VARIANTS"

# 拷贝脚本与 bundle 放在一起，接入方从同一目录调用
cp "$ROOT/Scripts/nocompile_copy_bundle.sh" "$OUTPUT/nocompile_copy_bundle.sh"
chmod +x "$OUTPUT/nocompile_copy_bundle.sh"

echo "✅ 已构建 $BUILT 个客户端 bundle：$OUTPUT"
