# 文档门禁：必需文档是否齐全 + Markdown 相对链接是否断。
#
# 用法：
#   powershell -File scripts/check-docs.ps1
#
# 说明：本脚本是 scripts/check-docs.sh 的 PowerShell 移植版——本机 bash 在沙箱下
#       不可执行（msys NtCreateDirectoryObject 被拒），故门禁以 PowerShell 为准。

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
    Write-Host '[跳过] 不在 git 工作区内。'
    exit 0
}
Set-Location $repoRoot

$errors = 0

$required = @(
    'AGENTS.md'
    'README.md'
    'CHANGELOG.md'
    'VERSION'
    '.gitignore'
    # ★ AI 记忆库：每轮开发前必读、结束后必写（是 AI 协作的交接凭据）
    'docs/AI-MEMORY.md'
    # ★ AI 分发规范：约束一切对外分发（不得自增版本、不得删旧 Release、须审批）
    'docs/AI-DISTRIBUTION.md'
    # ★ 计划与进度报告（给人看的快照；每轮进度以 AI-MEMORY.md 为准）
    'docs/PROJECT-STATUS.md'
    # ★ 开发计划书（前瞻：往哪走、先做什么、什么卡住了；与 PROJECT-STATUS 分工明确）
    'docs/DEVELOPMENT-PLAN.md'
    # ★ UI 设计规范（令牌体系 / 对比度实测 / 交互纪律；AGENTS §6.4.1 的细节出处）
    'docs/UI-DESIGN.md'
    # ★ 目录地图（从 AGENTS §4 外移而来 —— AGENTS 有指令体积预算，超出会被截断）
    'docs/DIRECTORY-MAP.md'
    # ★ 开源参考清单（借鉴了什么、许可能不能抄；新增引用前必看）
    'docs/OSS-REFERENCES.md'
    'docs/UPDATE-WORKFLOW.md'
    'docs/task-board.md'
    'docs/architecture.md'
    'docs/review-checklist.md'
    'docs/CHANGELOG-GUIDE.md'
    'docs/TECH-SKILLS.md'
    'docs/OSS-SOURCES.md'
    'docs/PROMPT-TEMPLATES.md'
    'docs/decisions/README.md'
    'docs/lessons/README.md'
    'scripts/check-secrets.ps1'
    'scripts/check-docs.ps1'
    'scripts/check-dev.ps1'
)

Write-Host '== 必需文档 =='
foreach ($f in $required) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $f)) {
        Write-Host "  [ OK ] $f"
    } else {
        Write-Host "  [缺失] $f"
        $errors++
    }
}

Write-Host '== Markdown 相对链接 =='
$mdFiles = @(git ls-files --cached --others --exclude-standard '*.md' 2>$null |
    Where-Object { $_ } | Sort-Object -Unique)
if ($mdFiles.Count -eq 0) {
    $mdFiles = @(Get-ChildItem -Path $repoRoot -Filter '*.md' -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        ForEach-Object { $_.FullName.Substring($repoRoot.Length + 1).Replace('\', '/') })
}

$linkCount = 0
foreach ($f in $mdFiles) {
    $full = Join-Path $repoRoot $f
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $lines = [System.IO.File]::ReadAllLines($full)
    $base = Split-Path $f -Parent

    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in [regex]::Matches($lines[$i], '\]\(([^)]+)\)')) {
            $link = $m.Groups[1].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($link)) { continue }
            # 外部链接与锚点跳过
            if ($link -match '^(https?:|mailto:|#)') { continue }
            # 省略式链接（GitHub compare 之类）
            if ($link -match '\.\.\.' -or $link -match '…') { continue }

            $target = $link
            if ($target.Contains('#')) { $target = $target.Substring(0, $target.IndexOf('#')) }
            if ($target.Contains('?')) { $target = $target.Substring(0, $target.IndexOf('?')) }
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            # 去掉尖括号包裹
            $target = $target.Trim('<', '>')

            $resolved = if ($target.StartsWith('/')) {
                Join-Path $repoRoot $target.TrimStart('/')
            } elseif ([string]::IsNullOrEmpty($base)) {
                Join-Path $repoRoot $target
            } else {
                Join-Path (Join-Path $repoRoot $base) $target
            }
            $resolved = [System.IO.Path]::GetFullPath($resolved)

            if (-not (Test-Path -LiteralPath $resolved)) {
                Write-Host "  [断链] ${f}:$($i + 1) → $link"
                $errors++
            }
            $linkCount++
        }
    }
}
Write-Host "  已检查 $linkCount 条相对链接"

Write-Host '== 结论 =='
if ($errors -eq 0) {
    Write-Host '文档门禁通过。'
    exit 0
}
Write-Host "发现 $errors 个问题（缺失文档 / 断链）。"
exit 1
