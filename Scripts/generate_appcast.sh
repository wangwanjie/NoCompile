#!/usr/bin/env bash
#
# 根据归档 DMG 生成 Sparkle appcast.xml，并把 enclosure 改写为 GitHub Releases 下载地址。
#
# 用法:
#   ./Scripts/generate_appcast.sh [--arch arm64|x86_64] [--archive PATH] [--archives-dir DIR] [--output PATH]
#                                 [--repo OWNER/REPO] [--account ACCOUNT]
#                                 [--notes TEXT | --notes-file FILE]
#
# 传 --arch 时生成该架构专用的 appcast-<arch>.xml（归档目录为 build/appcast-archives/<arch>），
# 随后用两个架构的 feed 重建 appcast.xml，供 0.2.3 及更早的通用版用户升级到对应架构的版本。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_ARCHIVES_DIR="$PROJECT_DIR/build/appcast-archives"
DEFAULT_OUTPUT_PATH="$PROJECT_DIR/appcast.xml"
INFO_PLIST="$PROJECT_DIR/App/NoCompile/Info.plist"
DEFAULT_ACCOUNT="cn.vanjay.NoCompile.sparkle"

ARCH=""
ARCHIVE_PATH=""
ARCHIVES_DIR=""
OUTPUT_PATH=""
LEGACY_OUTPUT_PATH="$DEFAULT_OUTPUT_PATH"
REPO=""
ACCOUNT="$DEFAULT_ACCOUNT"
NOTES=""
NOTES_FILE=""

usage() {
    cat <<'EOF'
用法:
  ./Scripts/generate_appcast.sh [--arch arm64|x86_64] [--archive PATH] [--archives-dir DIR] [--output PATH]
                                [--repo OWNER/REPO] [--account ACCOUNT]
                                [--notes TEXT | --notes-file FILE]

选项:
  --arch ARCH          生成指定架构的 appcast-<arch>.xml，并据此重建兼容旧版的 appcast.xml
  --archive PATH       将当前版本 DMG 复制到归档目录后再生成 appcast
  --archives-dir DIR   保存历史 DMG 的目录，默认 build/appcast-archives（指定架构时为其下的 <arch> 子目录）
  --output PATH        输出路径，默认仓库根目录的 appcast.xml（指定架构时为 appcast-<arch>.xml）
  --repo OWNER/REPO    GitHub 仓库
  --account ACCOUNT    Sparkle EdDSA Keychain account，默认 cn.vanjay.NoCompile.sparkle
  --notes TEXT         为当前 archive 生成同名 .md 发布说明
  --notes-file FILE    为当前 archive 复制同名发布说明文件
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
    local stripped="${url%/}"
    stripped="${stripped%.git}"
    if [[ "$stripped" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
        printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$stripped" =~ ^git@github\.com:([^/]+)/([^/]+)$ ]]; then
        printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

detect_repo() {
    local repo_url
    repo_url="$(read_plist_string "NoCompileGitHubURL")"
    [[ -n "$repo_url" ]] && extract_github_repo_from_url "$repo_url" && return 0
    while IFS=$'\t' read -r _name candidate; do
        extract_github_repo_from_url "$candidate" && return 0
    done < <(git remote -v | awk '$3=="(push)" {print $1 "\t" $2}' | awk '!seen[$1]++')
    return 1
}

find_sparkle_bin_dir() {
    if [[ -n "${SPARKLE_BIN_DIR:-}" && -x "${SPARKLE_BIN_DIR}/generate_appcast" ]]; then
        printf '%s\n' "$SPARKLE_BIN_DIR"; return 0
    fi
    local local_bin="$PROJECT_DIR/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
    if [[ -x "$local_bin/generate_appcast" ]]; then
        printf '%s\n' "$local_bin"; return 0
    fi
    while IFS= read -r candidate; do
        if [[ -x "$candidate/generate_appcast" && -x "$candidate/generate_keys" ]]; then
            printf '%s\n' "$candidate"; return 0
        fi
    done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | sort -r)
    return 1
}

copy_release_notes() {
    local archive_dest="$1"
    local base_path="${archive_dest%.*}"
    if [[ -n "$NOTES_FILE" ]]; then
        cp "$NOTES_FILE" "${base_path}.${NOTES_FILE##*.}"
    elif [[ -n "$NOTES" ]]; then
        printf '%s\n' "$NOTES" > "${base_path}.md"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 ;;
        --archive) ARCHIVE_PATH="${2:-}"; shift 2 ;;
        --archives-dir) ARCHIVES_DIR="${2:-}"; shift 2 ;;
        --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
        --repo) REPO="${2:-}"; shift 2 ;;
        --account) ACCOUNT="${2:-}"; shift 2 ;;
        --notes) NOTES="${2:-}"; shift 2 ;;
        --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -n "$NOTES" && -n "$NOTES_FILE" ]]; then
    echo "错误: --notes 和 --notes-file 只能二选一" >&2; exit 1
