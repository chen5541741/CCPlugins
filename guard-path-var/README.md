# guard-path-var — PATH 环境变量保护钩子

## 问题

在 **zsh** 中，小写数组 `path` 与大写标量 `PATH` 通过 `typeset -T PATH path` 绑定（tied）。  
当脚本或命令把 `path` 当作普通变量名使用时——典型用法如：

- `for path in ...`
- `read path`
- `path=...`

第一轮迭代就会把 `PATH` 覆盖成单个目录，导致后续命令（`curl`、`grep`、`head`、`python3` 等）报 `command not found`。

**bash** 不受影响（`path` 和 `PATH` 相互独立），本钩子仅在 zsh 环境下生效。

## 工作原理

`guard-path-var.sh` 是一个 **PreToolUse** 钩子，在每次 Bash 工具调用前检查命令文本：

1. 从 stdin 读取 JSON 格式的 tool 调用信息
2. 提取 `tool_input.command` 字段
3. 用正则匹配三类危险模式：
   - `for/select path` 循环变量
   - `read path` 变量
   - 裸 `path=...` 赋值（排除 `PATH=`、`mypath=`、`filepath=`、`url_path=` 等）
4. 命中任一模式 → **block**（阻止执行）并给出明确的中文解释和修改建议
5. 未命中 → **allow**（放行）

依赖检测：自动检测 `jq` → `python3` → `python`，三者都不可用时 **fail open**（放行，不阻塞调用）。

## 安装

### 作为 CCPlugin 安装（推荐）

确保本插件已注册到 marketplace，然后在 Claude Code 中执行插件安装命令。

### 手动安装到单个项目

编辑项目的 `.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/path/to/guard-path-var.sh",
            "timeout": 1800
          }
        ]
      }
    ]
  }
}
```

### 用户级安装（全局生效）

编辑 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/guard-path-var.sh",
            "timeout": 1800
          }
        ]
      }
    ]
  }
}
```

## 辅助诊断工具

`tools/scan_path_overwrite.py` 是一个独立的 Python 脚本，用于**事后扫描** Claude Code 会话日志（`.jsonl` 文件），发现已经发生的 PATH 覆盖问题。

### 用法

```bash
# 扫描指定目录下的所有 jsonl 日志（递归）
python tools/scan_path_overwrite.py /path/to/claude/logs

# 显示全部级别（默认只显示 CONFIRMED）
python tools/scan_path_overwrite.py /path/to/logs --show-all

# 输出 JSON 报告
python tools/scan_path_overwrite.py /path/to/logs --json report.json

# 多进程加速
python tools/scan_path_overwrite.py /path/to/logs --jobs 4
```

### 扫描分类

| 级别 | 含义 |
|------|------|
| **CONFIRMED** | 命令中检测到 `path` 变量赋值 **且** 该次调用的结果中出现 `command not found`。强证据，确认为 PATH 覆盖导致。 |
| **POTENTIAL** | 仅检测到 `path` 变量赋值模式，但结果中未出现 `command not found`（可能被绝对路径规避，或日志不完整）。 |
| **SUSPECT** | 仅出现 `command not found` 但未检测到 `path` 模式（原因待查，可能是其他环境问题）。 |

## 文件结构

```
guard-path-var/
├── .claude-plugin/
│   └── plugin.json        # 插件元数据
├── hooks/
│   └── hooks.json         # Hook 注册配置
├── scripts/
│   └── guard-path-var.sh  # PreToolUse 钩子脚本（核心）
├── tools/
│   └── scan_path_overwrite.py  # 日志分析辅助工具
└── README.md              # 本文件
```
