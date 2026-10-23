#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
nocompile_setup.py：一键把 NoCompile（拷贝 bundle 方式）接入到本地工程，或把接入的改动原样撤掉。

这些改动只用于本地调试，不应提交。切换分支前先 --remove，切过去后再运行一次即可：

    # 在工程目录（含 .xcworkspace / .xcodeproj）里运行
    /Applications/NoCompile.app/Contents/Resources/nocompile_setup.py
    # 撤销全部改动（切分支前执行）
    /Applications/NoCompile.app/Contents/Resources/nocompile_setup.py --remove

会做三件事（只作用于 App 类型的 target，默认只改名字含 Debug 的配置）：
  1. Other Linker Flags 追加 -Xlinker -interposable；清空 EXPORTED_SYMBOLS_FILE（可用 --keep-exported-symbols 保留）；
  2. Build Phases 末尾加 Run Script「[NoCompile] Copy Bundle」调用 nocompile_copy_bundle.sh，
     并在这些配置里关闭 ENABLE_USER_SCRIPT_SANDBOXING（否则脚本读不到 NoCompile.app）；
  3. 在 AppDelegate 的 didFinishLaunching（iOS / tvOS）、applicationDidFinishLaunching（macOS）
     或 SwiftUI App 的 init 最前面插入加载 NoCompile.bundle 的代码，Swift / Objective-C 自动区分。
     加载代码各平台相同：拷贝脚本已按平台挑好 bundle；模拟器与 macOS 上 App 内没有 bundle 时，
     再回退到从 NoCompile.app 加载对应平台的 bundle。

所有改动都带标记：工程里的设置记录在 NOCOMPILE_SETUP_ADDED 中，源码插入在
「>>> NoCompile setup」与「<<< NoCompile setup」之间，--remove 依据标记还原，不影响其他改动。
重复运行是安全的，已接入的部分会跳过。

配合 CocoaPods 自动接入（适合每次切换分支都要 pod install 的工程）：
    nocompile_setup.py --install-pod-hook   # 在 Podfile 加 post_integrate 钩子，钩子可以提交给同事
    export IntegrateNoCompile=true          # 本机开关，写法同 Podfile 里的 integrateHotReload
    pod install                             # 钩子调用 --sync：开关为 true 时接入，否则撤销
钩子只引用 /Applications/NoCompile.app 内的脚本，未安装 NoCompile.app 时什么也不做；
本机可用环境变量 NOCOMPILE_SETUP_SCRIPT 临时指向其他位置的脚本。
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

DEFAULT_RESOURCES = "/Applications/NoCompile.app/Contents/Resources"
COPY_SCRIPT_NAME = "nocompile_copy_bundle.sh"
PHASE_NAME = "[NoCompile] Copy Bundle"
SETTING_MARK = "NOCOMPILE_SETUP_ADDED"
CODE_BEGIN = ">>> NoCompile setup"
CODE_END = "<<< NoCompile setup"
APP_PRODUCT_TYPE = "com.apple.product-type.application"
SOURCE_EXTS = (".swift", ".m", ".mm")
# pbxproj 中可以不加引号的字符（与 Xcode 的写法一致）
BARE_RE = re.compile(r"^[A-Za-z0-9_$/:.]+$")


def log(msg):
    print(msg)


def warn(msg):
    print("⚠️  " + msg)


def fail(msg):
    print("❌ " + msg, file=sys.stderr)
    sys.exit(1)


