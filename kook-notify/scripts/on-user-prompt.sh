#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook：记录回合开始时间到 /tmp。
#
# 每当用户提交一条 prompt，写当前 unix epoch 到
#   /tmp/cc-turn-<session_id>.start
# 后续的 Stop hook 会读取此文件计算耗时。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/_load_env.sh"
kook_load_env

# 总开关：KOOK_NOTIFY=0 时彻底不工作
[ "${KOOK_NOTIFY:-1}" = "0" ] && exit 0

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' | tr -d '\r')"
[ -z "$session_id" ] && exit 0

date +%s > "/tmp/cc-turn-${session_id}.start"
