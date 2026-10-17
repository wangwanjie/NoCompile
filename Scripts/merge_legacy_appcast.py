#!/usr/bin/env python3
#
# 用 appcast-arm64.xml 与 appcast-x86_64.xml 重建 appcast.xml。
# 0.2.3 及更早的通用版 SUFeedURL 指向 appcast.xml，靠它升级到对应架构的版本。
#
# 同一版本 arm64 条目在前、x86_64 在后：Sparkle 遇到同版本时取第一个，Apple 芯片拿到 arm64 包；
# Intel 机器会过滤掉带 arm64 硬件要求的条目，拿到 x86_64 包。旧的通用包条目原样保留。
#
# 用法: merge_legacy_appcast.py LEGACY_APPCAST ARM64_APPCAST X86_64_APPCAST
#

import copy
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def load_items(path):
    p = pathlib.Path(path)
    if not p.exists():
        return []
    channel = ET.parse(p).getroot().find("channel")
    if channel is None:
        return []
    return channel.findall("item")


def enclosure_name(item):
    enclosure = item.find("enclosure")
    if enclosure is None:
        return ""
    return enclosure.attrib.get("url", "").rsplit("/", 1)[-1]


def build_number(item):
    node = item.find(f"{{{SPARKLE_NS}}}version")
    text = (node.text or "").strip() if node is not None else ""
    numbers = tuple(int(x) for x in re.findall(r"\d+", text))
    return numbers or (0,)


def main():
    legacy_path, arm64_path, x86_path = sys.argv[1:4]

    if pathlib.Path(legacy_path).exists():
        tree = ET.parse(legacy_path)
    else:
        root = ET.Element("rss", {"version": "2.0"})
        ET.SubElement(ET.SubElement(root, "channel"), "title").text = "NoCompile"
        tree = ET.ElementTree(root)
    channel = tree.getroot().find("channel")

    # 旧通用包的文件名不带架构后缀；带后缀的条目以两个架构 feed 为准重新写入
    universal = []
    for item in channel.findall("item"):
        if not re.search(r"_(arm64|x86_64)\.dmg$", enclosure_name(item)):
            universal.append(item)
        channel.remove(item)

    ordered = []
    for rank, items in enumerate([load_items(arm64_path), load_items(x86_path), universal]):
        for item in items:
            ordered.append((build_number(item), -rank, copy.deepcopy(item)))
    # build 号降序；同 build 号按 arm64、x86_64、通用的顺序
    ordered.sort(key=lambda entry: (entry[0], entry[1]), reverse=True)
    for _, _, item in ordered:
        channel.append(item)

    ET.indent(tree, space="    ")
    tree.write(legacy_path, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
