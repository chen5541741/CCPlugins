#!/usr/bin/env bash
# Claude Code Stop hook：算耗时，超过阈值才推送 KOOK 通知。
#
# 读取 UserPromptSubmit hook 写下的 /tmp/cc-turn-<session_id>.start，
# 计算耗时；超过 KOOK_NOTIFY_THRESHOLD（默认 60s）才调 push.sh。
# 不论是否推送，都会清理 start 文件。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/_load_env.sh"
kook_load_env

[ "${KOOK_NOTIFY:-1}" = "0" ] && exit 0

threshold="${KOOK_NOTIFY_THRESHOLD:-60}"

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' | tr -d '\r')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' | tr -d '\r')"
[ -z "$cwd" ] && cwd="$PWD"

start_file="/tmp/cc-turn-${session_id}.start"
# 没拿到 session_id 或没记录开始时间：静默退出
if [ -z "$session_id" ] || [ ! -f "$start_file" ]; then
  exit 0
fi

start="$(cat "$start_file")"
rm -f "$start_file"
now="$(date +%s)"
elapsed=$(( now - start ))

if [ "$elapsed" -lt "$threshold" ]; then
  exit 0
fi

# 格式化耗时
if [ "$elapsed" -ge 60 ]; then
  m=$(( elapsed / 60 ))
  s=$(( elapsed % 60 ))
  dur="${m}m${s}s"
else
  dur="${elapsed}s"
fi

# 同时按 / 和 \ 切，兼容 Windows 反斜杠路径
proj="${cwd##*[\\/]}"
[ -z "$proj" ] && proj="$(basename "$cwd")"
msg="[${proj}] Claude Code 完成 · ${dur}"

exec "$SCRIPT_DIR/push.sh" "$msg"
