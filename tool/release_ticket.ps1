<#
.SYNOPSIS
    分发审批凭据（release token）管理 —— 让「未经审批不得发版」成为**机械约束**而非口头约定。

.DESCRIPTION
    为什么需要这个脚本：
      `docs/AI-DISTRIBUTION.md` 规定「AI 不得自行发版，必须经用户审批」。
      但纪律写在文档里只能靠"记得遵守"，而发布是**不可撤回的对外动作**——
      一次疏忽就是既成事实。所以把它变成一道**开关**：

        · 默认状态：**没有凭据** → `release.yml` 会在第一步就失败
        · 用户批准后：AI 用本脚本**签发**凭据（带版本号 + 有效期）
        · 发版完成：凭据**自动消费**（一次性），或过期作废

    凭据文件 `.release-approval.json` **已加入 .gitignore**（不进仓库、不公开）。

    安全边界（务必认清）：
      这是**防误操作**，不是**防恶意**。AI 能自己调用 `approve` 绕过它。
      它的真实价值是：把"发版"从一条命令变成**一个需要显式决策步骤的流程**，
      并且在日志/提交里留下"谁在什么时候批了哪个版本"的痕迹。
      真正的把关仍是人 —— 见 AI-DISTRIBUTION.md §3 审批单。

.PARAMETER Action
    status    查看当前凭据状态（默认）
    approve   签发凭据（需要用户明确批准后由人执行；AI 不得自行调用）
    consume   消费凭据（release.yml 成功后调用，一次性）
    revoke    立即作废凭据

.PARAMETER Version
    approve 时必填：被批准的版本号（X.Y.Z），与 VERSION / tag 必须一致。

.PARAMETER Hours
    凭据有效期（默认 2 小时）。超时自动失效，避免"批了一次用一个月"。

.PARAMETER Note
    审批备注（建议写用户的原话，如「用户回复：批准」）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tool/release_ticket.ps1 -Action status
    powershell -NoProfile -ExecutionPolicy Bypass -File tool/release_ticket.ps1 -Action approve -Version 0.3.0 -Note "用户回复：批准"
    powershell -NoProfile -ExecutionPolicy Bypass -File tool/release_ticket.ps1 -Action consume
    powershell -NoProfile -ExecutionPolicy Bypass -File tool/release_ticket.ps1 -Action revoke
#>
param(
    [ValidateSet('status', 'approve', 'consume', 'revoke')]
    [string]$Action = 'status',
    [string]$Version,
    [int]$Hours = 2,
    [string]$Note = ''
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$ticket = Join-Path $root '.release-approval.json'

function Read-Ticket {
    if (-not (Test-Path -LiteralPath $ticket)) { return $null }
    try { return Get-Content -LiteralPath $ticket -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Show-Status($t) {
    Write-Host '== 分发审批凭据状态 =='
    if (-not $t) {
        Write-Host '  无凭据 —— **禁止发版**' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  AI 必须先向用户提交审批单（docs/AI-DISTRIBUTION.md §3），' -ForegroundColor Gray
        Write-Host '  得到明确「批准」后，由人执行：' -ForegroundColor Gray
        Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -File tool/release_ticket.ps1 `' -ForegroundColor DarkGray
        Write-Host '      -Action approve -Version X.Y.Z -Note "用户回复：批准"' -ForegroundColor DarkGray
        return
    }
    $exp = [datetime]$t.expiresAt
    $left = $exp - (Get-Date)
    Write-Host ("  版本   : {0}" -f $t.version)
    Write-Host ("  批准于 : {0}" -f $t.approvedAt)
    Write-Host ("  有效期 : {0}（剩余 {1:N0} 分钟）" -f $exp.ToString('yyyy-MM-dd HH:mm:ss'), $left.TotalMinutes)
    Write-Host ("  备注   : {0}" -f $t.note)
    if ($left.TotalSeconds -le 0) {
        Write-Host '  → **已过期，禁止发版**' -ForegroundColor Red
    } else {
        Write-Host '  → 有效，可发版' -ForegroundColor Green
    }
}

switch ($Action) {
    'status' {
        Show-Status (Read-Ticket)
    }

    'approve' {
        if (-not $Version -or $Version -notmatch '^\d+\.\d+\.\d+$') {
            Write-Host "[失败] 必须用 -Version 指定 X.Y.Z 版本号（收到：'$Version'）" -ForegroundColor Red
            exit 1
        }
        # 与仓库权威版本比对：批的必须是当前 VERSION，避免批了 A 却发 B
        $vf = Join-Path $root 'VERSION'
        if (Test-Path -LiteralPath $vf) {
            $fileVer = ([System.IO.File]::ReadAllText($vf)).Trim()
            if ($fileVer -ne $Version) {
                Write-Host "[失败] -Version($Version) 与仓库 VERSION($fileVer) 不一致。" -ForegroundColor Red
                Write-Host '       先跑 tool/bump_version.ps1 -Version X.Y.Z 改齐三处，再签发凭据。' -ForegroundColor Yellow
                exit 1
            }
        }
        $obj = [ordered]@{
            version    = $Version
            approvedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            expiresAt  = (Get-Date).AddHours($Hours).ToString('yyyy-MM-dd HH:mm:ss')
            note       = $Note
        }
        [System.IO.File]::WriteAllText($ticket, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[完成] 已签发 $Version 的分发凭据（$Hours 小时内有效）" -ForegroundColor Green
        Write-Host '       发版成功后请消费：-Action consume' -ForegroundColor Gray
    }

    'consume' {
        $t = Read-Ticket
        if (-not $t) { Write-Host '[提示] 无凭据可消费' -ForegroundColor Yellow; exit 0 }
        Remove-Item -LiteralPath $ticket -Force
        Write-Host ("[完成] 已消费 {0} 的凭据（一次性，需重新审批才能再发）" -f $t.version) -ForegroundColor Green
    }

    'revoke' {
        if (Test-Path -LiteralPath $ticket) {
            Remove-Item -LiteralPath $ticket -Force
            Write-Host '[完成] 凭据已作废' -ForegroundColor Green
        } else {
            Write-Host '[提示] 本来就没有凭据' -ForegroundColor Yellow
        }
    }
}
