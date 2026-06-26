#!/usr/bin/env bash
# Claude Code Notification hook：把"需要你的注意"事件推到 KOOK。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/_load_env.sh"
. "$SCRIPT_DIR/_session_title.sh"
kook_load_env

[ "${KOOK_NOTIFY:-1}" = "0" ] && exit 0

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' | tr -d '\r')"
notif_msg="$(printf '%s' "$input" | jq -r '.message // empty' | tr -d '\r')"
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' | tr -d '\r')"
[ -z "$cwd" ] && cwd="$PWD"

# 兼容 Windows 反斜杠路径与 POSIX 正斜杠路径：先按 \ 切，再按 / 切。
# bash glob 中 [\\/] 不能正确表达"反斜杠或正斜杠"（\ 是 glob 转义符）。
proj="${cwd##*\\}"
proj="${proj##*/}"
[ -z "$proj" ] && proj="$(basename "$cwd")"

# KOOK_NOTIFY_DIY：用户自定义的设备识别前缀，留空则不出现。
# bash ${VAR:+word}：VAR 已定义且非空才展开为 [VAR]，否则整段为空字符串。
msg="${KOOK_NOTIFY_DIY:+[${KOOK_NOTIFY_DIY}]}[${proj}] Claude Code 需要你的注意"
if [ -n "$notif_msg" ]; then
  msg="${msg} · ${notif_msg}"
fi

# 追加 /status 里的 Session name（取 transcript 中最后一条 ai-title）
title="$(kook_session_title "$transcript_path")"
if [ -n "$title" ]; then
  msg="${msg}
📝 ${title}"
fi

exec "$SCRIPT_DIR/push.sh" "$msg"
