#!/usr/bin/env bash
# Claude Code Notification hook：把"需要你的注意"事件推到 KOOK。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/_load_env.sh"
kook_load_env

[ "${KOOK_NOTIFY:-1}" = "0" ] && exit 0

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' | tr -d '\r')"
notif_msg="$(printf '%s' "$input" | jq -r '.message // empty' | tr -d '\r')"
[ -z "$cwd" ] && cwd="$PWD"

# 同时按 / 和 \ 切，兼容 Windows 反斜杠路径
proj="${cwd##*[\\/]}"
[ -z "$proj" ] && proj="$(basename "$cwd")"
msg="[${proj}] Claude Code 需要你的注意"
if [ -n "$notif_msg" ]; then
  msg="${msg} · ${notif_msg}"
fi

exec "$SCRIPT_DIR/push.sh" "$msg"
