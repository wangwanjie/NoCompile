#!/usr/bin/env bash
#
# 归档 NoCompile 菜单栏 App 为 Release .app，再用全局 create_pretty_dmg.sh 生成 DMG，可选公证。
#
# 用法:
#   ./Scripts/build_dmg.sh [--keychain-profile PROFILE] [--no-notarize] [--skip-archive]
# 默认使用 --keychain-profile "vanjay_mac_stapler" 公证；传入 --no-notarize 跳过。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="NoCompile"
PROJECT="App/NoCompile.xcodeproj"
CONFIGURATION="Release"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
ARCHIVE_PATH="$BUILD_DIR/NoCompile.xcarchive"
DMG_OUTPUT_DIR="$BUILD_DIR/dmg"
APP_ENTITLEMENTS="$PROJECT_DIR/App/NoCompile/NoCompile.entitlements"
KEYCHAIN_PROFILE="vanjay_mac_stapler"
DO_NOTARIZE=true
DO_ARCHIVE=true

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || { echo "错误: 未找到 $cmd" >&2; exit 1; }
}

current_signing_authority() {
    codesign -dv --verbose=4 "$1" 2>&1 \
        | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -1
}

# 从 keychain 里挑一个 Developer ID Application 身份。指定 team ID 优先匹配。
find_developer_id_identity() {
    local team_id="${1:-}"
    local matches
    matches="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application')"
    if [[ -z "$matches" ]]; then
        return 1
    fi
    if [[ -n "$team_id" ]]; then
        local hit
        hit="$(printf '%s\n' "$matches" | grep "($team_id)" | head -1)"
        if [[ -n "$hit" ]]; then
            printf '%s\n' "$hit" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(.*)"[[:space:]]*$/\1/'
            return 0
        fi
    fi
    printf '%s\n' "$matches" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(.*)"[[:space:]]*$/\1/'
}

verify_signature() {
    local target_path="$1" target_name="$2" sign_info
    sign_info="$(codesign -dv --verbose=4 "$target_path" 2>&1)"
    if ! grep -q "Authority=Developer ID Application" <<<"$sign_info"; then
        echo "错误: $target_name 未使用 Developer ID Application 签名" >&2
        echo "$sign_info" >&2
        exit 1
    fi
    if ! grep -q "Timestamp=" <<<"$sign_info"; then
        echo "错误: $target_name 签名缺少 secure timestamp" >&2
        exit 1
    fi
}

# codesign 带 --timestamp 时需要访问 Apple 时间戳服务，连续签名多个产物时偶发
# "The timestamp service is not available."，遇到该错误时退避重试
codesign_with_retry() {
    local attempt output
    for attempt in 1 2 3 4 5; do
        if output="$(/usr/bin/codesign "$@" 2>&1)"; then
            [[ -n "$output" ]] && echo "$output"
            return 0
        fi
        echo "$output" >&2
        if ! grep -q "timestamp service is not available" <<<"$output"; then
            return 1
        fi
        echo "时间戳服务暂不可用，$((attempt * 3)) 秒后重试（第 $attempt 次）..." >&2
        sleep $((attempt * 3))
    done
    return 1
}

resign_for_notarization() {
    local identity="$1" app_path="$2"
    local frameworks_dir="$app_path/Contents/Frameworks"

    echo "重新签名 Frameworks / Helper Bundles..."
    if [[ -d "$frameworks_dir" ]]; then
        # 先签 Sparkle 内部的 XPC / AutoUpdate.app / Helper 等
        while IFS= read -r -d '' bundle; do
            codesign_with_retry --force --sign "$identity" --timestamp --options runtime \
                --deep --preserve-metadata=entitlements "$bundle" || true
        done < <(find "$frameworks_dir" -type d \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -print0)
    fi

    # 客户端 bundle（供接入方加载，含 iOS / tvOS 产物）也必须带 Developer ID 签名才能通过公证
    while IFS= read -r -d '' bundle; do
        codesign_with_retry --force --sign "$identity" --timestamp --options runtime "$bundle"
    done < <(find "$app_path/Contents/Resources" -maxdepth 1 -type d -name "*NoCompile.bundle" -print0)

    local helper="$app_path/Contents/Helpers/nocompile"
    if [[ -f "$helper" ]]; then
        echo "重新签名命令行工具..."
        codesign_with_retry --force --sign "$identity" --timestamp --options runtime "$helper"
    fi

    echo "重新签名主 app..."
    codesign_with_retry --force --sign "$identity" --timestamp --options runtime \
        --entitlements "$APP_ENTITLEMENTS" \
        "$app_path"
}

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        --keychain-profile)
            KEYCHAIN_PROFILE="${2:?}"; shift 2 ;;
        --no-notarize)
            DO_NOTARIZE=false; shift ;;
        --skip-archive)
            DO_ARCHIVE=false; shift ;;
        -h|--help)
            grep '^#' "$0" | head -30
            exit 0 ;;
        *)
            echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

