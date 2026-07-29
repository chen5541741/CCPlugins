#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scan_path_overwrite.py
遍历目录下的 Claude Code 会话 jsonl 日志，定位 "path 环境变量被覆盖" 问题。

问题原理
--------
在 zsh 中，小写数组 `path` 与大写标量 `PATH` 是 tied（绑定）的。当命令把 `path`
当作变量名（典型：`for path in ...`），第一轮迭代就会把 PATH 覆盖成单个目录，
导致 curl/grep/head/python3 等大量报 "command not found"。

判定逻辑（双特征关联）
--------
  - danger  : 命令文本里出现 path 变量赋值模式
              （for/select path、read path、裸 path=）
  - symptom : 该调用的 tool_result 里出现 command-not-found 类错误
  - CONFIRMED = danger 且 symptom   —— 强证据，就是这个问题
  - POTENTIAL = 仅 danger            —— 触发了，但日志未记录症状 / 被绝对路径等规避
  - SUSPECT   = 仅 symptom           —— command not found 但无 path 模式，原因待查

用法
--------
  python scan_path_overwrite.py <目录> [选项]

  选项：
    --json PATH       额外把结构化报告写入该 JSON 文件
    --show-all        同时显示 POTENTIAL / SUSPECT（默认只显示 CONFIRMED）
    --jobs N          并行进程数，默认 1
    --max N           每类详情最多显示条数，默认 50
"""
import sys
import os
import re
import json
import argparse
from collections import Counter
from pathlib import Path

# Windows 控制台中文输出兜底
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


# ---------- 正则 ----------
# 原因：把 path 当变量名（zsh 下会通过 tie 覆盖 PATH）
DANGER_PATTERNS = [
    (re.compile(r"\b(?:for|select)\s+path\b\s*(?:in|do|\(|;|$)", re.MULTILINE), "for/select path"),
    (re.compile(r"\bread\s+path\b"), "read path"),
    # 裸 path= 赋值；负向后顾排除 PATH= / mypath= / filepath= / /path= / --path=
    (re.compile(r"(?<![A-Za-z0-9_/.-])path\s*="), "path= 赋值"),
]

# 症状：command-not-found 体系
SYMPTOM_PATTERNS = [
    re.compile(r"could not be located because [^\n]{0,60}?not included in the PATH", re.IGNORECASE),
    re.compile(r"\bcommand not found\b", re.IGNORECASE),
    re.compile(r"Command '[^']+' is available in the following places", re.IGNORECASE),
]


def match_danger(cmd):
    return [name for rx, name in DANGER_PATTERNS if rx.search(cmd)]


def match_symptoms(text):
    hits = []
    for rx in SYMPTOM_PATTERNS:
        m = rx.search(text)
        if m:
            hits.append(m.group(0).strip().replace("\n", " "))
    # 提取 command-not-found 涉及的命令名（如 curl、head）
    names = re.findall(r"Command '([^']+)' is available in the following places", text)
    return hits, names


def danger_line(cmd):
    """返回第一个命中危险模式所在行的文本（便于定位）。"""
    for rx, _ in DANGER_PATTERNS:
        m = rx.search(cmd)
        if m:
            start = cmd.rfind("\n", 0, m.start()) + 1
            end = cmd.find("\n", m.end())
            if end == -1:
                end = len(cmd)
            return cmd[start:end].strip()
    return ""


def first_line(cmd):
    for ln in cmd.splitlines():
        if ln.strip():
            return ln.strip()
    return ""


def extract_text(content):
    """tool_result.content 可能是 str 或 list[{type:text,text:...}]。"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for it in content:
            if isinstance(it, dict) and it.get("type") == "text":
                parts.append(it.get("text", ""))
            elif isinstance(it, str):
                parts.append(it)
        return "\n".join(parts)
    return "" if content is None else str(content)


def scan_file(path):
    """扫描单个 jsonl 文件。返回 (findings_list, error_or_None)。"""
    findings = []
    bash_uses = {}   # tool_use_id -> 元信息
    results = {}     # tool_use_id -> result 文本
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                msg = obj.get("message")
                content = msg.get("content") if isinstance(msg, dict) else None
                if not isinstance(content, list):
                    continue
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    ctype = c.get("type")
                    if ctype == "tool_use" and c.get("name") == "Bash":
                        cmd = (c.get("input") or {}).get("command", "") or ""
                        bash_uses[c.get("id")] = {
                            "line": lineno,
                            "command": cmd,
                            "timestamp": obj.get("timestamp", ""),
                            "sessionId": obj.get("sessionId", ""),
                            "cwd": obj.get("cwd", ""),
                            "uuid": obj.get("uuid", ""),
                        }
                    elif ctype == "tool_result":
                        tid = c.get("tool_use_id")
                        if tid:
                            # 同一 id 可能多次出现，保留最长那份（更可能含症状）
                            txt = extract_text(c.get("content"))
                            if len(txt) > len(results.get(tid, "")):
                                results[tid] = txt
    except Exception as e:
        return [], f"{path}: {e}"

    for tid, u in bash_uses.items():
        cmd = u["command"]
        danger = match_danger(cmd)
        text = results.get(tid, "")
        sym_hits, sym_names = match_symptoms(text)
        symptom = bool(sym_hits)
        if not danger and not symptom:
            continue
        if danger and symptom:
            sev = "CONFIRMED"
        elif danger:
            sev = "POTENTIAL"
        else:
            sev = "SUSPECT"
        findings.append({
            "severity": sev,
            "file": str(path),
            "line": u["line"],
            "sessionId": u["sessionId"],
            "timestamp": u["timestamp"],
            "cwd": u["cwd"],
            "tool_use_id": tid,
            "danger": danger,
            "danger_line": danger_line(cmd),
            "first_line": first_line(cmd),
            "symptom_samples": sym_hits[:3],
            "missing_commands": sym_names[:6],
        })
    return findings, None