def pbx_quote(value):
    """按 pbxproj 规则给字符串加引号与转义。"""
    if value and BARE_RE.match(value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return '"' + escaped + '"'


def pbx_unquote(raw):
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        inner = raw[1:-1]
        return inner.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")
    return raw


# ---------------------------------------------------------------------------
# 定位工程
# ---------------------------------------------------------------------------

def projects_in_workspace(workspace):
    """解析 contents.xcworkspacedata，返回其中的 .xcodeproj（排除 Pods）。"""
    data = os.path.join(workspace, "contents.xcworkspacedata")
    if not os.path.exists(data):
        return []
    base = os.path.dirname(workspace)
    result = []

    def walk(node, group_dir):
        for child in node:
            location = child.get("location", "")
            kind, _, rel = location.partition(":")
            if kind == "group":
                path = os.path.join(group_dir, rel)
            elif kind == "container":
                path = os.path.join(base, rel)
            elif kind == "absolute":
                path = rel
            else:
                path = group_dir
            if child.tag == "Group":
                walk(child, path if rel else group_dir)
            elif child.tag == "FileRef" and path.endswith(".xcodeproj"):
                if os.path.basename(path) != "Pods.xcodeproj":
                    result.append(os.path.normpath(path))

    walk(ET.parse(data).getroot(), base)
    return result


def locate_projects(path):
    path = os.path.abspath(path)
    if path.endswith(".xcodeproj"):
        return [path]
    if path.endswith(".xcworkspace"):
        projects = projects_in_workspace(path)
        if not projects:
            fail("%s 中没有找到工程" % path)
        return projects
    if not os.path.isdir(path):
        fail("路径不存在：%s" % path)
    workspaces = sorted(n for n in os.listdir(path) if n.endswith(".xcworkspace"))
    if len(workspaces) == 1:
        return locate_projects(os.path.join(path, workspaces[0]))
    if len(workspaces) > 1:
        fail("目录下有多个 workspace（%s），请把要接入的那个作为参数传入" % "、".join(workspaces))
    projects = sorted(n for n in os.listdir(path) if n.endswith(".xcodeproj"))
    if len(projects) == 1:
        return [os.path.join(path, projects[0])]
    if len(projects) > 1:
        fail("目录下有多个工程（%s），请把要接入的那个作为参数传入" % "、".join(projects))
    fail("%s 下没有 .xcworkspace 或 .xcodeproj，请在工程目录运行或传入工程路径" % path)


def locate_resources(explicit):
    """bundle 与拷贝脚本所在目录：优先本脚本所在目录（即 NoCompile.app 内），否则用 /Applications。"""
    if explicit:
        return os.path.abspath(explicit)
    here = os.path.dirname(os.path.realpath(__file__))
    if os.path.exists(os.path.join(here, COPY_SCRIPT_NAME)) and os.path.isdir(os.path.join(here, "iOSNoCompile.bundle")):
        return here
    return DEFAULT_RESOURCES


# ---------------------------------------------------------------------------
# pbxproj 文本编辑
# ---------------------------------------------------------------------------

class Settings:
    """XCBuildConfiguration 的 buildSettings 块，按条目保存原文，未改动的条目原样写回。"""

    def __init__(self, text):
        self.entries = []  # [key, [lines]]
        lines = text.split("\n") if text else []
        i = 0
        while i < len(lines):
            line = lines[i]
            match = re.match(r'^\t\t\t\t("(?:[^"\\]|\\.)*"|[^\s=]+) = (.*)$', line)
            if not match:
                # 无法识别的行原样保留，挂在上一个条目后面
                if self.entries:
                    self.entries[-1][1].append(line)
                else:
                    self.entries.append([None, [line]])
                i += 1
                continue
            key = pbx_unquote(match.group(1))
            block = [line]
            if match.group(2) == "(":
                i += 1
                while i < len(lines):
                    block.append(lines[i])
                    if lines[i] == "\t\t\t\t);":
                        break
                    i += 1
            self.entries.append([key, block])
            i += 1

    def render(self):
        return "\n".join(line for _, block in self.entries for line in block)

    def find(self, key):
        for entry in self.entries:
            if entry[0] == key:
                return entry
        return None

    def keys(self):
        return [entry[0] for entry in self.entries if entry[0]]

    def scalar(self, key):
        entry = self.find(key)
        if not entry or len(entry[1]) != 1:
            return None
        raw = entry[1][0].split(" = ", 1)[1]
        return pbx_unquote(raw[:-1] if raw.endswith(";") else raw)

    def set_lines(self, key, block):
        entry = self.find(key)
        if entry:
            entry[1] = block
            return
        # Xcode 按键名排序保存，按序插入可减少 Xcode 重新保存时的 diff
        index = len(self.entries)
        for i, (other, _) in enumerate(self.entries):
            if other and other > key:
                index = i
                break
        self.entries.insert(index, [key, block])

    def set_scalar(self, key, value):
        self.set_lines(key, ["\t\t\t\t%s = %s;" % (pbx_quote(key), pbx_quote(value))])

    def remove(self, key):
        self.entries = [entry for entry in self.entries if entry[0] != key]


class PBXText:
    def __init__(self, path):
        self.path = path
        with open(path, "r", encoding="utf-8") as handle:
            self.text = handle.read()
        self.original = self.text

    def object_span(self, oid):
        match = re.search(r"^\t\t%s(?: /\*.*?\*/)? = \{\n" % re.escape(oid), self.text, re.M)
        if not match:
            return None
        end = self.text.find("\n\t\t};\n", match.end() - 1)
        if end < 0:
            return None
        return match.start(), end + len("\n\t\t};\n")

    def settings_span(self, config_id):
        span = self.object_span(config_id)
        if not span:
            fail("工程文件格式无法识别（找不到配置 %s），请先用 Xcode 打开并保存一次工程" % config_id)
        start = self.text.find("\t\t\tbuildSettings = {\n", span[0], span[1])
        if start < 0:
            fail("工程文件格式无法识别（配置 %s 没有 buildSettings）" % config_id)
        body_start = start + len("\t\t\tbuildSettings = {\n")
        body_end = self.text.find("\t\t\t};", body_start, span[1])
        return body_start, body_end

    def read_settings(self, config_id):
        start, end = self.settings_span(config_id)
        return Settings(self.text[start:end].rstrip("\n"))

    def write_settings(self, config_id, settings):
        start, end = self.settings_span(config_id)
        body = settings.render()
        self.text = self.text[:start] + (body + "\n" if body else "") + self.text[end:]

    def add_phase(self, target_id, phase_id, script):
        block = (
            "\t\t%s /* %s */ = {\n"
            "\t\t\tisa = PBXShellScriptBuildPhase;\n"
            "\t\t\talwaysOutOfDate = 1;\n"
            "\t\t\tbuildActionMask = 2147483647;\n"
            "\t\t\tfiles = (\n\t\t\t);\n"
            "\t\t\tinputFileListPaths = (\n\t\t\t);\n"
            "\t\t\tinputPaths = (\n\t\t\t);\n"
            "\t\t\tname = %s;\n"
            "\t\t\toutputFileListPaths = (\n\t\t\t);\n"
            "\t\t\toutputPaths = (\n\t\t\t);\n"
            "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            "\t\t\tshellPath = /bin/sh;\n"
            "\t\t\tshellScript = %s;\n"
            "\t\t};\n"
        ) % (phase_id, PHASE_NAME, pbx_quote(PHASE_NAME), pbx_quote(script))

        begin_mark = "/* Begin PBXShellScriptBuildPhase section */\n"
        end_mark = "/* End PBXShellScriptBuildPhase section */\n"
        begin = self.text.find(begin_mark)
        if begin < 0:
            # 没有该 section 时按 isa 名字排序插入新 section
            insert_at = None
            for match in re.finditer(r"^/\* Begin (\w+) section \*/\n", self.text, re.M):
                if match.group(1) > "PBXShellScriptBuildPhase":
                    insert_at = match.start()
                    break
            if insert_at is None:
                insert_at = self.text.find("\t};\n\trootObject")
                if insert_at < 0:
                    fail("工程文件格式无法识别（找不到 objects 结尾）")
                insert_at = self.text.rfind("\n", 0, insert_at) + 1
            section = "\n" + begin_mark + block + end_mark
            # 新 section 前后保持一个空行，与 Xcode 的格式一致
            self.text = self.text[:insert_at].rstrip("\n") + "\n" + section + "\n" + self.text[insert_at:].lstrip("\n")
        else:
            body_start = begin + len(begin_mark)
            body_end = self.text.find(end_mark, body_start)
            # 按 ID 排序插入
            insert_at = body_end
            for match in re.finditer(r"^\t\t([0-9A-Za-z_]+)(?: /\*.*?\*/)? = \{", self.text[body_start:body_end], re.M):
                if match.group(1) > phase_id:
                    insert_at = body_start + match.start()
                    break
            self.text = self.text[:insert_at] + block + self.text[insert_at:]

        span = self.object_span(target_id)
        start = self.text.find("\t\t\tbuildPhases = (\n", span[0], span[1])
        if start < 0:
            fail("工程文件格式无法识别（target %s 没有 buildPhases）" % target_id)
        end = self.text.find("\t\t\t);\n", start)
        line = "\t\t\t\t%s /* %s */,\n" % (phase_id, PHASE_NAME)
        self.text = self.text[:end] + line + self.text[end:]

    def remove_phase(self, phase_id):
        self.text = re.sub(r"^\t\t\t\t%s(?: /\*.*?\*/)?,\n" % re.escape(phase_id), "", self.text, flags=re.M)
        span = self.object_span(phase_id)
        if span:
            self.text = self.text[:span[0]] + self.text[span[1]:]
        # section 被删空时整段去掉（连同前面的空行）
        self.text = self.text.replace(
            "\n/* Begin PBXShellScriptBuildPhase section */\n/* End PBXShellScriptBuildPhase section */\n", "")

    def changed(self):
        return self.text != self.original

    def save(self):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(self.text)


# ---------------------------------------------------------------------------
# 链接参数与脚本沙盒
# ---------------------------------------------------------------------------

def parse_marks(value):
    marks = {}
    for item in (value or "").split(";"):
        if "|" in item:
            key, _, how = item.partition("|")
            marks[key] = how
    return marks


def format_marks(marks):
    return ";".join("%s|%s" % (key, how) for key, how in marks.items())


def ldflag_keys(settings):
    return [key for key in settings.keys() if key == "OTHER_LDFLAGS" or key.startswith("OTHER_LDFLAGS[")]


def exported_keys(settings):
    return [key for key in settings.keys() if key == "EXPORTED_SYMBOLS_FILE" or key.startswith("EXPORTED_SYMBOLS_FILE[")]


def apply_settings(settings, need_sandbox, project_settings=None, clear_exported=True):
    """给一个配置追加 -interposable，需要时关闭脚本沙盒、清空导出符号文件，返回做了哪些改动的描述。
    project_settings 是 project 级的同名配置，target 级经 $(inherited) 继承到 -interposable 时不再追加。"""
    marks = parse_marks(settings.scalar(SETTING_MARK))
    done = []
    keys = ldflag_keys(settings) or ["OTHER_LDFLAGS"]
    for key in keys:
        entry = settings.find(key)
        text = "\n".join(entry[1]) if entry else ""
        if "-interposable" in text:
            continue
        upper = project_settings.find(key) if project_settings else None
        if upper and "-interposable" in "\n".join(upper[1]) and (not entry or "$(inherited)" in text):
            continue
        if not entry:
            settings.set_lines(key, [
                "\t\t\t\t%s = (" % pbx_quote(key),
                '\t\t\t\t\t"$(inherited)",',
                '\t\t\t\t\t"-Xlinker",',
                '\t\t\t\t\t"-interposable",',
                "\t\t\t\t);",
            ])
            marks[key] = "created"
        elif len(entry[1]) > 1:
            entry[1][-1:-1] = ['\t\t\t\t\t"-Xlinker",', '\t\t\t\t\t"-interposable",']
            marks[key] = "array"
        else:
            head, _, raw = entry[1][0].partition(" = ")
            raw = raw[:-1] if raw.endswith(";") else raw
            quoted = raw.startswith('"')
            inner = raw[1:-1] if quoted else raw
            entry[1] = ['%s = "%s -Xlinker -interposable";' % (head, inner)]
            marks[key] = "str" if quoted else "bare"
        done.append("%s 追加 -Xlinker -interposable" % key)

    if need_sandbox and settings.scalar("ENABLE_USER_SCRIPT_SANDBOXING") != "NO" and "ENABLE_USER_SCRIPT_SANDBOXING" not in marks:
        original = settings.scalar("ENABLE_USER_SCRIPT_SANDBOXING")
        marks["ENABLE_USER_SCRIPT_SANDBOXING"] = original if original is not None else "-"
        settings.set_scalar("ENABLE_USER_SCRIPT_SANDBOXING", "NO")
        done.append("ENABLE_USER_SCRIPT_SANDBOXING = NO")

    # 导出符号文件（例如只导出 _main）会让注入的 dylib 找不到 App 里的符号，接入期间清空，原值记入标记
    if clear_exported:
        keys = exported_keys(settings)
        if not keys and project_settings and project_settings.scalar("EXPORTED_SYMBOLS_FILE"):
            keys = ["EXPORTED_SYMBOLS_FILE"]
        for key in keys:
            if key in marks:
                continue
            entry = settings.find(key)
            if entry is None:
                marks[key] = "created"
            elif settings.scalar(key):
                marks[key] = "=" + entry[1][0].split(" = ", 1)[1][:-1]
            else:
                continue
            settings.set_scalar(key, "")
            done.append("%s 清空" % key)

    if marks:
        settings.set_scalar(SETTING_MARK, format_marks(marks))
    return done


def remove_settings(settings):
    marks = parse_marks(settings.scalar(SETTING_MARK))
    if not marks:
        return False
    for key, how in marks.items():
        if key.startswith("EXPORTED_SYMBOLS_FILE"):
            if how == "created":
                settings.remove(key)
            else:
                # 按原文写回，引号与转义保持不变
                settings.set_lines(key, ["\t\t\t\t%s = %s;" % (pbx_quote(key), how[1:])])
            continue
        if key == "ENABLE_USER_SCRIPT_SANDBOXING":
            if how == "-":
                settings.remove(key)
            else:
                settings.set_scalar(key, how)
            continue
        entry = settings.find(key)
        if not entry:
            continue
        if how == "created":
            settings.remove(key)
        elif how == "array":
            lines = entry[1]
            for i in range(len(lines) - 2, 0, -1):
                if lines[i - 1].strip() == '"-Xlinker",' and lines[i].strip() == '"-interposable",':
                    del lines[i - 1:i + 1]
                    break
        else:
            head, _, raw = entry[1][0].partition(" = ")
            raw = raw[:-1] if raw.endswith(";") else raw
            inner = raw[1:-1] if raw.startswith('"') else raw
            if inner.endswith(" -Xlinker -interposable"):
                inner = inner[:-len(" -Xlinker -interposable")]
            value = inner if how == "bare" else '"%s"' % inner
            entry[1] = ["%s = %s;" % (head, value)]
    settings.remove(SETTING_MARK)
    return True


# ---------------------------------------------------------------------------
# 源码插入
# ---------------------------------------------------------------------------

def objc_snippet(indent, resources):
    lines = [
        "// %s（由 nocompile_setup.py 添加，请勿提交，撤销：nocompile_setup.py --remove）" % CODE_BEGIN,
        "{",
        "    // 拷贝脚本已按平台把客户端拷进 App，统一名为 NoCompile.bundle",
        "    NSString *nc_bundlePath = [[NSBundle mainBundle] pathForResource:@\"NoCompile\" ofType:@\"bundle\"];",
        "#if DEBUG && (TARGET_OS_SIMULATOR || TARGET_OS_OSX)",
        "    // 模拟器与 macOS 可直接访问 Mac 文件系统：App 内没有时从 NoCompile.app 加载对应平台的 bundle",
        "    if (!nc_bundlePath) {",
        "#if TARGET_OS_OSX",
        "        nc_bundlePath = @\"%s/macOSNoCompile.bundle\";" % resources,
        "#elif TARGET_OS_TV",
        "        nc_bundlePath = @\"%s/tvOSNoCompile.bundle\";" % resources,
        "#else",
        "        nc_bundlePath = @\"%s/iOSNoCompile.bundle\";" % resources,
        "#endif",
        "    }",
        "#endif",
        "    if (nc_bundlePath) {",
        "        [[NSBundle bundleWithPath:nc_bundlePath] load];",
        "    }",
        "}",
        "// %s" % CODE_END,
    ]
    return "".join((line if line.startswith("#") else indent + line) + "\n" for line in lines)


def swift_lines(resources):
    return [
        "do {",
        "    // 拷贝脚本已按平台把客户端拷进 App，统一名为 NoCompile.bundle",
        "    var ncBundlePath = Bundle.main.path(forResource: \"NoCompile\", ofType: \"bundle\")",
        "    #if DEBUG && (targetEnvironment(simulator) || os(macOS))",
        "    // 模拟器与 macOS 可直接访问 Mac 文件系统：App 内没有时从 NoCompile.app 加载对应平台的 bundle",
        "    if ncBundlePath == nil {",
        "        #if os(macOS)",
        "        ncBundlePath = \"%s/macOSNoCompile.bundle\"" % resources,
        "        #elseif os(tvOS)",
        "        ncBundlePath = \"%s/tvOSNoCompile.bundle\"" % resources,
        "        #else",
        "        ncBundlePath = \"%s/iOSNoCompile.bundle\"" % resources,
        "        #endif",
        "    }",
        "    #endif",
        "    if let ncBundlePath = ncBundlePath {",
        "        _ = Bundle(path: ncBundlePath)?.load()",
        "    }",
        "}",
    ]


def swift_snippet(indent, resources, wrap_init=False):
    body = swift_lines(resources)
    if wrap_init:
        body = ["init() {"] + ["    " + line for line in body] + ["}"]
    lines = ["// %s（由 nocompile_setup.py 添加，请勿提交，撤销：nocompile_setup.py --remove）" % CODE_BEGIN] + body + ["// %s" % CODE_END]
    return "".join(indent + line + "\n" for line in lines)


# 各入口方法的签名；匹配后插入到其后第一个 { 的下一行
ENTRY_PATTERNS = [
    ("objc", re.compile(r"^[ \t]*-\s*\(\s*BOOL\s*\)\s*application\s*:\s*\([^)]*\)\s*\w+\s+didFinishLaunchingWithOptions\s*:", re.M)),
    ("objc", re.compile(r"^[ \t]*-\s*\(\s*void\s*\)\s*applicationDidFinishLaunching\s*:", re.M)),
    ("swift", re.compile(r"^[ \t]*(?:@\w+\s+)*(?:(?:public|open|internal|override|@objc)\s+)*func\s+application\s*\(\s*_\s+\w+\s*:\s*UIApplication\s*,\s*didFinishLaunchingWithOptions\b", re.M)),
    ("swift", re.compile(r"^[ \t]*(?:@\w+\s+)*(?:(?:public|open|internal|override|@objc)\s+)*func\s+applicationDidFinishLaunching\s*\(", re.M)),
]
SWIFTUI_APP_RE = re.compile(r"@main\s+struct\s+\w+\s*:\s*(?:[\w.]+\s*,\s*)*(?:SwiftUI\.)?App\b[^{]*\{", re.M)
EXISTING_LOAD_RE = re.compile(r'(pathForResource:\s*@"NoCompile"|forResource:\s*"NoCompile"|NoCompile\.bundle"|\b(import|@import)\s+NoCompileClient\b|#import\s*<NoCompile)')


def line_indent(text, pos):
    start = text.rfind("\n", 0, pos) + 1
    match = re.match(r"[ \t]*", text[start:])
    return match.group(0)


def insertion_point(text, brace):
    """返回 { 所在行之后的位置与方法体缩进。"""
    newline = text.find("\n", brace)
    pos = len(text) if newline < 0 else newline + 1
    outer = line_indent(text, brace)
    following = re.match(r"[ \t]*(?=\S)", text[pos:])
    indent = following.group(0) if following and len(following.group(0)) > len(outer) else outer + "    "
    return pos, indent


def plan_code(files, resources):
    """在 target 的源码中找入口，返回 (文件, 位置, 片段) 或说明原因的字符串。"""
    contents = {}
    for path in files:
        try:
            with open(path, "r", encoding="utf-8") as handle:
                contents[path] = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
    for path, text in contents.items():
        if CODE_BEGIN in text:
            return "已存在（%s）" % os.path.basename(path)
    for path, text in contents.items():
        if EXISTING_LOAD_RE.search(text):
            return "%s 里已有加载客户端的代码，跳过" % os.path.basename(path)

    for lang, pattern in ENTRY_PATTERNS:
        for path, text in contents.items():
            if (lang == "objc") != path.endswith((".m", ".mm")):
                continue
            for match in pattern.finditer(text):
                if text[match.start():match.end()].lstrip().startswith("//"):
                    continue
                brace = text.find("{", match.end())
                if brace < 0:
                    continue
                if lang == "objc" and ";" in text[match.end():brace]:
                    continue  # 头文件式的声明
                pos, indent = insertion_point(text, brace)
                snippet = objc_snippet(indent, resources) if lang == "objc" else swift_snippet(indent, resources)
                return path, pos, snippet

    for path, text in contents.items():
        if not path.endswith(".swift"):
            continue
        match = SWIFTUI_APP_RE.search(text)
        if not match:
            continue
        brace = match.end() - 1
        init = re.compile(r"^[ \t]*(?:public\s+)?init\s*\(\s*\)\s*\{", re.M).search(text, brace)
        if init:
            pos, indent = insertion_point(text, init.end() - 1)
            return path, pos, swift_snippet(indent, resources)
        pos, indent = insertion_point(text, brace)
        return path, pos, swift_snippet(indent, resources, wrap_init=True)
    return None


def remove_code(path):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    pattern = re.compile(r"^[^\n]*%s[^\n]*\n(?:.*?\n)*?[^\n]*%s[^\n]*\n" % (re.escape(CODE_BEGIN), re.escape(CODE_END)), re.M)
    return text, pattern.sub("", text)


# ---------------------------------------------------------------------------
# 工程分析
# ---------------------------------------------------------------------------

class Project:
    def __init__(self, path):
        self.path = path
        self.pbx_path = os.path.join(path, "project.pbxproj")
        try:
            raw = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", self.pbx_path],
                                 check=True, capture_output=True).stdout
        except subprocess.CalledProcessError as error:
            fail("无法解析 %s：%s" % (self.pbx_path, error.stderr.decode("utf-8", "replace").strip()))
        data = json.loads(raw)
        self.objects = data["objects"]
        self.root = self.objects[data["rootObject"]]
        self.root_dir = os.path.normpath(os.path.join(os.path.dirname(path), self.root.get("projectDirPath", "")))
        self.parents = {}
        for oid, obj in self.objects.items():
            for child in obj.get("children", []):
                self.parents[child] = oid

    def app_targets(self):
        for tid in self.root.get("targets", []):
            target = self.objects[tid]
            if target.get("isa") == "PBXNativeTarget" and target.get("productType") == APP_PRODUCT_TYPE:
                yield tid, target

    def ref_path(self, oid):
        obj = self.objects.get(oid, {})
        tree = obj.get("sourceTree", "<group>")
        rel = obj.get("path", "")
        if tree == "<absolute>":
            return rel
        if tree == "SOURCE_ROOT":
            return os.path.join(self.root_dir, rel)
        if tree != "<group>":
            return None
        parent = self.parents.get(oid)
        base = self.ref_path(parent) if parent else self.root_dir
        if base is None:
            return None
        return os.path.normpath(os.path.join(base, rel))

    def source_files(self, target):
        files = []
        for pid in target.get("buildPhases", []):
            phase = self.objects.get(pid, {})
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for fid in phase.get("files", []):
                ref = self.objects.get(fid, {}).get("fileRef")
                path = self.ref_path(ref) if ref else None
                if path and path.endswith(SOURCE_EXTS):
                    files.append(path)
        # Xcode 16 的文件夹同步组：源码不在 Sources 阶段里，直接遍历目录
        for gid in target.get("fileSystemSynchronizedGroups", []):
            root = self.ref_path(gid)
            if not root or not os.path.isdir(root):
                continue
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                files.extend(os.path.join(dirpath, n) for n in filenames if n.endswith(SOURCE_EXTS))
        return files

    def configs(self, target):
        config_list = self.objects[target["buildConfigurationList"]]
        for cid in config_list.get("buildConfigurations", []):
            yield cid, self.objects[cid].get("name", "")

    def project_settings(self, pbx, name):
        """project 级同名配置的 buildSettings，没有时返回 None。"""
        config_list = self.objects[self.root["buildConfigurationList"]]
        for cid in config_list.get("buildConfigurations", []):
            if self.objects[cid].get("name") == name:
                return pbx.read_settings(cid)
        return None

    def uses_client_package(self, target):
        for did in target.get("packageProductDependencies", []):
            if self.objects.get(did, {}).get("productName") in ("NoCompile", "NoCompileClient"):
                return True
        return False

    def phase_ids(self, target, predicate):
        result = []
        for pid in target.get("buildPhases", []):
            phase = self.objects.get(pid, {})
            if phase.get("isa") == "PBXShellScriptBuildPhase" and predicate(phase):
                result.append(pid)
        return result


