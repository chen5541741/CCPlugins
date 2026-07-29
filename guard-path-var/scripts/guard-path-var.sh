#!/bin/bash
# guard-path-var.sh — standalone PreToolUse(Bash) hook.
#
# Blocks `path` being used as a shell variable name. In zsh the lowercase
# `path` (array) is tied to uppercase `PATH` (scalar) via `typeset -T PATH
# path`, so `for path in ...`, `read path`, or `path=...` clobbers PATH and
# breaks curl/grep/head/python3 with "command not found". bash is immune
# (path and PATH are independent); this guard only matters under zsh.
#
# Self-contained: sources nothing, reads no project state. Copy this one
# file into any project to migrate.
#
# Install as CCPlugin (via hooks/hooks.json — auto-resolves ${CLAUDE_PLUGIN_ROOT}):
#   Refer to hooks/hooks.json in this plugin.
#
# Standalone project-level install (.claude/settings.json):
#   "hooks": {
#     "PreToolUse": [
#       { "matcher": "Bash", "hooks": [ {
#           "type": "command",
#           "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-path-var.sh",
#           "timeout": 1800
#       } ] }
#     ]
#   }
#
# User-level install (~/.claude/settings.json) — applies to ALL projects:
#   "command": "~/.claude/hooks/guard-path-var.sh"
#
# Patterns are case-sensitive (PATH= / export PATH= never match); char-class
# borders exclude mypath= / filepath= / url_path= / /path= / --path=, and bare
# $path / path/to (no '=') are left untouched.
# Requires jq OR python3/python on PATH (auto-detected). With neither, it
# fails open (allows) rather than risk breaking the host project's hooks.

set -u

INPUT=$(cat)

# Resolve a JSON parser once: prefer jq, else python3/python, else fail open.
PYTHON_BIN=""
if   command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
elif command -v python  >/dev/null 2>&1; then PYTHON_BIN=python
fi

if command -v jq >/dev/null 2>&1; then
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
elif [ -n "$PYTHON_BIN" ]; then
    COMMAND=$(printf '%s' "$INPUT" | "$PYTHON_BIN" -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(((d.get("tool_input") or {}).get("command") or ""))
except Exception:
    print("")' 2>/dev/null)
else
    exit 0
fi

# Only the Bash tool carries a shell command.
[ -z "$COMMAND" ] && exit 0

HIT=""
if   printf '%s' "$COMMAND" | grep -qE '(^|[^a-zA-Z0-9_])(for|select)[[:space:]]+path([[:space:]]+in|[[:space:]]*do|\(|;|$)'; then
    HIT="using 'path' as a for/select loop variable"
elif printf '%s' "$COMMAND" | grep -qE '(^|[^a-zA-Z0-9_])read[[:space:]]+path([^a-zA-Z0-9_]|$)'; then
    HIT="using 'path' as a read variable"
elif printf '%s' "$COMMAND" | grep -qE '(^|[^a-zA-Z0-9_/.-])path[[:space:]]*='; then
    HIT="assigning to the 'path' variable"
fi

[ -z "$HIT" ] && exit 0

REASON="In zsh (this session's shell), the lowercase 'path' (array) is tied to uppercase 'PATH' (scalar) via 'typeset -T PATH path'. Assigning to 'path' (e.g. 'for path in ...' or 'path=...') overwrites PATH, breaking curl/grep/head/python3 with \"command not found\". Detected: ${HIT}. Rename the variable to p / url_path / route / item (anything but 'path') and retry; or use absolute binary paths like /usr/bin/curl."

# Emit Claude Code PreToolUse block decision.
if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
else
    "$PYTHON_BIN" -c 'import sys,json; print(json.dumps({"decision":"block","reason":sys.argv[1]}))' "$REASON"
fi
exit 0
