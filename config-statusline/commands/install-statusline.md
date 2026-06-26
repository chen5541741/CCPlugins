---
description: 把本 plugin 自带的 statusline 脚本安装到用户全局 Claude Code 配置（自动按平台选择 bash / PowerShell 版本）
allowed-tools: Read, Write, Edit, Bash
---

按照 Claude Code 内置 `/statusline` 的标准配置语义，帮用户启用本 plugin
自带的 statusline 脚本。严格按以下流程执行，每完成一步简短汇报。

## 1. 探测平台与家目录

通过 Bash 执行（**必须实际运行，不要凭推测**）：

```bash
uname -s
echo "HOME=$HOME"
echo "USERPROFILE=$USERPROFILE"
command -v pwsh && pwsh -Version
command -v powershell && powershell -Command '$PSVersionTable.PSVersion'
```

根据 `uname -s` 输出判定平台：

- `MINGW*` / `MSYS*` / `CYGWIN*` / 含 `NT-` → **Windows**
- `Darwin` → **macOS**
- 其他（`Linux` 等）→ **Linux**

记下：
- `PLATFORM`（windows / macos / linux）
- `CLAUDE_DIR`：
  - Windows 取 `$USERPROFILE/.claude`（Git Bash 下 `$HOME` 通常也指向同一处，但 settings.json 要被 cmd.exe / powershell.exe 读取，所以用 `$USERPROFILE` 衍生的绝对 Windows 路径更稳）
  - 其他平台取 `$HOME/.claude`
- 仅 Windows：`PWSH_EXE` —— 优先 `pwsh`（PS 7+），没有再退回 `powershell`（Win 自带 5.1）。两个都没有则告知用户必须装 PowerShell 才能继续。

## 2. 展示即将安装的脚本

按平台用 Read 读取：

- Windows：`${CLAUDE_PLUGIN_ROOT}/scripts/statusline.ps1`
- 其他：`${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh`

把**前 10 行**贴给用户确认。用户拒绝则停止。

## 3. 备份用户原有脚本（如存在）

对**两个**可能的文件都检查并备份（用户可能切换过平台，留着另一份的旧文件）：

```bash
TS=$(date +%s)
for f in "$CLAUDE_DIR/statusline.sh" "$CLAUDE_DIR/statusline.ps1"; do
  if [ -f "$f" ]; then
    cp "$f" "$f.bak.$TS"
    echo "备份: $f -> $f.bak.$TS"
  fi
done
```

`$CLAUDE_DIR` 用第 1 步算出的值。Windows 下 Git Bash 能正常处理 `C:/Users/...`
风格路径，直接传即可。

## 4. 复制脚本到家目录

按平台复制对应脚本：

**Windows**：
```bash
cp "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.ps1" "$CLAUDE_DIR/statusline.ps1"
```

**macOS / Linux**：
```bash
cp "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"
```

**重要**：不要让 settings.json 直接引用 `${CLAUDE_PLUGIN_ROOT}` —— 该路径会
随 plugin 升级变化。

## 5. 写入 settings.json 的 statusLine 字段

按平台决定 `command` 值：

- **Windows**（用 PS 5.1 时）：
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File "<USERPROFILE_WIN>\.claude\statusline.ps1"
  ```
  `<USERPROFILE_WIN>` 是 Windows 风格路径（反斜杠），通过下面这条 Bash 取：
  ```bash
  echo "$USERPROFILE" | sed 's|/|\\|g'
  ```
  如果第 1 步发现有 `pwsh`，把 `powershell` 换成 `pwsh`（更快、字符编码更稳）。

- **macOS / Linux**：
  ```
  bash ~/.claude/statusline.sh
  ```

读取 `<settings.json 路径>`（Windows: `$USERPROFILE/.claude/settings.json`；
其他: `$HOME/.claude/settings.json`）：

- **文件不存在**：用 Write 新建：
  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "<上面按平台拼好的命令>"
    }
  }
  ```

- **存在但没 `statusLine`**：用 Edit 插入 `statusLine` 对象。保留其他字段、
  缩进、尾随逗号风格不变。

- **存在且已有 `statusLine`**：把当前值展示给用户，**问一次是否覆盖**。
  - 同意：用 Edit 替换为新值。
  - 拒绝：保留原值，但脚本仍留在家目录（用户可自行调用）。

固定结构：

```json
"statusLine": {
  "type": "command",
  "command": "<按平台填>"
}
```

## 6. 平台相关依赖与提示

完成后**主动告知**用户：

**通用**：
- 重启 Claude Code 或新开会话后状态行生效。

**Windows**：
- 脚本不依赖 `jq`，但 `git` 分支显示依赖 `git` 在 PATH 中。没装 git 时分支段会被跳过，其余字段正常。
- 终端必须支持 ANSI 颜色（Windows Terminal、VS Code 集成终端、Claude Code 内建均 OK；老 conhost 可能不行）。
- 如果用了 `powershell.exe`（5.1）且看到 emoji 显示成方块，是字体问题，换 Cascadia Code / 升级 PS 7 (`pwsh`) 即可。

**macOS / Linux**：
- 脚本依赖 `bash`、`jq`、`git`。缺 `jq` 会输出空白，缺 `git` 则分支段被跳过。
- macOS 自带 bash 3.x 可正常运行该脚本。

## 7. 禁止事项

- 不要修改 `${CLAUDE_PLUGIN_ROOT}` 目录里的**任何**文件。
- settings.json 中**不要**引用 `${CLAUDE_PLUGIN_ROOT}` 路径。
- 未拿到用户同意前不要覆盖已存在的 `statusLine` 配置。
- 不要跨平台写错：Windows 必须用 `.ps1` + PowerShell；*nix 必须用 `.sh` + bash。如果两个脚本同时存在于家目录（用户跨平台用同一份 settings.json），保留另一平台那份文件不动，仅修改 settings.json 的 command 指向当前平台需要的那份。
