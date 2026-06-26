#!/usr/bin/env bash
# push.sh — KOOK 单向推送脚本（bash + curl + jq 版）。
#
# 通过 KOOK 开放平台 REST API 发送一段文字到频道或私聊。
# 不接收事件，不依赖 webhook / websocket。
#
# 依赖：bash 3.2+、curl、jq。
#
# CLI:
#   ./push.sh --type {channel|dm} --target <id> [--markdown] [MESSAGE]
#
# 配置（来源优先级：CLI > 环境变量 > .env）：
#   KOOK_BOT_TOKEN    必填
#   KOOK_TARGET_TYPE  --type 省略时回退
#   KOOK_TARGET_ID    --target 省略时回退
#
# .env 加载顺序（先加载者优先，模拟 python-dotenv override=False）：
#   1) $PWD/.env                     （当前工作目录）
#   2) $CLAUDE_PROJECT_DIR/.env      （Claude Code 注入的项目根，作为 hook 时一般等于 1）
#   3) $CLAUDE_PLUGIN_ROOT/.env      （plugin 安装目录，作为所有项目共享的全局回退）
#   4) $SCRIPT_DIR/.env              （脚本所在目录，本仓库自测/兜底）
#   5) $SCRIPT_DIR/../.env           （仓库根 .env，开发自测兜底）
# 加载逻辑见 _load_env.sh，hook 脚本（on-*.sh）走同一套。

set -euo pipefail

API_BASE="https://www.kookapp.cn/api/v3"
TIMEOUT=10

# KOOK content type
TYPE_PLAIN=1
TYPE_KMARKDOWN=9

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: push.sh [-h] [--type {channel,dm}] [--target TARGET] [--markdown] [MESSAGE]

向 KOOK 频道或私聊推送一段文字消息。
--type / --target 未提供时回退到环境变量 KOOK_TARGET_TYPE / KOOK_TARGET_ID
（同样可写在 .env 中）。

options:
  -h, --help           显示本帮助
  --type {channel,dm}  目标类型：channel 频道，dm 私聊；省略则读 KOOK_TARGET_TYPE
  --target TARGET      目标 ID：channel 时为 channel_id；dm 时为 user_id；
                       省略则读 KOOK_TARGET_ID
  --markdown           以 KMarkdown (type=9) 发送，默认是纯文本 (type=1)

positional:
  MESSAGE              消息正文；省略时从 stdin 读取
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

# ----- 加载 .env -----
# 加载逻辑统一抽到 _load_env.sh，hook 脚本也走这套。
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_load_env.sh"
kook_load_env

# ----- 参数解析 -----
TARGET_TYPE=""
TARGET_ID=""
MARKDOWN=0
MESSAGE=""
HAS_MESSAGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --type)
      [ $# -ge 2 ] || die "--type 缺少参数"
      TARGET_TYPE="$2"
      shift 2
      ;;
    --type=*)
      TARGET_TYPE="${1#--type=}"
      shift
      ;;
    --target)
      [ $# -ge 2 ] || die "--target 缺少参数"
      TARGET_ID="$2"
      shift 2
      ;;
    --target=*)
      TARGET_ID="${1#--target=}"
      shift
      ;;
    --markdown)
      MARKDOWN=1
      shift
      ;;
    --)
      shift
      if [ $# -ge 1 ]; then
        MESSAGE="$1"
        HAS_MESSAGE=1
        shift
      fi
      ;;
    -*)
      die "未知选项: $1"
      ;;
    *)
      if [ "$HAS_MESSAGE" -eq 1 ]; then
        die "多余的位置参数: $1"
      fi
      MESSAGE="$1"
      HAS_MESSAGE=1
      shift
      ;;
  esac
done

# ----- 解析目标（CLI 优先，环境变量兜底）-----
: "${TARGET_TYPE:=${KOOK_TARGET_TYPE:-}}"
: "${TARGET_ID:=${KOOK_TARGET_ID:-}}"

[ -n "$TARGET_TYPE" ] || die "未提供 --type，也未在环境中找到 KOOK_TARGET_TYPE。"
case "$TARGET_TYPE" in
  channel|dm) ;;
  *) die "type 取值无效: '$TARGET_TYPE'，必须是 channel 或 dm。" ;;
esac
[ -n "$TARGET_ID" ] || die "未提供 --target，也未在环境中找到 KOOK_TARGET_ID。"

# ----- token -----
TOKEN="${KOOK_BOT_TOKEN:-}"
[ -n "$TOKEN" ] || die "未找到 KOOK_BOT_TOKEN。请通过环境变量或 .env 文件提供。"

# ----- 消息正文：位置参数优先；否则读 stdin；stdin 是 TTY 则报错 -----
if [ "$HAS_MESSAGE" -eq 0 ]; then
  if [ -t 0 ]; then
    die "未提供消息内容。请通过位置参数传入，或从 stdin 管道输入。"
  fi
  MESSAGE="$(cat)"
fi

# 消息空白判定：strip 后非空才放行
trimmed="$(printf '%s' "$MESSAGE" | tr -d '[:space:]')"
[ -n "$trimmed" ] || die "消息内容为空。"

# ----- endpoint -----
case "$TARGET_TYPE" in
  channel) URL="$API_BASE/message/create" ;;
  dm)      URL="$API_BASE/direct-message/create" ;;
esac

# ----- 构造 payload（用 jq 防注入）-----
if [ "$MARKDOWN" -eq 1 ]; then
  TYPE_VALUE="$TYPE_KMARKDOWN"
else
  TYPE_VALUE="$TYPE_PLAIN"
fi

# jq -c：紧凑输出，结构无空白，避免 Windows CRT text mode 在空白处插 \r
# tr -d '\r'：兜底去掉 jq stdout 可能注入的 CR（仅 Windows 出现，*nix 无副作用）
# curl --data-binary @-：通过 stdin 传 body，逐字节透传，避开 --data 对 \n 的特殊处理
RESP="$(
  jq -cn \
    --argjson type "$TYPE_VALUE" \
    --arg target_id "$TARGET_ID" \
    --arg content "$MESSAGE" \
    '{type: $type, target_id: $target_id, content: $content}' \
  | tr -d '\r' \
  | curl --silent --show-error --max-time "$TIMEOUT" \
      -X POST "$URL" \
      -H "Authorization: Bot $TOKEN" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data-binary @-
)" || die "网络请求失败 (curl 退出码 $?)"

# ----- 解析返回 -----
if ! echo "$RESP" | jq -e . >/dev/null 2>&1; then
  echo "error: 无法解析返回体: $(printf '%s' "$RESP" | head -c 500)" >&2
  exit 1
fi

CODE="$(jq -r '.code // "null"' <<<"$RESP")"
if [ "$CODE" != "0" ]; then
  MSG="$(jq -r '.message // "(无错误信息)"' <<<"$RESP")"
  echo "error: KOOK 返回失败 code=$CODE message=$MSG" >&2
  exit 1
fi

MSG_ID="$(jq -r '.data.msg_id // empty' <<<"$RESP")"
[ -n "$MSG_ID" ] || die "返回成功但缺少 msg_id，原始返回: $RESP"

printf '%s\n' "$MSG_ID"
