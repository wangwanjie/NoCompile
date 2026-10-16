#!/bin/bash
#
# build-app.sh
# 用 SwiftPM 命令行构建 NoCompile 菜单栏 App，并打包成 NoCompile.app。
#
# 全程不经过 Xcode，因此可以和"引用了 NoCompile 本地包的 App 工程"同时使用，
# 避免 Xcode "同一个本地包不能被两个窗口打开" 的冲突。
#
# 用法：
#   Scripts/build-app.sh                 # 构建到 build/NoCompile.app
#   Scripts/build-app.sh --install       # 构建并安装到 /Applications
#   Scripts/build-app.sh --open          # 构建并启动
#   Scripts/build-app.sh --open --project /path/to/App.xcodeproj   # 构建、启动并直接监听该工程
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT/build"
APP="$OUTPUT_DIR/NoCompile.app"
# 独立的构建目录，不与 Xcode / 日常 swift build 的 .build 互相干扰
SCRATCH="$ROOT/.build-app"

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

echo "⚙️  构建 NoCompile（release）…"
swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --product NoCompileApp
swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --product nocompile
BIN_DIR="$(swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"

echo "📦 打包 NoCompile.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/NoCompileApp" "$APP/Contents/MacOS/NoCompile"
# 命令行工具一并放进 App，便于终端使用。
# 注意：macOS 文件系统默认不区分大小写，nocompile 与主程序 NoCompile 同名，不能放在同一目录
cp "$BIN_DIR/nocompile" "$APP/Contents/Helpers/nocompile"

VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.1.0")"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>NoCompile</string>
    <key>CFBundleDisplayName</key>
    <string>NoCompile</string>
    <key>CFBundleIdentifier</key>
    <string>com.nocompile.app</string>
    <key>CFBundleExecutable</key>
    <string>NoCompile</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <!-- 只在菜单栏显示，不占 Dock -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# ad-hoc 签名，保证在 Apple Silicon 上可直接运行
# 签名身份：优先用环境变量 NOCOMPILE_SIGN_IDENTITY，其次用钥匙串中的 Apple Development 证书，最后退回 ad-hoc。
# 用固定证书签名后，系统隐私授权（访问"文稿"等目录）只需授予一次；ad-hoc 签名每次重新打包都会被当作新 App 重新询问
SIGN_IDENTITY="${NOCOMPILE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" | head -1 | awk '{print $2}')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/nocompile" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null
echo "✅ 已生成：$APP（签名：$SIGN_IDENTITY）"
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
    echo "⚡ NoCompile 已启动，请查看菜单栏右上角的闪电图标"
fi
