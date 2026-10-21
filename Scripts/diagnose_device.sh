#!/bin/bash
#
# 真机连不上时的一键诊断：收集 Mac / Xcode / usbmuxd / 设备端口 / NoCompile 日志信息。
# 用法：iPhone 用数据线连好，在 Xcode 里以 Debug 运行接入了 NoCompile 的 App，保持前台，然后执行
#   bash diagnose_device.sh
# 结果同时输出到终端和 ~/Desktop/NoCompile-device-diagnose.txt，把该文件发给开发者即可。
#
# 注意：探测设备端口时会短暂占用 App 的连接，NoCompile 会在 2 秒内自动重连，不影响使用。
#

DEVICE_PORT=21891
MAC_PORT=21890
OUTPUT="$HOME/Desktop/NoCompile-device-diagnose.txt"

run() {
    echo "\$ $*"
    "$@" 2>&1
    echo
}

{
    echo "===== NoCompile 真机诊断 $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo
    echo "## 1. 环境"
    run sw_vers
    echo "机型：$(sysctl -n hw.model)，芯片：$(sysctl -n machdep.cpu.brand_string)，架构：$(uname -m)"
    echo
    run xcodebuild -version
    run xcode-select -p
    for app in /Applications/NoCompile.app "$HOME/Applications/NoCompile.app"; do
        if [ -d "$app" ]; then
            echo "NoCompile：$app 版本 $(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" \
                "架构 $(lipo -archs "$app/Contents/MacOS/NoCompile" 2>/dev/null)"
        fi
    done
    echo "运行中的 NoCompile 进程："
    pgrep -fl "NoCompile.app/Contents/MacOS/NoCompile" || echo "（没有运行）"
    echo

    echo "## 2. usbmuxd"
    run ls -la /var/run/usbmuxd
    launchctl print system/com.apple.usbmuxd 2>&1 | grep -E "^\s*(state|pid|path) =" | head -5
    echo

    echo "## 3. usbmuxd 设备列表与端口探测"
    echo "（端口 $DEVICE_PORT 为 NoCompile 客户端在设备上监听的端口；62078 为系统 lockdownd，作对照）"
    /usr/bin/python3 -I - "$DEVICE_PORT" <<'PYEOF'
import plistlib, socket, struct, sys, time

DEVICE_PORT = int(sys.argv[1])
NAMES = {0: "成功", 1: "BadCommand", 2: "BadDevice（设备不可用或该通道不支持此端口）",
         3: "ConnectionRefused（设备上没有进程监听此端口）", 6: "BadVersion"}

def request(message, timeout=8):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect("/var/run/usbmuxd")
    payload = plistlib.dumps(dict(message, ClientVersionString="NoCompile-diagnose", ProgName="NoCompile-diagnose"))
    s.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)
    header = b""
    while len(header) < 16:
        chunk = s.recv(16 - len(header))
        if not chunk:
            raise IOError("usbmuxd 关闭了连接")
        header += chunk
    length = struct.unpack("<I", header[:4])[0] - 16
    body = b""
    while len(body) < length:
        chunk = s.recv(length - len(body))
        if not chunk:
            raise IOError("usbmuxd 关闭了连接")
        body += chunk
    return s, plistlib.loads(body)

try:
    s, result = request({"MessageType": "ListDevices"})
    s.close()
except Exception as error:
    print("❌ 无法使用 usbmuxd：%r" % (error,))
    sys.exit(0)

devices = result.get("DeviceList", [])
if not devices:
    print("❌ usbmuxd 中没有设备（Xcode 能看到设备但这里为空，说明设备只走了 CoreDevice 通道）")
for device in devices:
    props = device.get("Properties", {})
    print("设备 %s：连接方式 %s，序列号 %s，速率 %s" % (device.get("DeviceID"), props.get("ConnectionType"),
          props.get("SerialNumber"), props.get("ConnectionSpeed", "-")))
    for port in (DEVICE_PORT, 62078):
        start = time.time()
        try:
            s, reply = request({"MessageType": "Connect", "DeviceID": device["DeviceID"],
                                "PortNumber": socket.htons(port)})
            s.close()
            number = reply.get("Number", -1)
            print("    Connect 端口 %-5d → %s %s（%.2fs）" % (port, number, NAMES.get(number, "未知"), time.time() - start))
        except Exception as error:
            print("    Connect 端口 %-5d → 异常 %r（%.2fs）" % (port, error, time.time() - start))
PYEOF
    echo

    echo "## 4. CoreDevice 设备列表（Xcode 使用的通道）"
    run xcrun devicectl list devices
    echo "## 5. Mac 端监听端口 $MAC_PORT"
    lsof -nP -iTCP:$MAC_PORT -sTCP:LISTEN 2>&1 || echo "（没有进程监听 $MAC_PORT）"
    echo

    echo "## 6. NoCompile 诊断日志（真机 / 连接相关的最近 60 行）"
    grep -a -E "\[(真机|连接)\]" "$HOME/Library/Logs/NoCompile/Diagnostics.log" 2>/dev/null | tail -60 | cut -c1-300 \
        || echo "（没有找到 ~/Library/Logs/NoCompile/Diagnostics.log）"
} 2>&1 | tee "$OUTPUT"

echo
echo "诊断结果已保存到：$OUTPUT"