def podfile_uses_client(project_dir):
    podfile = os.path.join(project_dir, "Podfile")
    if not os.path.exists(podfile):
        return False
    with open(podfile, "r", encoding="utf-8", errors="replace") as handle:
        return re.search(r"^\s*pod\s+['\"]NoCompile['\"]", handle.read(), re.M) is not None


def phase_id_for(target_id, pbx_text):
    """由 target ID 派生固定的 24 位十六进制 ID，重复运行结果一致。"""
    seed = target_id
    while True:
        oid = hashlib.md5(("NoCompileSetup:" + seed).encode()).hexdigest()[:24].upper()
        if oid not in pbx_text:
            return oid
        seed += "+"


def matches_config(name, wanted):
    if wanted:
        return name in wanted
    return "Debug" in name


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def setup(projects, args, resources):
    copy_script = os.path.join(resources, COPY_SCRIPT_NAME)
    if not os.path.exists(copy_script):
        warn("未找到 %s，Run Script 仍会指向该路径，请确认 NoCompile.app 已安装（0.2.6 及以上）" % copy_script)
    script = "# 由 nocompile_setup.py 添加，请勿提交，撤销：nocompile_setup.py --remove\n"
    if args.configs:
        script += 'export NOCOMPILE_COPY_CONFIGURATIONS="%s"\n' % ",".join(args.configs)
    script += '"%s"\n' % copy_script

    touched = []
    any_target = False
    for project_path in projects:
        project = Project(project_path)
        pbx = PBXText(project.pbx_path)
        podfile_client = podfile_uses_client(project.root_dir)
        for tid, target in project.app_targets():
            name = target.get("name", tid)
            if args.target and name not in args.target:
                continue
            any_target = True
            log("\n▶ %s / %s" % (os.path.basename(project_path), name))
            # target 由 CocoaPods 集成（有 [CP] 阶段）且 Podfile 引入了 NoCompile，客户端与链接参数都由 Pod 提供
            if podfile_client and project.phase_ids(target, lambda p: p.get("name", "").startswith("[CP]")):
                log("  Podfile 已引入 NoCompile，链接参数与客户端由 CocoaPods 提供，跳过")
                continue
            via_spm = project.uses_client_package(target)

            configs = [(cid, cname) for cid, cname in project.configs(target) if matches_config(cname, args.configs)]
            if not configs:
                warn("  没有匹配的配置（默认只处理名字含 Debug 的配置，可用 --configs 指定），跳过")
                continue
            for cid, cname in configs:
                settings = pbx.read_settings(cid)
                # SPM 方式不需要拷贝脚本，也就不用关闭脚本沙盒
                done = apply_settings(settings, not via_spm, project.project_settings(pbx, cname),
                                      clear_exported=not args.keep_exported_symbols)
                pbx.write_settings(cid, settings)
                log("  [%s] %s" % (cname, "，".join(done) if done else "链接参数已就绪"))

            if via_spm:
                log("  已通过 Swift Package 链接客户端，不添加拷贝脚本与加载代码")
                continue

            existing = project.phase_ids(target, lambda p: p.get("name") == PHASE_NAME or COPY_SCRIPT_NAME in p.get("shellScript", ""))
            if existing:
                log("  Run Script 已存在，跳过")
            else:
                pbx.add_phase(tid, phase_id_for(tid, pbx.text), script)
                log("  已在 Build Phases 末尾添加 Run Script「%s」" % PHASE_NAME)

            plan = plan_code(project.source_files(target), resources)
            if plan is None:
                warn("  没找到 didFinishLaunching / applicationDidFinishLaunching / SwiftUI App 入口，请手动添加加载代码（见接入指南方式 E）")
            elif isinstance(plan, str):
                log("  加载代码%s" % plan)
            else:
                path, pos, snippet = plan
                with open(path, "r", encoding="utf-8") as handle:
                    text = handle.read()
                if not args.dry_run:
                    with open(path, "w", encoding="utf-8") as handle:
                        handle.write(text[:pos] + snippet + text[pos:])
                touched.append(path)
                log("  已在 %s 的入口最前面插入加载代码" % os.path.relpath(path, project.root_dir))

        if pbx.changed():
            if not args.dry_run:
                pbx.save()
            touched.append(project.pbx_path)

    if args.target and not any_target:
        fail("没有找到名为 %s 的 App target" % "、".join(args.target))
    if not any_target:
        fail("工程里没有 App 类型的 target")
    return touched