fi

require_command /usr/bin/python3
require_command /usr/libexec/PlistBuddy

if [[ -n "$ARCH" && "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
    echo "错误: --arch 只支持 arm64 或 x86_64" >&2; exit 1
fi

# 按架构分开归档目录与输出文件，避免同版本的两个架构 DMG 混进同一个 feed
if [[ -z "$ARCHIVES_DIR" ]]; then
    if [[ -n "$ARCH" ]]; then
        ARCHIVES_DIR="$DEFAULT_ARCHIVES_DIR/$ARCH"
    else
        ARCHIVES_DIR="$DEFAULT_ARCHIVES_DIR"
    fi
fi
if [[ -z "$OUTPUT_PATH" ]]; then
    if [[ -n "$ARCH" ]]; then
        OUTPUT_PATH="$PROJECT_DIR/appcast-$ARCH.xml"
    else
        OUTPUT_PATH="$DEFAULT_OUTPUT_PATH"
    fi
fi

ARCHIVES_DIR="${ARCHIVES_DIR/#\~/$HOME}"
OUTPUT_PATH="${OUTPUT_PATH/#\~/$HOME}"

if [[ -n "$ARCHIVE_PATH" ]]; then
    ARCHIVE_PATH="$(resolve_path "$ARCHIVE_PATH")"
    if [[ -z "$ARCHIVE_PATH" || ! -f "$ARCHIVE_PATH" ]]; then
        echo "错误: 未找到 archive 文件" >&2; exit 1
    fi
fi

if [[ -n "$NOTES_FILE" ]]; then
    NOTES_FILE="$(resolve_path "$NOTES_FILE")"
    if [[ -z "$NOTES_FILE" || ! -f "$NOTES_FILE" ]]; then
        echo "错误: 未找到 notes 文件" >&2; exit 1
    fi
fi

if [[ -z "$REPO" ]]; then
    if ! REPO="$(detect_repo)"; then
        echo "错误: 无法推断 GitHub 仓库，请通过 --repo OWNER/REPO 指定" >&2; exit 1
    fi
fi

if ! [[ "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
    echo "错误: --repo 必须是 OWNER/REPO 格式" >&2; exit 1
fi

if ! SPARKLE_BIN_DIR="$(find_sparkle_bin_dir)"; then
    echo "错误: 未找到 Sparkle 工具，请先在 Xcode 里解析一次包依赖 (Product > Resolve Package Dependencies)" >&2
    exit 1
fi

if ! "$SPARKLE_BIN_DIR/generate_keys" --account "$ACCOUNT" -p >/dev/null 2>&1; then
    echo "错误: 未找到 Sparkle EdDSA 私钥。先运行以下命令生成一次:" >&2
    echo "  $SPARKLE_BIN_DIR/generate_keys --account $ACCOUNT" >&2
    exit 1
fi

mkdir -p "$ARCHIVES_DIR"

if [[ -n "$ARCHIVE_PATH" ]]; then
    archive_dest="$ARCHIVES_DIR/$(basename "$ARCHIVE_PATH")"
    cp "$ARCHIVE_PATH" "$archive_dest"
    copy_release_notes "$archive_dest"
fi

shopt -s nullglob
archives=( "$ARCHIVES_DIR"/*.dmg )
shopt -u nullglob

if [[ ${#archives[@]} -eq 0 ]]; then
    echo "错误: $ARCHIVES_DIR 中没有 DMG" >&2; exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nocompile-appcast.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$ARCHIVES_DIR"/*.dmg "$TMP_DIR/"
for notes_path in "$ARCHIVES_DIR"/*.md "$ARCHIVES_DIR"/*.txt "$ARCHIVES_DIR"/*.html; do
    [[ -e "$notes_path" ]] || continue
    cp "$notes_path" "$TMP_DIR/"
done

TMP_APPCAST="$TMP_DIR/appcast.xml"
# 不生成增量包：增量文件只落在临时目录、不会随 Release 上传，写进 appcast 会是失效链接
"$SPARKLE_BIN_DIR/generate_appcast" \
    --account "$ACCOUNT" \
    --maximum-deltas 0 \
    --link "https://github.com/$REPO" \
    -o "$TMP_APPCAST" \
    "$TMP_DIR"

/usr/bin/python3 - "$TMP_APPCAST" "$OUTPUT_PATH" "$REPO" "$TMP_DIR" "$ARCH" <<'PY'
import html
import pathlib
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

input_path, output_path, repo, archives_dir, arch = sys.argv[1:6]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
dc_ns = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", sparkle_ns)
ET.register_namespace("dc", dc_ns)

tree = ET.parse(input_path)
root = tree.getroot()
channel = root.find("channel")
if channel is None:
    raise SystemExit("appcast 中缺少 channel 节点")

def find_or_create(parent, tag):
    node = parent.find(tag)
    if node is None:
        node = ET.SubElement(parent, tag)
    return node

def replace_inline_markup(text):
    escaped = html.escape(text, quote=False)
    def replace_link(m):
        return f'<a href="{html.escape(m.group(2), quote=True)}">{m.group(1)}</a>'
    escaped = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", replace_link, escaped)
    escaped = re.sub(r"(?<!\*)\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(r"(?<!\*)\*([^*]+)\*", r"<em>\1</em>", escaped)
    escaped = re.sub(r"(?<![\"'>])(https?://[^\s<]+)",
                     lambda m: f'<a href="{html.escape(m.group(1), quote=True)}">{m.group(1)}</a>',
                     escaped)
    return escaped

def markdown_to_html(md):
    lines = md.replace("\r\n", "\n").split("\n")
    blocks, para, items, code = [], [], [], []
    in_code = False
    def flush_para():
        nonlocal para
        if para:
            body = "<br/>".join(replace_inline_markup(l.strip()) for l in para if l.strip())
            if body: blocks.append(f"<p>{body}</p>")
            para = []
    def flush_list():
        nonlocal items
        if items:
            body = "".join(f"<li>{replace_inline_markup(i)}</li>" for i in items)
            blocks.append(f"<ul>{body}</ul>")
            items = []
    def flush_code():
        nonlocal code
        if code:
            blocks.append(f"<pre><code>{html.escape(chr(10).join(code))}</code></pre>")
            code = []
    for raw in lines:
        line = raw.rstrip(); stripped = line.strip()
        if stripped.startswith("```"):
            flush_para(); flush_list()
            if in_code: flush_code()
            in_code = not in_code; continue
        if in_code:
            code.append(line); continue
        if not stripped:
            flush_para(); flush_list(); continue
        h = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if h:
            flush_para(); flush_list()
            blocks.append(f"<h{len(h.group(1))}>{replace_inline_markup(h.group(2).strip())}</h{len(h.group(1))}>")
            continue
        if re.fullmatch(r"[-*_]{3,}", stripped):
            flush_para(); flush_list(); blocks.append("<hr/>"); continue
        li = re.match(r"^[-*]\s+(.*)$", stripped)
        if li:
            flush_para(); items.append(li.group(1).strip()); continue
        flush_list(); para.append(line)
    flush_para(); flush_list()
    if in_code: flush_code()
    return "\n".join(blocks).strip()

def load_release_notes_html(filename):
    stem = pathlib.Path(filename).stem
    base = pathlib.Path(archives_dir) / stem
    for ext, fn in [(".html", None), (".md", markdown_to_html), (".txt", None)]:
        path = pathlib.Path(f"{base}{ext}")
        if path.exists():
            text = path.read_text(encoding="utf-8")
            if fn: return fn(text)
            if ext == ".html": return text.strip()
            return f"<div style=\"white-space: pre-wrap;\">{html.escape(text.strip())}</div>"
    return ""

title = find_or_create(channel, "title")
if not (title.text or "").strip(): title.text = "NoCompile Updates"
link = find_or_create(channel, "link"); link.text = f"https://github.com/{repo}"
desc = find_or_create(channel, "description")
if not (desc.text or "").strip(): desc.text = "NoCompile release feed."
lang = find_or_create(channel, "language")
if not (lang.text or "").strip(): lang.text = "en"

for item in channel.findall("item"):
    enclosure = item.find("enclosure")
    if enclosure is None: continue
    raw_url = enclosure.attrib.get("url", "")
    filename = pathlib.PurePosixPath(urllib.parse.urlparse(raw_url).path).name or pathlib.Path(raw_url).name
    if not filename: continue

    # 文件名形如 NoCompile_v0.2.4_arm64.dmg（按架构）或 NoCompile_v0.2.3.dmg（旧通用包）
    m = re.match(r"NoCompile_(.+?)(?:_(?:arm64|x86_64))?\.dmg$", filename)
    version = m.group(1) if m else None
    if version is None:
        sv = item.find(f"{{{sparkle_ns}}}shortVersionString")
        version = (sv.text or "").strip() if sv is not None else ""
    if not version:
        sv = item.find(f"{{{sparkle_ns}}}version")
        version = (sv.text or "").strip() if sv is not None else ""
    if not version:
        raise SystemExit(f"无法从 {filename} 推断版本号")
    version = version.lstrip("vV")
    tag = f"v{version}"
    enclosure.set("url", f"https://github.com/{repo}/releases/download/{urllib.parse.quote(tag, safe='')}/{urllib.parse.quote(filename, safe='')}")
    item_link = find_or_create(item, "link")
    item_link.text = f"https://github.com/{repo}/releases/tag/{urllib.parse.quote(tag, safe='')}"
    notes_html = load_release_notes_html(filename)
    if notes_html:
        find_or_create(item, "description").text = notes_html
    for tag_name in [f"{{{sparkle_ns}}}releaseNotesLink", f"{{{sparkle_ns}}}fullReleaseNotesLink"]:
        node = item.find(tag_name)
        if node is not None: item.remove(node)
    # arm64 包声明硬件要求，Intel 机器上的 Sparkle 会忽略该条目
    if arch == "arm64":
        find_or_create(item, f"{{{sparkle_ns}}}hardwareRequirements").text = "arm64"

ET.indent(tree, space="    ")
tree.write(output_path, encoding="utf-8", xml_declaration=True)
PY

echo "已生成 appcast: $OUTPUT_PATH"
echo "归档目录: $ARCHIVES_DIR"

# 按架构生成后，同步重建旧通用版读取的 appcast.xml
if [[ -n "$ARCH" ]]; then
    /usr/bin/python3 "$SCRIPT_DIR/merge_legacy_appcast.py" \
        "$LEGACY_OUTPUT_PATH" "$PROJECT_DIR/appcast-arm64.xml" "$PROJECT_DIR/appcast-x86_64.xml"
    echo "已重建兼容旧版的 appcast: $LEGACY_OUTPUT_PATH"
fi