require_command xcodebuild
require_command codesign
require_command /usr/bin/plutil
require_command create_pretty_dmg.sh

cd "$PROJECT_DIR"

# 读取版本
PROJECT_YML="$PROJECT_DIR/App/project.yml"
VERSION=$(grep -m1 "MARKETING_VERSION:" "$PROJECT_YML" | sed 's/.*MARKETING_VERSION:[[:space:]]*//' | tr -d ' "')
if [[ -z "$VERSION" ]]; then
    echo "错误: 无法读取 MARKETING_VERSION" >&2
    exit 1
fi
echo "版本: $VERSION"

APP_PATH="$ARCHIVE_PATH/Products/Applications/NoCompile.app"

if [[ "$DO_ARCHIVE" == true ]]; then
    require_command xcodegen
    echo "生成 Xcode 工程..."
    (cd "$PROJECT_DIR/App" && xcodegen generate)
    echo "构建客户端 bundle..."
    "$PROJECT_DIR/Scripts/build-client-bundles.sh"
    echo "归档 $SCHEME (Release, arm64 + x86_64)..."
    rm -rf "$ARCHIVE_PATH"
    xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        clean archive
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "错误: 未找到构建产物 $APP_PATH" >&2
    exit 1
fi

# archive 出来通常是 adhoc / Apple Development 签名，公证必须换成 Developer ID Application。
SIGNING_AUTHORITY=""
if [[ "$DO_NOTARIZE" == true ]]; then
    SIGNING_AUTHORITY="$(current_signing_authority "$APP_PATH")"
    if [[ -z "$SIGNING_AUTHORITY" ]]; then
        # 读工程里的 DEVELOPMENT_TEAM 优先匹配
        TEAM_ID="$(grep -m1 'DEVELOPMENT_TEAM:' "$PROJECT_YML" | sed 's/.*DEVELOPMENT_TEAM:[[:space:]]*//' | tr -d ' "')"
        SIGNING_AUTHORITY="$(find_developer_id_identity "$TEAM_ID" || true)"
    fi
    if [[ -n "$SIGNING_AUTHORITY" ]]; then
        echo "使用签名身份: $SIGNING_AUTHORITY"
        resign_for_notarization "$SIGNING_AUTHORITY" "$APP_PATH"
        verify_signature "$APP_PATH" "NoCompile.app"
    else
        echo "错误: keychain 里找不到 Developer ID Application 身份，无法公证。" >&2
        echo "运行 security find-identity -v -p codesigning 检查。" >&2
        exit 1
    fi
else
    echo "跳过公证，保留 archive 原始签名。"
fi

# 用全局 create_pretty_dmg.sh 生成 DMG
mkdir -p "$DMG_OUTPUT_DIR"
echo "生成 DMG..."
create_pretty_dmg.sh \
    --app-path "$APP_PATH" \
    --dmg-name "NoCompile" \
    --append-version \
    --output-dir "$DMG_OUTPUT_DIR"

# 找刚生成的 DMG（形如 NoCompile_2.1.0.dmg）
DMG_PATH="$(ls -t "$DMG_OUTPUT_DIR"/NoCompile*.dmg 2>/dev/null | head -1)"
if [[ -z "$DMG_PATH" ]]; then
    echo "错误: 未找到生成的 DMG" >&2
    exit 1
fi
echo "DMG 已生成: $DMG_PATH"

# 公证
if [[ "$DO_NOTARIZE" == true && -n "$SIGNING_AUTHORITY" ]]; then
    echo "提交公证 (keychain-profile: $KEYCHAIN_PROFILE)..."
    NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait 2>&1) || true
    echo "$NOTARY_OUTPUT"
    if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
        echo "公证成功，正在钉合 (staple)..."
        xcrun stapler staple "$DMG_PATH"
        echo "公证并钉合完成。"
    else
        echo "公证未通过 (status 非 Accepted)。" >&2
        NOTARY_ID=$(echo "$NOTARY_OUTPUT" | sed -n 's/.*id:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
        [[ -n "$NOTARY_ID" ]] && echo "查看失败原因: xcrun notarytool log $NOTARY_ID --keychain-profile \"$KEYCHAIN_PROFILE\"" >&2
        exit 1
    fi
else
    echo "已跳过公证。"
fi

echo "完成。产物: $DMG_PATH"
