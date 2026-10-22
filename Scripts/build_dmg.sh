#!/usr/bin/env bash
#
# 按架构分别归档 NoCompile 菜单栏 App 为 Release .app，再用全局 create_pretty_dmg.sh 生成 DMG，可选公证。
# 每个架构产出一个 DMG（如 NoCompile_v0.2.4_arm64.dmg），其 SUFeedURL 指向对应的 appcast-<arch>.xml。
#
# 用法:
#   ./Scripts/build_dmg.sh [--arch arm64|x86_64]... [--keychain-profile PROFILE] [--no-notarize] [--skip-archive]
# 默认同时构建 arm64 与 x86_64；--arch 可重复传入只构建指定架构。
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
DMG_OUTPUT_DIR="$BUILD_DIR/dmg"
APP_ENTITLEMENTS="$PROJECT_DIR/App/NoCompile/NoCompile.entitlements"
KEYCHAIN_PROFILE="vanjay_mac_stapler"
DO_NOTARIZE=true
DO_ARCHIVE=true
ARCHS_TO_BUILD=()
SUPPORTED_ARCHS=(arm64 x86_64)

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
        # 由内向外签名（find -depth 先列出子目录）：先签 Sparkle 内部的 XPC / Updater.app，再签外层 framework，
        # 否则后签的内层会破坏外层已经封好的签名。任一签名失败立即终止，不能留到公证阶段才发现
        while IFS= read -r -d '' bundle; do
            codesign_with_retry --force --sign "$identity" --timestamp --options runtime \
                --preserve-metadata=entitlements "$bundle"
        done < <(find "$frameworks_dir" -depth -type d \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -print0)
        # Sparkle 的 Autoupdate 是 framework 里的裸可执行文件，不属于上面任何一个包，单独签
        while IFS= read -r -d '' binary; do
            codesign_with_retry --force --sign "$identity" --timestamp --options runtime "$binary"
        done < <(find "$frameworks_dir" -type f -name "Autoupdate" -perm -u+x -print0)
        while IFS= read -r -d '' bundle; do
            codesign_with_retry --force --sign "$identity" --timestamp --options runtime \
                --preserve-metadata=entitlements "$bundle"
        done < <(find "$frameworks_dir" -maxdepth 1 -type d -name "*.framework" -print0)
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

# 把 App 自身代码与 Sparkle 等依赖精简为单一架构：xcodebuild 的 ARCHS 只作用于本工程的 target，
# SPM 预编译的 Sparkle.framework 仍是通用二进制。客户端 bundle（Contents/Resources/*.bundle）会被加载进
# 接入方任意架构、任意平台的 App，保持原样，不在精简范围内
thin_to_arch() {
    local app_path="$1" arch="$2" file archs
    while IFS= read -r -d '' file; do
        archs="$(lipo -archs "$file" 2>/dev/null || true)"
        if [[ -z "$archs" || "$archs" == "$arch" ]]; then
            continue
        fi
        if [[ " $archs " != *" $arch "* ]]; then
            echo "错误: $file 不含 $arch 架构（$archs）" >&2
            exit 1
        fi
        lipo -thin "$arch" "$file" -output "$file.thin"
        # 保留原文件权限（可执行位）
        chmod "$(stat -f '%Lp' "$file")" "$file.thin"
        mv "$file.thin" "$file"
    done < <(find "$app_path/Contents/MacOS" "$app_path/Contents/Helpers" "$app_path/Contents/Frameworks" \
                  -type f -print0 2>/dev/null)
}

# 校验 App 内（客户端 bundle 除外）每个 Mach-O 都只含目标架构
verify_single_arch() {
    local app_path="$1" arch="$2" file archs failed=0
    while IFS= read -r -d '' file; do
        archs="$(lipo -archs "$file" 2>/dev/null || true)"
        if [[ -n "$archs" && "$archs" != "$arch" ]]; then
            echo "错误: $file 的架构为 '$archs'，预期 '$arch'" >&2
            failed=1
        fi
    done < <(find "$app_path/Contents/MacOS" "$app_path/Contents/Helpers" "$app_path/Contents/Frameworks" \
                  -type f -print0 2>/dev/null)
    if [[ "$failed" -ne 0 ]]; then
        exit 1
    fi
}