def main():
    ap = argparse.ArgumentParser(
        description="扫描 Claude Code jsonl 日志，定位 path 环境变量覆盖问题"
    )
    ap.add_argument("directory", help="要扫描的目录（递归查找 *.jsonl）")
    ap.add_argument("--json", metavar="PATH", help="额外输出 JSON 报告到该文件")
    ap.add_argument("--show-all", action="store_true", help="同时显示 POTENTIAL/SUSPECT")
    ap.add_argument("--jobs", type=int, default=1, help="并行进程数，默认 1")
    ap.add_argument("--max", type=int, default=50, help="每类详情最多显示条数，默认 50")
    args = ap.parse_args()

    root = Path(args.directory)
    if not root.exists():
        print("目录不存在:", args.directory)
        sys.exit(1)
    files = sorted(root.rglob("*.jsonl"))
    if not files:
        print("未找到任何 .jsonl 文件:", args.directory)
        return

    print(f"扫描 {len(files)} 个 jsonl 文件 ...")
    all_findings = []
    errors = []

    if args.jobs and args.jobs > 1:
        from concurrent.futures import ProcessPoolExecutor
        with ProcessPoolExecutor(max_workers=args.jobs) as ex:
            for fnds, err in ex.map(scan_file, [str(p) for p in files]):
                if err:
                    errors.append(err)
                    continue
                all_findings.extend(fnds)
    else:
        for p in files:
            fnds, err = scan_file(str(p))
            if err:
                errors.append(err)
                continue
            all_findings.extend(fnds)

    sev_order = {"CONFIRMED": 0, "POTENTIAL": 1, "SUSPECT": 2}
    all_findings.sort(key=lambda x: (sev_order.get(x["severity"], 9), x["file"], x["line"]))
    sev_cnt = Counter(f["severity"] for f in all_findings)
    hit_files = {f["file"] for f in all_findings if f["severity"] == "CONFIRMED"}

    print("\n==== 汇总 ====")
    print(f"扫描文件数    : {len(files)}")
    print(f"读取异常文件  : {len(errors)}")
    print(f"CONFIRMED     : {sev_cnt.get('CONFIRMED', 0)}  （危险模式 + 症状，强证据）涉及 {len(hit_files)} 个文件")
    print(f"POTENTIAL     : {sev_cnt.get('POTENTIAL', 0)}  （仅危险模式，可能已触发）")
    print(f"SUSPECT       : {sev_cnt.get('SUSPECT', 0)}  （仅 command not found，原因待查）")
    if errors:
        print(f"\n[警告] {len(errors)} 个文件读取异常（已跳过），示例:\n  {errors[0]}")

    def show(level, limit):
        items = [f for f in all_findings if f["severity"] == level]
        if not items:
            return
        print(f"\n==== {level} 详情（共 {len(items)} 条，显示前 {min(limit, len(items))}）====")
        for f in items[:limit]:
            print(f"\n[{Path(f['file']).name}]  行 {f['line']}    {f['timestamp']}")
            print(f"  会话     : {f['sessionId']}")
            print(f"  危险模式 : {', '.join(f['danger'])}")
            if f["missing_commands"]:
                print(f"  丢失命令 : {', '.join(f['missing_commands'])}")
            if f["symptom_samples"]:
                print(f"  症状样本 : {f['symptom_samples'][0][:80]}")
            print(f"  命令首行 : {f['first_line'][:70]}")
            print(f"  触发行   : {f['danger_line'][:70]}")

    show("CONFIRMED", args.max)
    if args.show_all:
        show("POTENTIAL", args.max)
        show("SUSPECT", args.max)

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fp:
            json.dump(
                {"summary": dict(sev_cnt), "findings": all_findings},
                fp, ensure_ascii=False, indent=2,
            )
        print(f"\nJSON 报告已写入: {args.json}")


if __name__ == "__main__":
    main()
