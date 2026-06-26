#!/usr/bin/env bash
# 仅供 source。提供 kook_session_title：从 Claude Code transcript 提取
# 最后一条 `ai-title` 记录（即 /status 里显示的 "Session name"）。
#
# 用法：
#   . "$SCRIPT_DIR/_session_title.sh"
#   title="$(kook_session_title "$transcript_path")"
#
# 输入：transcript_path —— hook input JSON 中的 .transcript_path 字段
# 输出：title 字符串到 stdout；找不到 / 文件不存在 / jq 失败时输出空串
# 不会失败退出：调用方按"是否非空"判断。

kook_session_title() {
  local path="${1:-}"
  [ -n "$path" ] || return 0
  [ -f "$path" ] || return 0

  # jsonl 默认 jq 按行处理：select 不匹配则该行无输出，匹配则输出 aiTitle。
  # tail -n1 取最后一条（也即最新生成的 title，Claude Code 可能多次重写）。
  # tr -d '\r' 兜底 jq.exe stdout 的 Windows text mode CRLF。
  jq -r 'select(.type=="ai-title") | .aiTitle // empty' "$path" 2>/dev/null \
    | tail -n1 \
    | tr -d '\r'
}