# 校验随 App 分发的客户端 bundle：五个变体齐全，且版本与本次发布一致（防止打进上次遗留的旧客户端）
verify_client_bundles() {
    local app_path="$1" name plist bundle_version
    for name in macOSNoCompile iOSNoCompile iOSDeviceNoCompile tvOSNoCompile tvOSDeviceNoCompile; do
        plist="$app_path/Contents/Resources/$name.bundle/Info.plist"
        if [[ ! -f "$plist" ]]; then
            plist="$app_path/Contents/Resources/$name.bundle/Contents/Info.plist"
        fi
        if [[ ! -f "$plist" ]]; then
            echo "错误: App 中缺少客户端 bundle $name.bundle" >&2
            exit 1
        fi
        bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
        if [[ "$bundle_version" != "$VERSION" ]]; then
            echo "错误: $name.bundle 版本为 '$bundle_version'，预期 '$VERSION'" >&2
            exit 1
        fi
    done
}

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        --arch)
            ARCHS_TO_BUILD+=("${2:?}"); shift 2 ;;
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

if [[ ${#ARCHS_TO_BUILD[@]} -eq 0 ]]; then
    ARCHS_TO_BUILD=("${SUPPORTED_ARCHS[@]}")
fi
for arch in "${ARCHS_TO_BUILD[@]}"; do
    if [[ " ${SUPPORTED_ARCHS[*]} " != *" $arch "* ]]; then
        echo "错误: 不支持的架构 $arch（可选: ${SUPPORTED_ARCHS[*]}）" >&2
        exit 1
    fi
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
echo "版本: $VERSION，架构: ${ARCHS_TO_BUILD[*]}"
# App、客户端工程、podspec、两端协议常量的版本号必须一致
"$PROJECT_DIR/Scripts/bump_version.sh" --check

# 公证需要的 Developer ID 身份，在第一个架构签名时确定，后续架构复用
SIGNING_AUTHORITY=""

if [[ "$DO_ARCHIVE" == true ]]; then
    require_command xcodegen
    echo "生成 Xcode 工程..."
    (cd "$PROJECT_DIR/App" && xcodegen generate)
    # 客户端 bundle 会被加载进接入方的 App，接入方可能是任一架构，因此始终构建通用版本；发布包必须五个变体齐全
    echo "构建客户端 bundle..."
    "$PROJECT_DIR/Scripts/build-client-bundles.sh" --require-all
fi

# 归档、签名、打包并公证单个架构，产物路径写入全局 BUILT_DMGS
BUILT_DMGS=()
build_arch() {
    local arch="$1"
    local archive_path="$BUILD_DIR/NoCompile-$arch.xcarchive"
    local app_path="$archive_path/Products/Applications/NoCompile.app"

    echo "========== $arch =========="
    if [[ "$DO_ARCHIVE" == true ]]; then
        echo "归档 $SCHEME (Release, $arch)..."
        rm -rf "$archive_path"
        # NOCOMPILE_APPCAST_NAME 决定 Info.plist 里的 SUFeedURL，让各架构只收到同架构的更新
        xcodebuild -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration "$CONFIGURATION" \
            -derivedDataPath "$DERIVED_DATA" \
            -archivePath "$archive_path" \
            -destination "generic/platform=macOS" \
            ARCHS="$arch" \
            ONLY_ACTIVE_ARCH=NO \
            NOCOMPILE_APPCAST_NAME="appcast-$arch.xml" \
            clean archive
    fi

    if [[ ! -d "$app_path" ]]; then
        echo "错误: 未找到构建产物 $app_path" >&2
        exit 1
    fi

    # --skip-archive 复用旧归档时，归档的版本可能与 project.yml 不一致，DMG 文件名就会标错版本
    local app_version
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
    if [[ "$app_version" != "$VERSION" ]]; then
        echo "错误: 归档中 App 版本为 '$app_version'，与 project.yml 的 '$VERSION' 不一致，请去掉 --skip-archive 重新归档" >&2
        exit 1
    fi
    verify_client_bundles "$app_path"

    # 精简为单一架构后逐个校验：主程序、命令行工具、Sparkle 都只能含目标架构
    thin_to_arch "$app_path" "$arch"
    verify_single_arch "$app_path" "$arch"
    local feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app_path/Contents/Info.plist")"
    if [[ "$feed_url" != *"/appcast-$arch.xml" ]]; then
        echo "错误: SUFeedURL 为 '$feed_url'，预期指向 appcast-$arch.xml" >&2
        exit 1
    fi
    echo "SUFeedURL: $feed_url"

    # archive 出来通常是 adhoc / Apple Development 签名，公证必须换成 Developer ID Application。
    if [[ "$DO_NOTARIZE" == true ]]; then
        if [[ -z "$SIGNING_AUTHORITY" ]]; then
            SIGNING_AUTHORITY="$(current_signing_authority "$app_path")"
        fi
        if [[ -z "$SIGNING_AUTHORITY" ]]; then
            # 读工程里的 DEVELOPMENT_TEAM 优先匹配
            local team_id
            team_id="$(grep -m1 'DEVELOPMENT_TEAM:' "$PROJECT_YML" | sed 's/.*DEVELOPMENT_TEAM:[[:space:]]*//' | tr -d ' "')"
            SIGNING_AUTHORITY="$(find_developer_id_identity "$team_id" || true)"
        fi
        if [[ -n "$SIGNING_AUTHORITY" ]]; then
            echo "使用签名身份: $SIGNING_AUTHORITY"
            resign_for_notarization "$SIGNING_AUTHORITY" "$app_path"
            verify_signature "$app_path" "NoCompile.app ($arch)"
            # 严格校验整个包的签名（含嵌套代码），签名封印有问题时在这里就失败
            codesign --verify --deep --strict --verbose=2 "$app_path"
        else
            echo "错误: keychain 里找不到 Developer ID Application 身份，无法公证。" >&2
            echo "运行 security find-identity -v -p codesigning 检查。" >&2
            exit 1
        fi
    else
        # 精简架构改写了二进制，原签名已失效，用本机临时签名重签，保证本地能启动
        echo "跳过公证，使用临时签名（ad-hoc）重签。"
        codesign --force --deep --sign - --entitlements "$APP_ENTITLEMENTS" "$app_path"
    fi

    # 用全局 create_pretty_dmg.sh 生成 DMG，文件名带上版本与架构
    local dmg_name="NoCompile_v${VERSION}_${arch}"
    local dmg_path="$DMG_OUTPUT_DIR/$dmg_name.dmg"
    mkdir -p "$DMG_OUTPUT_DIR"
    rm -f "$dmg_path"
    echo "生成 DMG..."
    create_pretty_dmg.sh \
        --app-path "$app_path" \
        --dmg-name "$dmg_name" \
        --output-dir "$DMG_OUTPUT_DIR"
    if [[ ! -f "$dmg_path" ]]; then
        echo "错误: 未找到生成的 DMG $dmg_path" >&2
        exit 1
    fi
    echo "DMG 已生成: $dmg_path"

    # 公证
    if [[ "$DO_NOTARIZE" == true ]]; then
        echo "提交公证 (keychain-profile: $KEYCHAIN_PROFILE)..."
        local notary_output notary_id
        notary_output=$(xcrun notarytool submit "$dmg_path" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait 2>&1) || true
        echo "$notary_output"
        if echo "$notary_output" | grep -q "status: Accepted"; then
            echo "公证成功，正在钉合 (staple)..."
            xcrun stapler staple "$dmg_path"
            xcrun stapler validate "$dmg_path"
            echo "公证并钉合完成。"
        else
            echo "公证未通过 (status 非 Accepted)。" >&2
            notary_id=$(echo "$notary_output" | sed -n 's/.*id:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
            if [[ -n "$notary_id" ]]; then
                echo "查看失败原因: xcrun notarytool log $notary_id --keychain-profile \"$KEYCHAIN_PROFILE\"" >&2
            fi
            exit 1
        fi
    else
        echo "已跳过公证。"
    fi

    # 校验和，随 Release 一起上传，方便用户核对下载的文件
    (cd "$DMG_OUTPUT_DIR" && shasum -a 256 "$dmg_name.dmg" > "$dmg_name.dmg.sha256")

    BUILT_DMGS+=("$dmg_path")
}

for arch in "${ARCHS_TO_BUILD[@]}"; do
    build_arch "$arch"
done

echo "完成。产物:"
printf '  %s\n' "${BUILT_DMGS[@]}"
