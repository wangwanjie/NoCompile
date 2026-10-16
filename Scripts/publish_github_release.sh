#!/usr/bin/env bash
#
# 上传 NoCompile DMG 到 GitHub Releases，并同步 appcast.xml。
# 默认上传 build/dmg/ 下最新的 NoCompile_*.dmg。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_DMG_DIR="$PROJECT_DIR/build/dmg"
PROJECT_YML="$PROJECT_DIR/App/project.yml"
INFO_PLIST="$PROJECT_DIR/App/NoCompile/Info.plist"

DMG_PATH=""
REPO=""
TAG=""
TITLE=""
NOTES=""
NOTES_FILE=""
GENERATE_NOTES=false
DRAFT=false
PRERELEASE=false

usage() {
    cat <<'EOF'
用法:
  ./Scripts/publish_github_release.sh [--dmg PATH] [--repo OWNER/REPO] [--tag TAG]
                                     [--title TITLE] [--notes TEXT | --notes-file FILE | --generate-notes]
                                     [--draft] [--prerelease]

前置:
  1. gh auth login 已完成，或 GITHUB_TOKEN 已配置
  2. build_dmg.sh 已生成 DMG
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || { echo "错误: 未找到 $1" >&2; exit 1; }
}

resolve_path() {
    local candidate="$1"
    [[ -z "$candidate" ]] && { echo ""; return 0; }
    if [[ ! "$candidate" = /* ]]; then
        if [[ -e "$candidate" ]]; then :
        elif [[ -e "$PROJECT_DIR/$candidate" ]]; then candidate="$PROJECT_DIR/$candidate"
        fi
    fi
    [[ ! -e "$candidate" ]] && { echo ""; return 0; }
    ( cd "$(dirname "$candidate")"; printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")" )
}

read_plist_string() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true
}

extract_github_repo_from_url() {
    local url="$1"
    # 剥掉尾部 /, .git，剥掉 https:// 或 git@ 前缀，再切 owner/repo。
    local stripped="${url%/}"
    stripped="${stripped%.git}"
    if [[ "$stripped" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
        printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0
    fi
    if [[ "$stripped" =~ ^git@github\.com:([^/]+)/([^/]+)$ ]]; then
        printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0
    fi
    return 1
}

detect_repo() {
    local remote_url
    remote_url="$(read_plist_string "NoCompileGitHubURL")"
    [[ -n "$remote_url" ]] && extract_github_repo_from_url "$remote_url" && return 0
    while IFS=$'\t' read -r _name candidate; do
        extract_github_repo_from_url "$candidate" && return 0
    done < <(git remote -v | awk '$3=="(push)" {print $1 "\t" $2}' | awk '!seen[$1]++')
    return 1
}

find_latest_dmg() {
    local latest="" mtime=0 fp
    shopt -s nullglob
    for fp in "$DEFAULT_DMG_DIR"/NoCompile*.dmg; do
        [[ -f "$fp" ]] || continue
        local m; m="$(stat -f '%m' "$fp")"
        if [[ -z "$latest" || "$m" -gt "$mtime" ]]; then latest="$fp"; mtime="$m"; fi
    done
    shopt -u nullglob
    printf '%s\n' "$latest"
}

infer_version_from_dmg() {
    local n raw
    n="$(basename "$1")"
    if [[ "$n" =~ ^NoCompile_(.+)\.dmg$ ]]; then
        raw="${BASH_REMATCH[1]}"
        printf '%s\n' "${raw#v}"
        return 0
    fi
    return 1
}

read_marketing_version() {
    grep -m1 "MARKETING_VERSION:" "$PROJECT_YML" | sed 's/.*MARKETING_VERSION:[[:space:]]*//' | tr -d ' "'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) DMG_PATH="${2:?}"; shift 2 ;;
        --repo) REPO="${2:?}"; shift 2 ;;
        --tag) TAG="${2:?}"; shift 2 ;;
        --title) TITLE="${2:?}"; shift 2 ;;
        --notes) NOTES="${2:?}"; shift 2 ;;
        --notes-file) NOTES_FILE="${2:?}"; shift 2 ;;
        --generate-notes) GENERATE_NOTES=true; shift ;;
        --draft) DRAFT=true; shift ;;
        --prerelease) PRERELEASE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -n "$NOTES" && -n "$NOTES_FILE" ]]; then
    echo "错误: --notes 和 --notes-file 二选一" >&2; exit 1
fi
if [[ "$GENERATE_NOTES" == true && ( -n "$NOTES" || -n "$NOTES_FILE" ) ]]; then
    echo "错误: --generate-notes 不能与 --notes/--notes-file 同时使用" >&2; exit 1
fi

require_command git
require_command gh

if ! gh auth status >/dev/null 2>&1; then
    echo "错误: gh 未登录，请先运行 gh auth login" >&2; exit 1
fi

if [[ -n "$DMG_PATH" ]]; then
    DMG_PATH="$(resolve_path "$DMG_PATH")"
else
    DMG_PATH="$(find_latest_dmg)"
fi
[[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]] && { echo "错误: 找不到 DMG。先跑 ./Scripts/build_dmg.sh" >&2; exit 1; }

if [[ -n "$NOTES_FILE" ]]; then
    NOTES_FILE="$(resolve_path "$NOTES_FILE")"
    [[ -z "$NOTES_FILE" || ! -f "$NOTES_FILE" ]] && { echo "错误: 找不到 notes 文件" >&2; exit 1; }
fi

[[ -z "$REPO" ]] && { REPO="$(detect_repo)" || { echo "错误: 无法推断 GitHub 仓库" >&2; exit 1; }; }

VERSION="$(infer_version_from_dmg "$DMG_PATH" 2>/dev/null || read_marketing_version)"
[[ -z "$VERSION" ]] && { echo "错误: 无法推断版本号" >&2; exit 1; }

[[ -z "$TAG" ]] && TAG="v$VERSION"
[[ -z "$TITLE" ]] && TITLE="NoCompile v$VERSION"

echo "仓库: $REPO"
echo "Tag:  $TAG"
echo "标题: $TITLE"
echo "DMG:  $DMG_PATH"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "Release 已存在，上传并覆盖同名资源..."
    gh release upload "$TAG" "$DMG_PATH" -R "$REPO" --clobber
else
    echo "创建 Release..."
    create_args=(release create "$TAG" "$DMG_PATH" -R "$REPO" --title "$TITLE")
    if [[ "$GENERATE_NOTES" == true ]]; then
        create_args+=(--generate-notes)
    elif [[ -n "$NOTES_FILE" ]]; then
        create_args+=(--notes-file "$NOTES_FILE")
    else
        create_args+=(--notes "${NOTES:-Release $TAG}")
    fi
    [[ "$DRAFT" == true ]] && create_args+=(--draft)
    [[ "$PRERELEASE" == true ]] && create_args+=(--prerelease)
    gh "${create_args[@]}"
fi

echo "完成: https://github.com/$REPO/releases/tag/$TAG"

APPCAST_NOTES="$(gh release view "$TAG" -R "$REPO" --json body --jq '.body // ""' 2>/dev/null || true)"

APPCAST_ARGS=(--repo "$REPO" --archive "$DMG_PATH")
[[ -n "$APPCAST_NOTES" ]] && APPCAST_ARGS+=(--notes "$APPCAST_NOTES")

"$PROJECT_DIR/Scripts/generate_appcast.sh" "${APPCAST_ARGS[@]}"

echo "appcast.xml 已更新，请提交并推送到默认分支。"
