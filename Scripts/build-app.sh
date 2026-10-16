#!/bin/bash
#
# build-app.sh
# 本地开发用：用 xcodebuild 构建 NoCompile 菜单栏 App（Release，本机签名），不涉及公证与发布。
# 发布请使用 Scripts/build_dmg.sh + Scripts/publish_github_release.sh。
#
# 全程命令行构建，可以和"以本地包方式引用 NoCompile 的 App 工程"同时在 Xcode 中打开，互不冲突。
#
# 用法：
#   Scripts/build-app.sh                 # 构建到 build/DerivedData/Build/Products/Release/NoCompile.app
#   Scripts/build-app.sh --install       # 构建并安装到 /Applications
#   Scripts/build-app.sh --open          # 构建并启动
#   Scripts/build-app.sh --open --project /path/to/App.xcodeproj   # 构建、启动并直接监听该工程
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/build/DerivedData"
APP="$DERIVED_DATA/Build/Products/Release/NoCompile.app"

INSTALL=0
OPEN=0
PROJECT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install)
            INSTALL=1
            ;;
        --open)
            OPEN=1
            ;;
        --project)
            shift
            PROJECT="${1:-}"
            ;;
        *)
            echo "未知参数：$1"
            exit 1
            ;;
    esac
    shift
done

command -v xcodegen >/dev/null 2>&1 || { echo "错误：未找到 xcodegen（brew install xcodegen）"; exit 1; }

echo "⚙️  生成 Xcode 工程…"
(cd "$ROOT/App" && xcodegen generate >/dev/null)

echo "⚙️  构建 NoCompile（Release）…"
xcodebuild -project "$ROOT/App/NoCompile.xcodeproj" \
    -scheme NoCompile \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "generic/platform=macOS" \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

if [ ! -d "$APP" ]; then
    echo "❌ 构建失败，未找到 $APP"
    exit 1
fi
echo "✅ 已生成：$APP"
echo "   命令行工具：$APP/Contents/Helpers/nocompile"

TARGET_APP="$APP"
if [ "$INSTALL" -eq 1 ]; then
    rm -rf "/Applications/NoCompile.app"
    cp -R "$APP" "/Applications/NoCompile.app"
    TARGET_APP="/Applications/NoCompile.app"
    echo "✅ 已安装到：$TARGET_APP"
fi

if [ "$OPEN" -eq 1 ]; then
    # 已有实例在运行时先退出，避免端口占用
    pkill -x NoCompile 2>/dev/null || true
    sleep 0.5
    if [ -n "$PROJECT" ]; then
        open "$TARGET_APP" --args --project "$PROJECT"
    else
        open "$TARGET_APP"
    fi
    echo "⚡ NoCompile 已启动"
fi