def remove(projects, args):
    touched = []
    for project_path in projects:
        project = Project(project_path)
        pbx = PBXText(project.pbx_path)
        for tid, target in project.app_targets():
            name = target.get("name", tid)
            if args.target and name not in args.target:
                continue
            for cid, cname in project.configs(target):
                settings = pbx.read_settings(cid)
                if remove_settings(settings):
                    pbx.write_settings(cid, settings)
                    log("%s / %s [%s]：已还原构建设置" % (os.path.basename(project_path), name, cname))
            for pid in project.phase_ids(target, lambda p: p.get("name") == PHASE_NAME):
                pbx.remove_phase(pid)
                log("%s / %s：已删除 Run Script" % (os.path.basename(project_path), name))
            for path in set(project.source_files(target)):
                try:
                    text, new = remove_code(path)
                except (OSError, UnicodeDecodeError):
                    continue
                if new != text:
                    if not args.dry_run:
                        with open(path, "w", encoding="utf-8") as handle:
                            handle.write(new)
                    touched.append(path)
                    log("%s：已删除加载代码" % os.path.relpath(path, project.root_dir))
        if pbx.changed():
            if not args.dry_run:
                pbx.save()
            touched.append(project.pbx_path)
    return touched


# ---------------------------------------------------------------------------
# 开关与 Podfile 钩子
# ---------------------------------------------------------------------------

