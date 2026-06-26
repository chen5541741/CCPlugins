# kook-notify

Claude Code plugin：通过 KOOK Bot 把 Claude Code 长任务完成、需要注意等事件单向推送到频道或私聊。

附带可独立调用的 `push.sh`，纯 REST API，不接收事件、不依赖 webhook / websocket。

## 依赖

`bash`、`curl`、`jq`。三者在多数 Linux/macOS 系统是标配（macOS 默认 bash 3.2，本脚本兼容）。Windows 用户使用 Git Bash 即可。无 Python、无虚拟环境。

## 安装

通过 marketplace 安装：

```bash
# 进入 Claude Code
/plugin marketplace add https://github.com/<owner>/CCPlugins   # 或本地 git 路径
/plugin install kook-notify@MSPlugins
```

安装后插件目录由 Claude Code 管理（`${CLAUDE_PLUGIN_ROOT}`）。

## 配置

把 `.env.example` 复制为 `.env` 并填入 token，**两种放法任选**：

| 位置 | 适用场景 |
|---|---|
| `${CLAUDE_PROJECT_DIR}/.env` | 每个项目独立配置（推送到不同频道） |
| `${CLAUDE_PLUGIN_ROOT}/.env` | 全局共享配置（所有项目用同一套） |

加载优先级：**项目目录 > plugin 根目录**。先匹配到的 `.env` 生效。

```ini
# 必填：Bot Token
KOOK_BOT_TOKEN=你的 bot token

# 推送默认目标
KOOK_TARGET_TYPE=channel        # channel 或 dm
KOOK_TARGET_ID=1234567890       # channel_id 或 user_id

# Claude Code hook（可选）
KOOK_NOTIFY=1                   # 0 = 关闭所有 hook 推送；其他/未设 = 开
KOOK_NOTIFY_THRESHOLD=60        # Stop hook 触发的最小耗时（秒），默认 60
```

Token 在 [KOOK 开发者后台](https://developer.kookapp.cn/app/index) Bot → "机器人连接模式" 处获取。

## Hook 行为

| 事件 | 行为 |
|---|---|
| `UserPromptSubmit` | 记录回合开始时间到 `/tmp/cc-turn-<session>.start` |
| `Stop` | 若耗时 ≥ `KOOK_NOTIFY_THRESHOLD`，推送 `[<project>] Claude Code 完成 · <耗时>` |
| `Notification` | 推送 `[<project>] Claude Code 需要你的注意 · <message>` |

启用条件：`.env` 配好 `KOOK_BOT_TOKEN` + `KOOK_TARGET_*`；`KOOK_NOTIFY` 未设或非 `0`。

临时关闭单次会话：`KOOK_NOTIFY=0 claude`。

## 手动调用 push.sh

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/push.sh" "服务挂了"
echo "..." | "${CLAUDE_PLUGIN_ROOT}/scripts/push.sh" --markdown
"${CLAUDE_PLUGIN_ROOT}/scripts/push.sh" --type dm --target <user_id> "hi"
```

成功 stdout 输出 `msg_id`；失败 stderr 输出错误，`exit 1`。

## 取 ID 提示

在 KOOK 客户端打开"开发者模式"后，右键频道或用户头像可"复制 ID"。

私聊前提：目标用户必须和 bot 至少共享一个服务器，否则 KOOK 会拒绝投递。
