# Claude Code statusline - Windows / PowerShell 版本
# 与 statusline.sh 输出格式一致，不依赖 jq；git 可选。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

# 读取 stdin JSON
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
$data = $raw | ConvertFrom-Json

$model       = $data.model.display_name
$dir         = $data.workspace.current_dir
$cost        = if ($null -ne $data.cost.total_cost_usd) { [double]$data.cost.total_cost_usd } else { 0 }
$pctRaw      = if ($null -ne $data.context_window.used_percentage) { [double]$data.context_window.used_percentage } else { 0 }
$pct         = [int][math]::Floor($pctRaw)
$durationMs  = if ($null -ne $data.cost.total_duration_ms) { [long]$data.cost.total_duration_ms } else { 0 }

$ESC   = [char]27
$CYAN  = "$ESC[36m"
$GREEN = "$ESC[32m"
$YEL   = "$ESC[33m"
$RED   = "$ESC[31m"
$RST   = "$ESC[0m"

if     ($pct -ge 90) { $barColor = $RED }
elseif ($pct -ge 70) { $barColor = $YEL }
else                  { $barColor = $GREEN }

$filled = [math]::Floor($pct / 10)
$empty  = 10 - $filled
$bar    = ('█' * $filled) + ('░' * $empty)

$totalSec = [math]::Floor($durationMs / 1000)
$hours    = [math]::Floor($totalSec / 3600)
$mins     = [math]::Floor(($totalSec % 3600) / 60)
$secs     = $totalSec % 60
$dur = if ($hours -gt 0) { "${hours}h ${mins}m ${secs}s" } else { "${mins}m ${secs}s" }

# Git 分支（可选 —— 没装 git 或 dir 不是 repo 则跳过）
$branch = ""
if (Get-Command git -ErrorAction SilentlyContinue) {
    & git -C $dir rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $branchName = & git -C $dir branch --show-current 2>$null
        if ($branchName) { $branch = " | 🌿 $branchName" }
    }
}

$costFmt = ('${0:F2}' -f $cost)

Write-Host "$CYAN[$model]$RST 📁 $dir$branch"
Write-Host "$barColor$bar$RST ${pct}% | $YEL$costFmt$RST | ⏱️ $dur"