SWITCH_NAMES = ("IntegrateNoCompile", "integrateNoCompile")
HOOK_BEGIN = "# >>> NoCompile setup hook"
HOOK_END = "# <<< NoCompile setup hook"


def switch_enabled():
    """读取环境变量开关 IntegrateNoCompile，写法与 Podfile 里的 integrateHotReload 等开关一致。"""
    for name in SWITCH_NAMES:
        value = os.environ.get(name)
        if value is not None:
            return value.strip().lower() in ("true", "1", "yes")
    return False


def base_dir_of(path):
    path = os.path.abspath(path)
    return path if os.path.isdir(path) and not path.endswith((".xcodeproj", ".xcworkspace")) else os.path.dirname(path)


def hook_lines(indent):
    # 钩子会随 Podfile 提交，只引用 NoCompile.app 内的脚本；NOCOMPILE_SETUP_SCRIPT 供本机临时指向其他位置。
    # 插件（如 cocoapods-arm64-to-sim）的 post_integrate 在 Podfile 钩子之后执行，会把内存中的工程再保存一次、
    # 覆盖脚本的修改，所以用 at_exit 等 pod 进程结束、所有钩子执行完后再运行，且只在 pod install 成功时运行
    lines = [
        HOOK_BEGIN,
        "# 本机 export IntegrateNoCompile=true 后，pod install 会自动接入 NoCompile（拷贝 bundle 方式，仅 Debug），",
        "# 未设置时自动撤销；未安装 NoCompile.app 时不做任何事。接入的改动只在本地，请勿提交。",
        "nc_setup_script = ENV['NOCOMPILE_SETUP_SCRIPT'] || '%s/nocompile_setup.py'" % DEFAULT_RESOURCES,
        "if File.exist?(nc_setup_script)",
        "  nc_project_dir = File.dirname(File.expand_path(__FILE__))",
        "  # 等所有钩子（包括插件的）执行完再运行，避免插件保存工程时覆盖脚本的修改",
        "  at_exit do",
        "    if $!.nil? || ($!.is_a?(SystemExit) && $!.success?)",
        "      system('/usr/bin/python3', nc_setup_script, '--sync', nc_project_dir)",
        "    end",
        "  end",
        "end",
        HOOK_END,
    ]
    return "".join(indent + line + "\n" for line in lines)


