#!/usr/bin/env python3
"""
NoCompile 端到端自测：改源码 → 等 NoCompile 注入 → 读 App 里的探针输出。

用法（在示例工程目录 Examples/NoCompileExample 下）：
    python3 E2E/run_e2e.py                       # 全部场景
    python3 E2E/run_e2e.py --only A01,B07,R01    # 指定场景
    python3 E2E/run_e2e.py --build               # 先 xcodebuild 构建并安装
    python3 E2E/run_e2e.py --list                # 列出场景

前置条件：已有一个能用的 nocompile 命令行（默认 ../../.build/debug/nocompile，可用 --nocompile 指定），
模拟器已创建。脚本会自己启动 App（带 EXAMPLE_PROBE_FILE）、启动 nocompile、逐个场景改文件，
结束后把所有被改动的文件恢复原样。
"""

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)  # Examples/NoCompileExample
sys.path.insert(0, HERE)
import manifest  # noqa: E402

BUNDLE_ID = "com.vanjay.nocompile.example.ios"
WORKSPACE = os.path.join(ROOT, "NoCompileExample.xcworkspace")
# 输出放在工程目录之外：NoCompile 会监听工程目录，备份文件放在里面会被当成改动
OUT = os.environ.get("E2E_OUT", "/tmp/nocompile-e2e-out")
PROBE_FILE = "/tmp/nocompile-e2e-probe.json"


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


