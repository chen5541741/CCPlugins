#!/usr/bin/env bash
# Claude Code Notification hook：把"需要你的注意"事件推到 KOOK。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for f in \
  "${CLAUDE_PROJECT_DIR:-}/.env" \
  "${CLAUDE_PLUGIN_ROOT:-}/.env" \
  "$SCRIPT_DIR/../.env"
do
  [ -n "$f" ] && [ -f "$f" ] || continue
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
  break
done

[ "${KOOK_NOTIFY:-1}" = "0" ] && exit 0

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
notif_msg="$(printf '%s' "$input" | jq -r '.message // empty')"
[ -z "$cwd" ] && cwd="$PWD"

proj="$(basename "$cwd")"
msg="[${proj}] Claude Code 需要你的注意"
if [ -n "$notif_msg" ]; then
  msg="${msg} · ${notif_msg}"
fi

exec "$SCRIPT_DIR/push.sh" "$msg"
