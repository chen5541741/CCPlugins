#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scan_path_overwrite.py
遍历目录下的 Claude Code 会话 jsonl 日志，定位 "path 环境变量被覆盖" 问题，
并验证 hook 防护是否生效。

问题原理
--------
在 zsh 中，小写数组 `path` 与大写标量 `PATH` 是 tied（绑定）的。当命令把 `path`
当作变量名（典型：`for path in ...`），第一轮迭代就会把 PATH 覆盖成单个目录，
导致 curl/grep/head/python3 等大量报 "command not found"。

判定逻辑（三特征：危险模式 / 被拦截 / 症状）
--------
  - danger  : 命令文本里出现 path 变量赋值模式
              （for/select path、read path、裸 path=）
  - denied  : 该调用被拒绝执行 —— 顶层字段 toolDenialKind 非空（结构化，最可靠），
              或 result 文本含 hook 阻断特征词（文本兜底）
  - symptom : result 里出现 command-not-found 类错误
              （注意：被拦截时 symptom 强制为假，因为 hook 阻断文本里也写了
               "command not found" 这个词作为解释，不能算真症状）

四态分类
--------
  - HOOKED    : danger 且 denied   —— hook 防护生效，命令被拦截，未执行
  - LEAKED    : danger 且 symptom  —— 命令真的执行并破坏了 PATH（hook 漏网 / 未装 hook）
  - POTENTIAL : 仅 danger          —— 危险模式，但既未被拦截也未观察到症状
  - SUSPECT   : 仅 symptom         —— command not found 但无 path 模式，原因待查

用法
--------
  python scan_path_overwrite.py <目录> [选项]

  选项：
    --json PATH       额外把结构化报告写入该 JSON 文件
    --show-all        同时显示 POTENTIAL / SUSPECT（默认只显示 HOOKED / LEAKED）
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

# hook 阻断文本兜底特征（toolDenialKind 缺失时用）
HOOK_TEXT_PATTERNS = [
    re.compile(r"typeset -T PATH path"),
    re.compile(r"tied to uppercase", re.IGNORECASE),
    re.compile(r"Rename the variable", re.IGNORECASE),
    re.compile(r"overwrites PATH", re.IGNORECASE),
]


def match_danger(cmd):
    return [name for rx, name in DANGER_PATTERNS if rx.search(cmd)]


def match_symptoms(text):
    hits = []
    for rx in SYMPTOM_PATTERNS:
        m = rx.search(text)
        if m:
            hits.append(m.group(0).strip().replace("\n", " "))
    names = re.findall(r"Command '([^']+)' is available in the following places", text)
    return hits, names


def is_denied(obj, text):
    """该 tool_result 所在记录是否表示命令被拒绝执行。"""
    if obj.get("toolDenialKind"):   # 结构化字段，最可靠（如 'permission-rule' / 'hook'）
        return True
    if any(rx.search(text) for rx in HOOK_TEXT_PATTERNS):
        return True
    return False


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
    results = {}     # tool_use_id -> {text, denied, denial_kind, is_error}
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
                            txt = extract_text(c.get("content"))
                            rec = {
                                "text": txt,
                                "denied": is_denied(obj, txt),
                                "denial_kind": obj.get("toolDenialKind"),
                                "is_error": c.get("is_error"),
                            }
                            # 同一 id 可能多次出现，保留文本更长的那份
                            if len(txt) >= len(results.get(tid, {}).get("text", "")):
                                results[tid] = rec
    except Exception as e:
        return [], f"{path}: {e}"

    for tid, u in bash_uses.items():
        cmd = u["command"]
        danger = match_danger(cmd)
        r = results.get(tid)
        denied = bool(r and r["denied"])
        text = r["text"] if r else ""
        sym_hits, sym_names = match_symptoms(text)
        # 关键：被拦截时，拦截文本里的 "command not found" 字样不算真症状
        symptom = (not denied) and bool(sym_hits)

        if not danger and not symptom:
            continue  # 与 path 问题无关（含「被拦截但非 path 命令」）
        if danger and denied:
            sev = "HOOKED"
        elif danger and symptom:
            sev = "LEAKED"
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
            "denied": denied,
            "denial_kind": r.get("denial_kind") if r else None,
            "symptom_samples": sym_hits[:3] if symptom else [],
            "missing_commands": sym_names[:6] if symptom else [],
        })
    return findings, None


