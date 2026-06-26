#!/usr/bin/env bash
# 仅供 source，不要直接执行。
#
# 提供 kook_load_env：按候选路径顺序加载 .env，先加载者优先
# （模拟 python-dotenv override=False）。已经在 env 里的变量不会被覆盖，
# 多个 .env 文件之间互补（项目级覆盖全局级）。
#
# 用法（最简）—— 调用方无需传任何参数：
#   . "$(dirname "${BASH_SOURCE[0]}")/_load_env.sh"
#   kook_load_env
#
# 用法（显式指定脚本目录，覆盖自动推导）：
#   kook_load_env "/path/to/scripts"
#
# 比 `set -a; source .env` 更稳：
#   * 不会被 .env 里的 `$xxx` `` `cmd` `` 之类二次展开
#   * 容忍值里含空格、引号
#   * # 注释、空行安全
#   * 自动去掉值首尾的成对引号（单/双引号都行）
#   * 自动剥离 CRLF 行尾的 \r
#
# 候选 .env 路径（按优先级递减，先到先得；已存在 env 变量不会被覆盖）：
#   0) $KOOK_DOTENV                  （环境变量显式指定的路径，最高优先级；便于 CI / 临时覆盖）
#   1) $PWD/.env                     （当前工作目录）
#   2) $CLAUDE_PROJECT_DIR/.env      （Claude Code 注入的项目根；hook 场景下一般等于 1）
#   3) $CLAUDE_PLUGIN_ROOT/.env      （plugin 安装目录，作为所有项目共享的全局回退）
#   4) <调用脚本所在目录>/.env       （即"当前运行脚本同目录"，自动从 BASH_SOURCE 推导）
#   5) <调用脚本所在目录>/../.env    （仓库根 .env，开发自测兜底）

# 解析单个 .env 文件。仅当变量当前未设置或为空时才填入。
_kook_load_env_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local line key val
  # 用 IFS= read -r 防止 bash 解析特殊字符
  while IFS= read -r line || [ -n "$line" ]; do
    # 去掉行尾可能的 \r（Windows / CRLF 兼容）
    line="${line%$'\r'}"
    case "$line" in
      ''|\#*) continue ;;
      *=*)
        key="${line%%=*}"
        val="${line#*=}"
        # 去掉首尾成对引号
        case "$val" in
          \"*\") val="${val#\"}"; val="${val%\"}" ;;
          \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        # 仅当当前 env 未设置（或为空）时才填入
        if [ -z "${!key:-}" ]; then
          export "$key=$val"
        fi
        ;;
    esac
  done < "$f"
}

# 推导"调用方脚本目录"用的是 ${BASH_SOURCE[1]}：
#   - BASH_SOURCE[0] = 当前函数所在文件 = _load_env.sh
#   - BASH_SOURCE[1] = 调用本函数的脚本（即 push.sh / on-*.sh 等）
# 推导逻辑直接内联在 kook_load_env 里，避免再嵌一层函数让索引偏移。

# 按候选路径加载。可显式传 script_dir 覆盖自动推导。
kook_load_env() {
  local script_dir="${1:-}"
  if [ -z "$script_dir" ]; then
    # 自动从 BASH_SOURCE 链推导调用方所在目录
    local src="${BASH_SOURCE[1]:-}"
    if [ -n "$src" ]; then
      script_dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd)" || script_dir=""
    fi
    # 极端兜底：交互式 shell 直接调用，无 BASH_SOURCE[1]
    [ -z "$script_dir" ] && script_dir="$PWD"
  fi

  local -a candidates=()
  [ -n "${KOOK_DOTENV:-}" ]         && candidates+=("$KOOK_DOTENV")
  [ -n "${PWD:-}" ]                 && candidates+=("$PWD/.env")
  [ -n "${CLAUDE_PROJECT_DIR:-}" ]  && candidates+=("$CLAUDE_PROJECT_DIR/.env")
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]  && candidates+=("$CLAUDE_PLUGIN_ROOT/.env")
  [ -n "$script_dir" ]              && candidates+=("$script_dir/.env")
  [ -n "$script_dir" ]              && candidates+=("$script_dir/../.env")

  local seen="" f
  for f in "${candidates[@]}"; do
    case "$seen" in *"|$f|"*) continue ;; esac
    seen="$seen|$f|"
    _kook_load_env_file "$f"
  done
}