def install_pod_hook(podfile):
    with open(podfile, "r", encoding="utf-8") as handle:
        text = handle.read()
    if HOOK_BEGIN in text:
        return False
    # CocoaPods 只允许一个 post_integrate，已有时把调用放进它的最前面
    match = re.search(r"^([ \t]*)post_integrate\s+do\s*\|[^|]*\|[^\n]*\n", text, re.M)
    if match:
        text = text[:match.end()] + hook_lines(match.group(1) + "  ") + text[match.end():]
    else:
        lines = hook_lines("").split("\n")
        # 标记与说明注释在块外，post_integrate 块包住调用代码
        head = [line for line in lines[1:-2] if line.startswith("#")]
        body = [line for line in lines[1:-2] if not line.startswith("#")]
        block = "\n".join([lines[0]] + head) + "\npost_integrate do |installer|\n"
        block += "".join("  " + line + "\n" for line in body) + "end\n" + lines[-2] + "\n"
        if not text.endswith("\n"):
            text += "\n"
        text += "\n" + block
    with open(podfile, "w", encoding="utf-8") as handle:
        handle.write(text)
    return True


def remove_pod_hook(podfile):
    with open(podfile, "r", encoding="utf-8") as handle:
        text = handle.read()
    begin = text.find(HOOK_BEGIN)
    if begin < 0:
        return False
    start = text.rfind("\n", 0, begin) + 1
    end = text.find("\n", text.find(HOOK_END, begin)) + 1
    # 追加在文件末尾的钩子前面有一个空行，一并去掉
    if start == begin and text[start - 2:start] == "\n\n":
        start -= 1
    with open(podfile, "w", encoding="utf-8") as handle:
        handle.write(text[:start] + text[end:])
    return True


