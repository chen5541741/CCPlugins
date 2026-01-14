# Claude Code 插件安装环境设置
# 使用方法: source ~/setup-claude-env.sh
# 或: . ~/setup-claude-env.sh

# 创建临时目录（与 ~/.claude 同一子卷）
mkdir -p "$HOME/.cache/tmp"

# 设置 TMPDIR
export TMPDIR="$HOME/.cache/tmp"

echo "✓ TMPDIR 已设置为: $TMPDIR"
echo "现在可以运行 claude 并使用 /plugin 安装插件了"
