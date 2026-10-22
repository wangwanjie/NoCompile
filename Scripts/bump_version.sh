#!/usr/bin/env bash
#
# bump_version.sh
# 一次改齐发版需要同步的版本号，并把 App 的构建号加 1：
#   App/project.yml                       MARKETING_VERSION / CURRENT_PROJECT_VERSION
#   Client/project.yml                    MARKETING_VERSION
#   Client/NoCompileClient.xcodeproj      MARKETING_VERSION（已提交的工程，Carthage 使用）
#   NoCompile.podspec                     s.version
#   Sources/NoCompileKit/Protocol.swift   NCProtocol.clientVersion
#   Sources/NoCompileClient/NCProtocol.h  NC_CLIENT_VERSION
# 客户端修订号（clientRevision / NC_CLIENT_REVISION）只在两端交互不兼容时才手动递增，本脚本不改。
#
# 用法：
#   Scripts/bump_version.sh 0.3.0          # 设置版本号，构建号自动加 1
#   Scripts/bump_version.sh --check        # 只检查各处版本号是否一致（build_dmg.sh 打包前会调用）
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_YML="$ROOT/App/project.yml"
CLIENT_YML="$ROOT/Client/project.yml"
CLIENT_PBXPROJ="$ROOT/Client/NoCompileClient.xcodeproj/project.pbxproj"
PODSPEC="$ROOT/NoCompile.podspec"
PROTOCOL_SWIFT="$ROOT/Sources/NoCompileKit/Protocol.swift"
PROTOCOL_HEADER="$ROOT/Sources/NoCompileClient/NCProtocol.h"

# 各处当前的版本号，每行一个「来源<TAB>版本」
current_versions() {
    printf 'App/project.yml\t%s\n' "$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$APP_YML" | head -1)"
    printf 'Client/project.yml\t%s\n' "$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$CLIENT_YML" | head -1)"
    sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$CLIENT_PBXPROJ" | sort -u | while read -r v; do
        printf 'Client/NoCompileClient.xcodeproj\t%s\n' "$v"
    done
    printf 'NoCompile.podspec\t%s\n' "$(sed -n "s/.*s\.version[[:space:]]*=[[:space:]]*['\"]\([0-9.]*\)['\"].*/\1/p" "$PODSPEC" | head -1)"
    printf 'Protocol.swift\t%s\n' "$(sed -n 's/.*clientVersion: String = "\([0-9.]*\)".*/\1/p' "$PROTOCOL_SWIFT" | head -1)"
    printf 'NCProtocol.h\t%s\n' "$(sed -n 's/.*NC_CLIENT_VERSION @"\([0-9.]*\)".*/\1/p' "$PROTOCOL_HEADER" | head -1)"
}

check() {
    local versions distinct
    versions="$(current_versions)"
    distinct="$(printf '%s\n' "$versions" | cut -f2 | sort -u)"
    if [[ "$(printf '%s\n' "$distinct" | wc -l | tr -d ' ')" != "1" || -z "$distinct" ]]; then
        echo "❌ 版本号不一致：" >&2
        printf '%s\n' "$versions" | column -t -s $'\t' >&2
        return 1
    fi
    echo "✅ 版本号一致：$distinct"
}

if [[ "${1:-}" == "--check" ]]; then
    check
    exit $?
fi

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "用法：Scripts/bump_version.sh X.Y.Z | --check" >&2
    exit 1
fi

BUILD="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\([0-9]*\).*/\1/p' "$APP_YML" | head -1)"
NEXT_BUILD=$((BUILD + 1))

sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*).*/\1$VERSION/" "$APP_YML"
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*).*/\1$NEXT_BUILD/" "$APP_YML"
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*).*/\1$VERSION/" "$CLIENT_YML"
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $VERSION;/" "$CLIENT_PBXPROJ"
sed -i '' -E "s/(s\.version[[:space:]]*=[[:space:]]*')[0-9.]+(')/\1$VERSION\2/" "$PODSPEC"
sed -i '' -E "s/(clientVersion: String = \")[0-9.]+(\")/\1$VERSION\2/" "$PROTOCOL_SWIFT"
sed -i '' -E "s/(NC_CLIENT_VERSION @\")[0-9.]+(\")/\1$VERSION\2/" "$PROTOCOL_HEADER"

echo "版本号：$VERSION，构建号：$BUILD → $NEXT_BUILD"
check