class Sim:
    def __init__(self, udid):
        self.udid = udid

    def boot(self):
        run(["xcrun", "simctl", "boot", self.udid])
        run(["xcrun", "simctl", "bootstatus", self.udid, "-b"], timeout=180)

    def app_path(self):
        out = run(["xcodebuild", "-workspace", WORKSPACE, "-scheme", "ExampleiOS", "-configuration", "Debug",
                   "-destination", f"platform=iOS Simulator,id={self.udid}", "-showBuildSettings"]).stdout
        match = re.search(r"^\s*TARGET_BUILD_DIR = (.*)$", out, re.M)
        return os.path.join(match.group(1), "ExampleiOS.app")

    def derived_data(self):
        return os.path.dirname(os.path.dirname(os.path.dirname(self.app_path())))

    def clean(self):
        """删除该工程的 DerivedData，保证接下来的构建日志里有每个文件的编译命令"""
        path = self.derived_data()
        if "DerivedData" in path and os.path.isdir(path):
            print(f"🧹 删除 {path}", flush=True)
            shutil.rmtree(path, ignore_errors=True)

    def build(self):
        print("⏳ xcodebuild …", flush=True)
        result = run(["xcodebuild", "-workspace", WORKSPACE, "-scheme", "ExampleiOS", "-configuration", "Debug",
                      "-destination", f"platform=iOS Simulator,id={self.udid}", "build"])
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, "xcodebuild.log"), "w") as f:
            f.write(result.stdout + result.stderr)
        if result.returncode != 0:
            tail = "\n".join((result.stdout + result.stderr).splitlines()[-30:])
            raise SystemExit(f"xcodebuild 失败：\n{tail}")

    def install(self):
        run(["xcrun", "simctl", "terminate", self.udid, BUNDLE_ID])
        r = run(["xcrun", "simctl", "install", self.udid, self.app_path()])
        if r.returncode != 0:
            raise SystemExit("安装失败：" + r.stderr)

    def launch(self):
        run(["xcrun", "simctl", "terminate", self.udid, BUNDLE_ID])
        if os.path.exists(PROBE_FILE):
            os.remove(PROBE_FILE)
        env = dict(os.environ, SIMCTL_CHILD_EXAMPLE_PROBE_FILE=PROBE_FILE)
        r = subprocess.run(["xcrun", "simctl", "launch", self.udid, BUNDLE_ID], env=env, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("启动失败：" + r.stderr)


class Engine:
    """nocompile 命令行子进程，日志写入文件并可按偏移读取增量"""

    def __init__(self, binary):
        self.binary = binary
        self.path = os.path.join(OUT, "engine.log")
        self.proc = None

    def start(self):
        os.makedirs(OUT, exist_ok=True)
        self.log = open(self.path, "w")
        self.proc = subprocess.Popen([self.binary, "--project", WORKSPACE], stdout=self.log, stderr=subprocess.STDOUT,
                                     cwd=ROOT, preexec_fn=os.setsid)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGINT)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)

    def size(self):
        self.log.flush()
        return os.path.getsize(self.path)

    def since(self, offset):
        with open(self.path, "rb") as f:
            f.seek(offset)
            return f.read().decode("utf-8", "replace")

    def wait_for(self, pattern, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if re.search(pattern, self.since(0)):
                return True
            time.sleep(0.3)
        return False


class Probe:
    def __init__(self):
        self.pid = None

    def read(self):
        try:
            with open(PROBE_FILE) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def wait_alive(self, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            data = self.read()
            if data and data.get("tick", 0) >= 3:
                self.pid = data["pid"]
                return data
            time.sleep(0.3)
        return None


def file_hash(path):
    import hashlib
    try:
        with open(path, "rb") as f:
            return hashlib.sha1(f.read()).hexdigest()
    except OSError:
        return None


STATE_FILE = os.path.join(OUT, "pending.json")


class Workspace:
    """记录被改动 / 新建的文件，结束时恢复。

    恢复前核对文件当前内容是否仍是脚本自己写入的版本：期间被人手动改过的文件不会被旧备份覆盖。
    状态落盘到 pending.json，脚本被强行终止后可用 --restore 安全恢复"""

    def __init__(self):
        self.backup = os.path.join(OUT, "backup")
        shutil.rmtree(self.backup, ignore_errors=True)
        os.makedirs(self.backup)
        self.saved = {}
        self.created = []
        self.written = {}  # rel -> 脚本最后一次写入后的哈希

    def persist(self):
        with open(STATE_FILE, "w") as f:
            json.dump({"saved": self.saved, "created": self.created, "written": self.written}, f)

    @staticmethod
    def restore_from_state():
        if not os.path.exists(STATE_FILE):
            return
        with open(STATE_FILE) as f:
            state = json.load(f)
        workspace = Workspace.__new__(Workspace)
        workspace.backup = os.path.join(OUT, "backup")
        workspace.saved = state["saved"]
        workspace.created = state["created"]
        workspace.written = state["written"]
        workspace.restore_all()

    def abs(self, rel):
        return os.path.join(ROOT, rel)

    def save(self, rel):
        if rel in self.saved or rel in self.created:
            return
        path = self.abs(rel)
        if os.path.exists(path):
            dest = os.path.join(self.backup, rel.replace("/", "__"))
            shutil.copy2(path, dest)
            self.saved[rel] = dest
        else:
            self.created.append(rel)

    def apply(self, edit):
        rel = edit["file"]
        path = self.abs(rel)
        self.save(rel)
        if "create" in edit:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(edit["create"])
            self.written[rel] = file_hash(path)
            self.persist()
            return True
        if "copyFrom" in edit:
            shutil.copyfile(self.abs(edit["copyFrom"]), path)
            self.written[rel] = file_hash(path)
            self.persist()
            return True
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if edit["from"] not in text:
            return False
        text = text.replace(edit["from"], edit["to"]) if edit.get("all") else text.replace(edit["from"], edit["to"], 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        self.written[rel] = file_hash(path)
        self.persist()
        return True

    def _still_ours(self, rel):
        """文件当前内容仍是脚本写入的版本（没有被别人改过）"""
        return file_hash(self.abs(rel)) == self.written.get(rel)

    def restore_file(self, rel):
        if rel in self.saved:
            if self._still_ours(rel):
                shutil.copyfile(self.saved[rel], self.abs(rel))
        elif rel in self.created and os.path.exists(self.abs(rel)):
            os.remove(self.abs(rel))

    def restore_all(self):
        for rel in list(self.saved):
            if self._still_ours(rel):
                shutil.copyfile(self.saved[rel], self.abs(rel))
            elif file_hash(self.abs(rel)) != file_hash(self.saved[rel]):
                print(f"⚠️ {rel} 在脚本运行期间被改动过，未恢复", flush=True)
        for rel in self.created:
            if os.path.exists(self.abs(rel)):
                os.remove(self.abs(rel))
        if os.path.exists(STATE_FILE):
            os.remove(STATE_FILE)


def materialize(obj, base):
    """把清单里的 @@v2@@ / @@v3@@ / @@v4@@ 换成本场景独有的令牌。
    多个场景可能共用同一份探针输出（例如同一个函数里既有 App 的令牌又有 framework 的令牌），
    令牌唯一才不会被前面场景留下的 v2 误判为通过"""
    if isinstance(obj, str):
        return (obj.replace("@@v2@@", f"@@v{base}@@").replace("@@v3@@", f"@@v{base + 1}@@")
                .replace("@@v4@@", f"@@v{base + 2}@@"))
    if isinstance(obj, list):
        return [materialize(x, base) for x in obj]
    if isinstance(obj, tuple):
        return tuple(materialize(x, base) for x in obj)
    if isinstance(obj, dict):
        return {materialize(k, base): materialize(v, base) for k, v in obj.items()}
    return obj


def count(value, needle):
    return value.count(needle)


def crash_reports_since(start):
    base = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    found = []
    if os.path.isdir(base):
        for name in os.listdir(base):
            if name.startswith("ExampleiOS") and os.path.getmtime(os.path.join(base, name)) >= start:
                found.append(os.path.join(base, name))
    return found


def evaluate(checks, values):
    problems = []
    for chk in checks:
        value = values.get(chk["key"], "")
        for needle, want in chk["expect"].items():
            got = count(value, needle)
            if got != want:
                problems.append(f"{chk['key']}: 期望 {needle!r}×{want}，实际×{got}，输出「{value}」")
    return problems


def check_step(step, probe, deadline):
    """轮询直到全部「应出现」的检查满足（或超时），再按 settle 多等一会儿，最后整体判定。
    返回 (ok, 描述, 是否崩溃)"""
    checks = step.get("checks", [])
    settle = step.get("settle", 0)
    positive = [c for c in checks if not c.get("stay") and c["expect"]]
    started = time.time()
    satisfied_at = None
    values = {}
    while time.time() < deadline:
        data = probe.read()
        if data is None:
            time.sleep(0.2)
            continue
        if data["pid"] != probe.pid:
            return False, "App 崩溃或重启（pid 变化）", True
        if time.time() - data["time"] > 5:
            return False, "App 已无响应（探针 5 秒没有更新，进程可能已崩溃或卡死）", True
        values = data["values"]
        if positive:
            if not evaluate(positive, values):
                if satisfied_at is None:
                    satisfied_at = time.time()
                if time.time() - satisfied_at >= settle:
                    break
            else:
                satisfied_at = None
        elif time.time() - started >= settle:
            break
        time.sleep(0.2)
    data = probe.read()
    if data is not None:
        if data["pid"] != probe.pid:
            return False, "App 崩溃或重启（pid 变化）", True
        if time.time() - data["time"] > 5:
            return False, "App 已无响应（探针 5 秒没有更新，进程可能已崩溃或卡死）", True
        values = data["values"]
    problems = evaluate(checks, values)
    return (not problems), "；".join(problems), False


def monotonic_ok(spec, before, after):
    problems = []
    for key, pattern in spec:
        b = re.search(pattern, before.get(key, ""))
        a = re.search(pattern, after.get(key, ""))
        if b and a and int(a.group(1)) < int(b.group(1)):
            problems.append(f"{key} 的 {pattern} 从 {b.group(1)} 回退到 {a.group(1)}（状态被重置）")
        if b and not a:
            problems.append(f"{key} 的 {pattern} 之后读不到")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="")
    parser.add_argument("--skip", default="")
    parser.add_argument("--sim", default="")
    parser.add_argument("--nocompile", default=os.path.join(ROOT, "..", "..", ".build", "debug", "nocompile"))
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--clean", action="store_true", help="先删除 DerivedData 再完整构建（隐含 --build）")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--restore", action="store_true", help="脚本被强行终止后，把备份目录里的原始文件恢复回来")
    parser.add_argument("--timeout", type=float, default=25)
    args = parser.parse_args()

    if args.restore:
        Workspace.restore_from_state()
        print("已按 pending.json 恢复（只恢复仍是脚本写入版本的文件）")
        return

    scenarios = manifest.SCENARIOS
    if args.list:
        for s in scenarios:
            print(s["id"], "(xfail)" if s.get("xfail") else "")
        return
    only = {x for x in args.only.split(",") if x}
    skip = {x for x in args.skip.split(",") if x}
    if only:
        scenarios = [s for s in scenarios if s["id"] in only]
    scenarios = [s for s in scenarios if s["id"] not in skip]

    if os.path.exists(STATE_FILE):
        print("发现上次遗留的改动，先恢复……", flush=True)
        Workspace.restore_from_state()

    udid = args.sim or os.environ.get("E2E_SIM") or ""
    if not udid:
        out = run(["xcrun", "simctl", "list", "devices", "available"]).stdout
        match = re.search(r"iPhone[^\n]*\(([0-9A-F-]{36})\) \((?:Booted|Shutdown)\)", out)
        udid = match.group(1)
    sim = Sim(udid)
    os.makedirs(OUT, exist_ok=True)
    sim.boot()
    if args.clean:
        sim.clean()
    if args.build or args.clean:
        sim.build()
    sim.install()
    sim.launch()
    probe = Probe()
    base = probe.wait_alive()
    if not base:
        raise SystemExit("App 没有产生探针输出，检查 App 是否启动成功")

    engine = Engine(os.path.abspath(args.nocompile))
    workspace = Workspace()
    engine.start()
    results = []

    def finish():
        engine.stop()
        workspace.restore_all()

    def on_signal(*_):
        finish()
        sys.exit(130)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    try:
        if not engine.wait_for(r"就绪|已连接", 90):
            print("⚠️ 引擎 90 秒内没有就绪，日志：\n" + engine.since(0)[-2000:])
        if not engine.wait_for(r"已连接", 60):
            print("⚠️ App 没有连上 NoCompile：\n" + engine.since(0)[-2000:])
        time.sleep(1.5)
        print(f"▶︎ 共 {len(scenarios)} 个场景，模拟器 {udid}\n", flush=True)

        for ordinal, scenario in enumerate(scenarios):
            scenario = materialize(scenario, 10 + ordinal * 3)
            sid = scenario["id"]
            started = time.time()
            data = probe.read()
            before = dict(data["values"]) if data else {}
            log_offset = engine.size()
            status, note = "PASS", ""
            crashed = False
            elapsed = 0.0
            step_notes = []
            for step in scenario["steps"]:
                missing = [e["file"] for e in step["edits"] if not workspace.apply(e)]
                if missing:
                    status, note = "SKIP", f"找不到要替换的文本：{missing}（文件已被前序场景改过？）"
                    break
                edits = step["edits"]
                for e in edits:
                    if e.get("gap"):
                        time.sleep(e["gap"])
                step_start = time.time()
                ok, detail, crashed = check_step(step, probe, step_start + args.timeout)
                elapsed += time.time() - step_start
                log_text = engine.since(log_offset)
                if step.get("expectLog") and not re.search(step["expectLog"], log_text):
                    ok, detail = False, (detail + "；" if detail else "") + f"引擎日志里没有匹配 {step['expectLog']!r} 的提示"
                if step.get("forbidLog") and re.search(step["forbidLog"], log_text):
                    ok, detail = False, (detail + "；" if detail else "") + f"引擎日志里出现了不该有的 {step['forbidLog']!r}"
                if crashed:
                    status, note = "CRASH", detail
                    break
                if not ok:
                    status, note = "FAIL", detail
                    break
            else:
                data = probe.read()
                after = data["values"] if data else {}
                problems = monotonic_ok(scenario.get("monotonic", []), before, after)
                for needle in scenario.get("extra_expect_not", []):
                    if needle in after.get(sid, ""):
                        problems.append(f"{sid} 的输出里出现了 {needle!r}")
                if problems:
                    status, note = "FAIL", "；".join(problems)

            engine_log = engine.since(log_offset)
            if scenario.get("xfail"):
                if status == "PASS":
                    status = "XPASS"
                elif status == "FAIL":
                    status = "XFAIL"
                    note = f"{scenario['xfail']}｜{note}"

            if status == "CRASH":
                # 崩溃后恢复这次场景改的文件并重启 App，保证后续场景的源码与二进制一致
                reports = crash_reports_since(started - 1)
                if reports:
                    note += f"｜崩溃日志 {reports[-1]}"
                engine.stop()
                workspace.restore_all()
                sim.launch()
                probe.pid = None
                probe.wait_alive()
                engine.start()
                engine.wait_for(r"已连接", 60)
                time.sleep(1.5)
                workspace = Workspace()
            else:
                for rel in scenario.get("cleanup", []):
                    workspace.restore_file(rel)

            results.append({"id": sid, "status": status, "seconds": round(elapsed, 2), "note": note,
                            "engineLog": engine_log[-3000:]})
            icon = {"PASS": "✅", "XPASS": "🎉", "XFAIL": "🟡", "FAIL": "❌", "CRASH": "💥", "SKIP": "⏭"}.get(status, "?")
            print(f"{icon} {sid:<5} {status:<6} {elapsed:5.1f}s  {note[:300]}", flush=True)
            if status in ("FAIL", "CRASH"):
                tail = "\n".join(l for l in engine_log.splitlines() if l.strip())[-600:]
                if tail:
                    print("     引擎日志：" + tail.replace("\n", "\n     "), flush=True)
    finally:
        finish()

    with open(os.path.join(OUT, "report.json"), "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    summary = {}
    for r in results:
        summary[r["status"]] = summary.get(r["status"], 0) + 1
    print("\n汇总：" + "，".join(f"{k} {v}" for k, v in sorted(summary.items())))
    print(f"详情：{os.path.join(OUT, 'report.json')}，引擎日志：{engine.path}")
    sys.exit(1 if any(r["status"] in ("FAIL", "CRASH") for r in results) else 0)


if __name__ == "__main__":
    main()