def main():
    ap = argparse.ArgumentParser(
        description="扫描 Claude Code jsonl 日志，定位 path 环境变量覆盖问题并验证 hook 防护"
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

    sev_order = {"HOOKED": 0, "LEAKED": 1, "POTENTIAL": 2, "SUSPECT": 3}
    all_findings.sort(key=lambda x: (sev_order.get(x["severity"], 9), x["file"], x["line"]))
    sev_cnt = Counter(f["severity"] for f in all_findings)

    hooked = sev_cnt.get("HOOKED", 0)
    leaked = sev_cnt.get("LEAKED", 0)
    potential = sev_cnt.get("POTENTIAL", 0)
    suspect = sev_cnt.get("SUSPECT", 0)
    # 防护有效率：在被拦截或漏网的 path 命令中，被拦截的占比
    tried = hooked + leaked
    eff = (hooked / tried * 100.0) if tried else None

    print("\n==== 汇总 ====")
    print(f"扫描文件数    : {len(files)}")
    print(f"读取异常文件  : {len(errors)}")
    print(f"HOOKED        : {hooked}  （hook 拦截成功，防护生效 ✓）")
    print(f"LEAKED        : {leaked}  （命令真执行 + PATH 被破坏，hook 漏网/未装 ✗）")
    print(f"POTENTIAL     : {potential}  （危险模式，但未拦截也未观察到症状）")
    print(f"SUSPECT       : {suspect}  （command not found 但非 path 模式，原因待查）")
    if tried:
        print(f"path 危险命令 : 共 {tried} 次（拦截 {hooked} + 漏网 {leaked}），"
              f"防护有效率 {eff:.1f}%")
    else:
        print("path 危险命令 : 0 次")
    if leaked:
        print(f"\n[!] 发现 {leaked} 处 LEAKED：hook 未拦住或未启用，需排查！")
    if errors:
        print(f"\n[警告] {len(errors)} 个文件读取异常（已跳过），示例:\n  {errors[0]}")

    def show(level, limit, banner_note=""):
        items = [f for f in all_findings if f["severity"] == level]
        if not items:
            return
        print(f"\n==== {level} 详情（共 {len(items)} 条，显示前 {min(limit, len(items))}）{banner_note} ====")
        for f in items[:limit]:
            print(f"\n[{Path(f['file']).name}]  行 {f['line']}    {f['timestamp']}")
            print(f"  会话     : {f['sessionId']}")
            print(f"  危险模式 : {', '.join(f['danger'])}")
            if f.get("denial_kind"):
                print(f"  拦截类型 : toolDenialKind={f['denial_kind']}")
            if f["missing_commands"]:
                print(f"  丢失命令 : {', '.join(f['missing_commands'])}")
            if f["symptom_samples"]:
                print(f"  症状样本 : {f['symptom_samples'][0][:80]}")
            print(f"  命令首行 : {f['first_line'][:70]}")
            print(f"  触发行   : {f['danger_line'][:70]}")

    # 默认显示 HOOKED 与 LEAKED；--show-all 再加 POTENTIAL / SUSPECT
    show("HOOKED", args.max, "（防护生效）")
    show("LEAKED", args.max, "（问题泄漏 ✗）")
    if args.show_all:
        show("POTENTIAL", args.max)
        show("SUSPECT", args.max)

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fp:
            json.dump(
                {
                    "summary": {
                        "files": len(files),
                        "HOOKED": hooked, "LEAKED": leaked,
                        "POTENTIAL": potential, "SUSPECT": suspect,
                        "path_attempts": tried,
                        "effectiveness_pct": round(eff, 1) if eff is not None else None,
                    },
                    "findings": all_findings,
                },
                fp, ensure_ascii=False, indent=2,
            )
        print(f"\nJSON 报告已写入: {args.json}")


if __name__ == "__main__":
    main()
