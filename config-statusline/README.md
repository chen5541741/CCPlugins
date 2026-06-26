# config-statusline

一键安装本 plugin 自带的 statusline 脚本到 Claude Code 全局配置。封装了
内置 `/statusline` 的标准配置流程，并自动按平台选择实现：

| 平台 | 脚本 | 依赖 |
|---|---|---|
| Windows | `statusline.ps1`（PowerShell） | 系统自带 PowerShell 5.1 即可，无需 jq |
| macOS / Linux | `statusline.sh`（Bash） | `bash` + `jq`（必需）、`git`（可选） |

两个版本输出格式一致：模型名、当前目录、git 分支、context 进度条、累计费用、耗时。

## 安装

```
/plugin install config-statusline@MSPlugins
```

## 使用

启用 plugin 后，在 Claude Code 中执行：

```
/install-statusline
```

Claude 会依次：

1. 探测平台（Windows / macOS / Linux）和 PowerShell 可用性
2. 展示要安装的脚本前 10 行让你确认
3. 备份你原有的 `~/.claude/statusline.sh` 和 `.ps1`（如有）
4. 把对应平台的脚本复制到 `~/.claude/`
5. 把标准 `statusLine` 字段写入 `~/.claude/settings.json`（已有则询问后覆盖）
6. 提示当前平台的依赖与注意事项

完成后重启 Claude Code 或新开一个会话即可看到状态行。

## 跨平台运行同一份 settings.json？

不建议。`statusLine.command` 在两个平台上写法不同（`bash ~/.claude/...` vs
`powershell -File ...`）。如果你确实在 Windows 和 *nix 间共用同一份
`settings.json`，建议把 statusLine 写在各自机器的本地覆盖里，而不是同步过去。

## 为什么不让 settings.json 直接引用 plugin 内的脚本？

Claude Code 的 `statusLine.command` 字段**不支持** `${CLAUDE_PLUGIN_ROOT}`
变量替换；且 plugin 缓存路径会随版本变化（旧版本目录约 7 天后清理）。
所以脚本必须复制到一个稳定路径（用户家目录），settings.json 引用该稳定
路径，plugin 升级才不会让 statusLine 失效。

## 输出预览

```
[claude-opus-4-8] 📁 D:/rin/github/CCPlugins | 🌿 main
████████░░ 80% | $1.23 | ⏱️ 12m 34s
```

- context 进度条：≥70% 黄、≥90% 红
- 费用累计为当前 session
- 耗时为 Claude Code 报告的 `cost.total_duration_ms`

## 自定义脚本

直接编辑 `~/.claude/statusline.sh` 或 `~/.claude/statusline.ps1`。本 plugin
不会再覆盖它们，除非你再次主动执行 `/install-statusline`（这种情况会先
自动备份成 `.bak.<timestamp>`）。

## 卸载

```
/plugin uninstall config-statusline@MSPlugins
```

卸载只移除 plugin 本体。`~/.claude/statusline.{sh,ps1}` 与 `settings.json`
中的 `statusLine` 字段需要你手动清理。
