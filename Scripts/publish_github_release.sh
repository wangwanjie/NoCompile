#!/usr/bin/env bash
#
# 上传 NoCompile DMG 到 GitHub Releases，并同步 Sparkle appcast。
# 默认上传 build/dmg/ 下当前版本的各架构 DMG（NoCompile_vX.Y.Z_arm64.dmg / _x86_64.dmg），
# 并分别更新 appcast-arm64.xml、appcast-x86_64.xml 以及兼容旧通用版的 appcast.xml。
#
# 除带版本号的 DMG 外，还会上传：
#   NoCompile_arm64.dmg / NoCompile_x86_64.dmg  不带版本号的副本，README 用
#       https://github.com/<repo>/releases/latest/download/NoCompile_<arch>.dmg 作为固定的"最新版"下载地址
#   SHA256SUMS.txt                              所有 DMG 的校验和
# 发布说明末尾自动追加「下载」表格（按芯片区分的文件、大小与 SHA-256）。
#
# Release 的 tag 打在本地 HEAD 上（--target），要求 HEAD 已推送到远端，保证 tag 与 podspec 指向的代码一致。
# --draft / --prerelease 不更新正式 feed：草稿的下载地址对外是 404，预发布版不应推送给所有用户。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_DMG_DIR="$PROJECT_DIR/build/dmg"
PROJECT_YML="$PROJECT_DIR/App/project.yml"
INFO_PLIST="$PROJECT_DIR/App/NoCompile/Info.plist"

DMG_PATHS=()
REPO=""
TAG=""
TITLE=""
NOTES=""
NOTES_FILE=""
GENERATE_NOTES=false
DRAFT=false
PRERELEASE=false
ALLOW_SINGLE_ARCH=false

usage() {
    cat <<'EOF'
用法:
  ./Scripts/publish_github_release.sh [--dmg PATH]... [--repo OWNER/REPO] [--tag TAG]
                                     [--title TITLE] [--notes TEXT | --notes-file FILE | --generate-notes]
                                     [--draft] [--prerelease] [--allow-single-arch]

前置:
  1. gh auth login 已完成，或 GITHUB_TOKEN 已配置
  2. build_dmg.sh 已生成 DMG

--dmg 可重复传入；不传时取 build/dmg 下当前 MARKETING_VERSION 的各架构 DMG。
默认要求 arm64 与 x86_64 两个 DMG 齐全（只发一个架构，另一架构的用户就收不到更新）；
确实只发布单个架构时传 --allow-single-arch。
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

# 当前版本的各架构 DMG
find_version_dmgs() {
    local version="$1" fp
    shopt -s nullglob
    for fp in "$DEFAULT_DMG_DIR/NoCompile_v${version}_arm64.dmg" "$DEFAULT_DMG_DIR/NoCompile_v${version}_x86_64.dmg"; do
        if [[ -f "$fp" ]]; then
            printf '%s\n' "$fp"
        fi
    done
    shopt -u nullglob
}

infer_version_from_dmg() {
    local n raw
    n="$(basename "$1")"
    # 形如 NoCompile_v0.2.4_arm64.dmg 或旧通用包 NoCompile_v0.2.3.dmg
    if [[ "$n" =~ ^NoCompile_(.+)\.dmg$ ]]; then
        raw="${BASH_REMATCH[1]}"
        raw="${raw%_arm64}"
        raw="${raw%_x86_64}"
        printf '%s\n' "${raw#v}"
        return 0
    fi
    return 1
}

# 从文件名取架构，旧通用包返回空
infer_arch_from_dmg() {
    local n
    n="$(basename "$1")"
    if [[ "$n" =~ _(arm64|x86_64)\.dmg$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

read_marketing_version() {
    grep -m1 "MARKETING_VERSION:" "$PROJECT_YML" | sed 's/.*MARKETING_VERSION:[[:space:]]*//' | tr -d ' "'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) DMG_PATHS+=("${2:?}"); shift 2 ;;
        --repo) REPO="${2:?}"; shift 2 ;;
        --tag) TAG="${2:?}"; shift 2 ;;
        --title) TITLE="${2:?}"; shift 2 ;;
        --notes) NOTES="${2:?}"; shift 2 ;;
        --notes-file) NOTES_FILE="${2:?}"; shift 2 ;;
        --generate-notes) GENERATE_NOTES=true; shift ;;
        --draft) DRAFT=true; shift ;;
        --prerelease) PRERELEASE=true; shift ;;
        --allow-single-arch) ALLOW_SINGLE_ARCH=true; shift ;;
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