def report(touched, args, removing):
    if args.dry_run:
        log("\n（--dry-run，未写入任何文件）")
        return
    if touched:
        log("\n已修改：")
        for path in dict.fromkeys(touched):
            log("  " + path)
        if not removing:
            log("\n这些改动只用于本地调试，请勿提交。切换分支前运行 `%s --remove` 撤销。" % os.path.basename(sys.argv[0]))
    elif removing:
        log("没有需要撤销的改动")
    else:
        log("\n已全部接入，无需改动")


def main():
    parser = argparse.ArgumentParser(description="一键接入 / 撤销 NoCompile（拷贝 bundle 方式），改动只用于本地调试，请勿提交")
    parser.add_argument("path", nargs="?", default=".", help=".xcworkspace / .xcodeproj 或其所在目录，默认当前目录")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--remove", action="store_true", help="撤销本脚本添加的全部改动")
    mode.add_argument("--sync", action="store_true", help="按环境变量 IntegrateNoCompile 接入（true）或撤销，供 Podfile 钩子调用")
    mode.add_argument("--install-pod-hook", action="store_true", help="在 Podfile 加 post_integrate 钩子（可提交），pod install 后自动执行 --sync")
    mode.add_argument("--uninstall-pod-hook", action="store_true", help="去掉 Podfile 里的钩子")
    parser.add_argument("--target", action="append", help="只处理指定的 App target，可重复")
    parser.add_argument("--configs", help="要接入的配置名，逗号分隔，默认只处理名字含 Debug 的配置")
    parser.add_argument("--keep-exported-symbols", action="store_true", help="不清空 EXPORTED_SYMBOLS_FILE")
    parser.add_argument("--bundles-dir", help="客户端 bundle 与 nocompile_copy_bundle.sh 所在目录，默认 NoCompile.app 的 Resources")
    parser.add_argument("--dry-run", action="store_true", help="只打印将要做的改动，不写文件")
    args = parser.parse_args()
    args.configs = [c.strip() for c in args.configs.split(",") if c.strip()] if args.configs else None

    if args.install_pod_hook or args.uninstall_pod_hook:
        podfile = os.path.join(base_dir_of(args.path), "Podfile")
        if not os.path.exists(podfile):
            fail("未找到 %s" % podfile)
        if args.install_pod_hook:
            if install_pod_hook(podfile):
                log("已在 Podfile 添加 post_integrate 钩子，可以提交。本机 export IntegrateNoCompile=true 后 pod install 即自动接入")
            else:
                log("Podfile 里已有钩子")
        elif remove_pod_hook(podfile):
            log("已去掉 Podfile 里的钩子")
        else:
            log("Podfile 里没有钩子")
        return

    projects = locate_projects(args.path)
    if args.sync:
        if switch_enabled():
            log("[NoCompile] IntegrateNoCompile=true，接入 NoCompile")
            report(setup(projects, args, locate_resources(args.bundles_dir)), args, False)
        else:
            # 未开启时撤销之前接入的改动；本来就没接入时保持安静，不打扰未使用 NoCompile 的同事
            touched = remove(projects, args)
            if touched:
                log("[NoCompile] 未设置 IntegrateNoCompile=true，已撤销接入")
        return
    if args.remove:
        report(remove(projects, args), args, True)
    else:
        report(setup(projects, args, locate_resources(args.bundles_dir)), args, False)


if __name__ == "__main__":
    main()