if [[ ${#DMG_PATHS[@]} -gt 0 ]]; then
    resolved=()
    for dmg in "${DMG_PATHS[@]}"; do
        path="$(resolve_path "$dmg")"
        if [[ -z "$path" || ! -f "$path" ]]; then
            echo "错误: 找不到 DMG $dmg" >&2; exit 1
        fi
        resolved+=("$path")
    done
    DMG_PATHS=("${resolved[@]}")
else
    while IFS= read -r dmg; do
        DMG_PATHS+=("$dmg")
    done < <(find_version_dmgs "$(read_marketing_version)")
    # 没有按架构的产物时退回旧行为：取最新的单个 DMG
    if [[ ${#DMG_PATHS[@]} -eq 0 ]]; then
        latest="$(find_latest_dmg)"
        if [[ -n "$latest" ]]; then
            DMG_PATHS=("$latest")
        fi
    fi
fi
if [[ ${#DMG_PATHS[@]} -eq 0 ]]; then
    echo "错误: 找不到 DMG。先跑 ./Scripts/build_dmg.sh" >&2; exit 1
fi

if [[ -n "$NOTES_FILE" ]]; then
    NOTES_FILE="$(resolve_path "$NOTES_FILE")"
    [[ -z "$NOTES_FILE" || ! -f "$NOTES_FILE" ]] && { echo "错误: 找不到 notes 文件" >&2; exit 1; }
fi

[[ -z "$REPO" ]] && { REPO="$(detect_repo)" || { echo "错误: 无法推断 GitHub 仓库" >&2; exit 1; }; }

VERSION="$(infer_version_from_dmg "${DMG_PATHS[0]}" 2>/dev/null || read_marketing_version)"
[[ -z "$VERSION" ]] && { echo "错误: 无法推断版本号" >&2; exit 1; }
# 一次只发布同一版本的 DMG
for dmg in "${DMG_PATHS[@]}"; do
    if [[ "$(infer_version_from_dmg "$dmg" 2>/dev/null || true)" != "$VERSION" ]]; then
        echo "错误: $dmg 与版本 $VERSION 不一致" >&2; exit 1
    fi
done

# 两个架构齐全才发布（--allow-single-arch 除外）
ARCHS_FOUND=()
for dmg in "${DMG_PATHS[@]}"; do
    arch="$(infer_arch_from_dmg "$dmg")"
    [[ -n "$arch" ]] && ARCHS_FOUND+=("$arch")
done
if [[ "$ALLOW_SINGLE_ARCH" != true ]]; then
    for required in arm64 x86_64; do
        if [[ " ${ARCHS_FOUND[*]:-} " != *" $required "* ]]; then
            echo "错误: 缺少 $required 的 DMG（只发布单个架构请传 --allow-single-arch）" >&2
            exit 1
        fi
    done
fi

[[ -z "$TAG" ]] && TAG="v$VERSION"
[[ -z "$TITLE" ]] && TITLE="NoCompile v$VERSION"

# tag 打在本地 HEAD 上，HEAD 必须已推送：否则 gh 会在远端默认分支的 HEAD 上建 tag，与本次构建的代码不一致
TARGET_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
git -C "$PROJECT_DIR" fetch --quiet origin 2>/dev/null || echo "警告: git fetch 失败，按本地记录的远端分支检查" >&2
if [[ -z "$(git -C "$PROJECT_DIR" branch -r --contains "$TARGET_COMMIT" 2>/dev/null)" ]]; then
    echo "错误: HEAD ($TARGET_COMMIT) 尚未推送到远端，请先 git push 再发布" >&2
    exit 1
fi

# 不带版本号的副本与校验和，放在临时目录里一起上传
ASSET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nocompile-release.XXXXXX")"
trap 'rm -rf "$ASSET_DIR"' EXIT
UPLOAD_PATHS=("${DMG_PATHS[@]}")
DOWNLOAD_TABLE=$'\n\n## 下载\n\n| 芯片 | 文件 | 大小 | SHA-256 |\n|---|---|---|---|\n'
for dmg in "${DMG_PATHS[@]}"; do
    arch="$(infer_arch_from_dmg "$dmg")"
    name="$(basename "$dmg")"
    sum="$(shasum -a 256 "$dmg" | awk '{print $1}')"
    size="$(du -h "$dmg" | awk '{print $1}')"
    printf '%s  %s\n' "$sum" "$name" >> "$ASSET_DIR/SHA256SUMS.txt"
    if [[ -n "$arch" ]]; then
        cp "$dmg" "$ASSET_DIR/NoCompile_$arch.dmg"
        UPLOAD_PATHS+=("$ASSET_DIR/NoCompile_$arch.dmg")
        chip="Apple 芯片（M 系列）"
        [[ "$arch" == "x86_64" ]] && chip="Intel"
        DOWNLOAD_TABLE+="| $chip | [$name](https://github.com/$REPO/releases/download/$TAG/$name) | $size | \`$sum\` |"$'\n'
    fi
done
UPLOAD_PATHS+=("$ASSET_DIR/SHA256SUMS.txt")
DOWNLOAD_TABLE+=$'\n不确定芯片类型：点击屏幕左上角的苹果菜单 → 关于本机，「芯片」一栏显示 Apple M 系列即选 arm64，显示 Intel 即选 x86_64。\n'

echo "仓库: $REPO"
echo "Tag:  $TAG"
echo "标题: $TITLE"
printf 'DMG:  %s\n' "${DMG_PATHS[@]}"
echo "提交: $TARGET_COMMIT"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "Release 已存在，上传并覆盖同名资源..."
    gh release upload "$TAG" "${UPLOAD_PATHS[@]}" -R "$REPO" --clobber
else
    echo "创建 Release..."
    create_args=(release create "$TAG" "${UPLOAD_PATHS[@]}" -R "$REPO" --title "$TITLE" --target "$TARGET_COMMIT")
    if [[ "$GENERATE_NOTES" == true ]]; then
        create_args+=(--generate-notes)
    else
        # 发布说明末尾追加下载表格
        BODY_FILE="$ASSET_DIR/notes.md"
        if [[ -n "$NOTES_FILE" ]]; then
            cat "$NOTES_FILE" > "$BODY_FILE"
        else
            printf '%s\n' "${NOTES:-Release $TAG}" > "$BODY_FILE"
        fi
        printf '%s' "$DOWNLOAD_TABLE" >> "$BODY_FILE"
        create_args+=(--notes-file "$BODY_FILE")
    fi
    [[ "$DRAFT" == true ]] && create_args+=(--draft)
    [[ "$PRERELEASE" == true ]] && create_args+=(--prerelease)
    gh "${create_args[@]}"
fi

echo "完成: https://github.com/$REPO/releases/tag/$TAG"

if [[ "$DRAFT" == true || "$PRERELEASE" == true ]]; then
    echo "草稿 / 预发布版本不更新 appcast（草稿的下载地址对外不可访问，预发布版不推送给所有用户）。"
    exit 0
fi

# 更新窗口里展示的发布说明：用原始说明，不带下载表格（Sparkle 已按架构选好安装包）
if [[ -n "$NOTES_FILE" ]]; then
    APPCAST_NOTES="$(cat "$NOTES_FILE")"
elif [[ -n "$NOTES" ]]; then
    APPCAST_NOTES="$NOTES"
else
    APPCAST_NOTES="$(gh release view "$TAG" -R "$REPO" --json body --jq '.body // ""' 2>/dev/null || true)"
fi

# 每个 DMG 更新所属架构的 appcast；按架构生成时 generate_appcast.sh 会同步重建 appcast.xml
for dmg in "${DMG_PATHS[@]}"; do
    APPCAST_ARGS=(--repo "$REPO" --archive "$dmg")
    arch="$(infer_arch_from_dmg "$dmg")"
    if [[ -n "$arch" ]]; then
        APPCAST_ARGS+=(--arch "$arch")
    fi
    if [[ -n "$APPCAST_NOTES" ]]; then
        APPCAST_ARGS+=(--notes "$APPCAST_NOTES")
    fi
    "$PROJECT_DIR/Scripts/generate_appcast.sh" "${APPCAST_ARGS[@]}"
done

# 自检：新条目的下载地址可以访问、长度与文件一致，否则用户点更新会失败
echo "校验 appcast 中本次发布的下载地址..."
VERIFY_FAILED=false
for dmg in "${DMG_PATHS[@]}"; do
    name="$(basename "$dmg")"
    url="https://github.com/$REPO/releases/download/$TAG/$name"
    expected="$(stat -f '%z' "$dmg")"
    status="$(curl -sIL -o /dev/null -w '%{http_code}' "$url" || true)"
    if [[ "$status" != "200" ]]; then
        echo "警告: $url 返回 $status" >&2
        VERIFY_FAILED=true
    fi
    for feed in "$PROJECT_DIR"/appcast*.xml; do
        if grep -q "$name" "$feed" && ! grep -q "length=\"$expected\"" "$feed"; then
            echo "警告: $(basename "$feed") 中 $name 的 length 与文件大小 $expected 不一致" >&2
            VERIFY_FAILED=true
        fi
    done
done
if [[ "$VERIFY_FAILED" == true ]]; then
    echo "appcast 自检未通过，请检查后再提交 appcast 文件。" >&2
    exit 1
fi

echo "appcast 已更新（appcast.xml / appcast-<arch>.xml），请提交并推送到默认分支。"
