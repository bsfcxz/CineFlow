# 敏感信息门禁：扫出提交里可能带走的凭据 / 地址 / 会话串。
#
# 用法：
#   powershell -File scripts/check-secrets.ps1            # 全量（git ls-files）
#   powershell -File scripts/check-secrets.ps1 --staged   # 只扫暂存区
#
# 约定：新增命中一律红；白名单（本就公开的域名等）放 scripts/secrets-allow.txt 并写理由。
# 说明：本脚本是 scripts/check-secrets.sh 的 PowerShell 移植版——本机 bash 在沙箱下
#       不可执行（msys NtCreateDirectoryObject 被拒），故门禁以 PowerShell 为准。
#       扫描范围只含 **git 跟踪的文件**，因此 build/ 与 tool/icon/_gen/ 天然不在范围内。

[CmdletBinding()]
param(
    [switch]$Staged,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
    Write-Host '[跳过] 不在 git 工作区内。'
    exit 0
}
Set-Location $repoRoot

# ---- 模式判定（兼容 --staged 位置参数）----
$mode = if ($Staged -or ($args -contains '--staged')) { 'staged' } else { 'all' }

# ---- 检测模式表：名称 + 正则 ----
$patterns = @(
    @{ Name = '通用凭据片段(token/apikey/password/cookie)'
       # 允许值被引号包裹（api_key = "AKIA..." 这种最常见的写法）；
       # 原 .sh 版不允许引号，实测会漏掉带引号的真实凭据。
       Re   = '(api[_-]?key|secret[_-]?key|passwd|password|access[_-]?token|refresh[_-]?token|auth[_-]?token|cookie|token)[\s]*[:=][\s]*[''"]?[A-Za-z0-9_.:;/=+-]{16,}' }
    @{ Name = 'JWT'
       Re   = 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.' }
    @{ Name = '私钥块'
       Re   = '-----BEGIN [A-Z ]*PRIVATE KEY-----' }
    @{ Name = '长base64串'
       Re   = '[A-Za-z0-9+/=]{120,}' }
    @{ Name = '内网或本机地址'
       Re   = 'https?://(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.0\.0\.1)[:/]?[0-9]*' }
    # ⚠️ 实测漏检（2026-10-06）：上面那条**只认私有网段**，
    #    于是把用户真实服务器的**公网 IP + 端口**（`http://<公网IP>:8096/...`）
    #    当成普通文本放过去了 —— 那正是红线明令禁止的「私密地址」。
    #    补一条覆盖公网 IPv4，同时排除文档/测试常用的保留地址：
    #      · 192.0.2.x / 198.51.100.x / 203.0.113.x  RFC 5737 文档用
    #      · 127.x / 0.0.0.0 / 255.x                 回环与保留
    #      · 版本号形态（4.10.0.40 这类）由「必须带 http(s):// 或端口」抵消
    #    注意：**必须带 scheme 或 :端口**才算命中，否则会误报
    #    `4.10.0.40`（Emby 版本号）这类四段数字。
    @{ Name = '公网 IPv4 + 端口/scheme（真实服务器地址）'
       Re   = '(https?://|//)(?!(?:10\.|127\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|0\.|255\.))(?:\d{1,3}\.){3}\d{1,3}(?::\d{2,5})?' }
    @{ Name = '裸公网 IP:端口（无 scheme）'
       # 形如「公网地址 + :8096」（登录页示例、curl 命令里最常见）。
       # ⚠️ 本注释**不能**写出真实形状的四段数字加端口 ——
       #    实测踩过：门禁把**自己的注释**当成了泄露（自命中）。
       Re   = '(?<![\d.])(?!(?:10\.|127\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|0\.|255\.))(?:\d{1,3}\.){3}\d{1,3}:(?:80|443|[1-9]\d{3,4})\b' }
)

# 后缀白名单：模板文件里出现占位符是正常的
$allowSuffix = @('.example', '.sample', '.template')

# 逐文件白名单（整文件跳过；慎用——会让该文件失去全部扫描）
$allowFiles = @()

# 逐行白名单（**优先用这个**）：只有同时匹配「文件路径」且该行包含「指定片段」时才放行。
# 格式（scripts/secrets-allow.txt）：
#     <相对路径> :: <该行必须包含的片段>    # 理由
# 用行级而不是文件级，是为了让同一个文件里其它行仍被扫描。
$allowLines = @()
$allowPath = Join-Path $repoRoot 'scripts/secrets-allow.txt'
if (Test-Path $allowPath) {
    foreach ($raw in (Get-Content $allowPath)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '::') {
            $parts = $line -split '::', 2
            $allowLines += [pscustomobject]@{
                Path    = $parts[0].Trim()
                Snippet = ($parts[1] -split '#')[0].Trim()
            }
        } else {
            $allowFiles += $line
        }
    }
}

# 该行是否被逐行白名单放行
function Test-LineAllowed {
    param([string]$RelPath, [string]$Line)
    foreach ($a in $allowLines) {
        if ($RelPath -eq $a.Path -and $Line.Contains($a.Snippet)) { return $true }
    }
    return $false
}

# ---- 收集待扫文件 ----
if ($mode -eq 'staged') {
    $files = git diff --cached --name-only --diff-filter=ACM 2>$null
} else {
    $files = git ls-files 2>$null
}
$files = @($files | Where-Object { $_ })

if ($files.Count -eq 0) {
    Write-Host '[跳过] 没有可扫描的文件（仓库为空，或不在 git 工作区）。'
    exit 0
}

if (-not $Quiet) { Write-Host "== 扫描模式：$mode（共 $($files.Count) 个文件） ==" }

$hits = 0
$allowed = 0
# 白名单文件自身是「控制文件」：它的职责就是记录被放行的片段，扫它必然自命中。
$selfSkip = @('scripts/secrets-allow.txt')
foreach ($f in $files) {
    $skip = $false
    foreach ($suf in $allowSuffix) { if ($f.EndsWith($suf)) { $skip = $true } }
    if ($allowFiles -contains $f) { $skip = $true }
    if ($selfSkip -contains $f) { $skip = $true }
    if ($skip) { continue }

    $full = Join-Path $repoRoot $f
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

    # 跳过二进制（含 NUL 字节）
    try {
        $bytes = [System.IO.File]::ReadAllBytes($full)
    } catch { continue }
    if ($bytes.Length -gt 0 -and ($bytes -contains 0)) { continue }

    $lines = [System.IO.File]::ReadAllLines($full)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineAllowed = Test-LineAllowed -RelPath $f -Line $line
        foreach ($p in $patterns) {
            if ($line -match $p.Re) {
                if ($lineAllowed) { $allowed++; continue }
                $shown = if ($line.Length -gt 140) { $line.Substring(0, 140) } else { $line }
                Write-Host ("  [命中] {0}:{1}  模式：{2}" -f $f, ($i + 1), $p.Name)
                Write-Host ("        {0}" -f $shown.Trim())
                $hits++
            }
        }
    }
}

if ($allowed -gt 0) {
    Write-Host "  （另有 $allowed 处命中被 scripts/secrets-allow.txt 的逐行白名单放行）"
}

if ($hits -eq 0) {
    Write-Host '== 通过：未发现敏感信息可疑片段 =='
    exit 0
}

Write-Host "== 结论：发现 $hits 处可疑片段 =="
Write-Host @'
处理方式：
  1) 改占位符（TEMPLATE），真实值放 .env / *.local（已 gitignore）
  2) 已推上去的：改写历史，光删最新一版没用（AGENTS.md §4.1）
  3) 确认是白名单公开资产（如 README 上本就印着的域名）→ 加进 scripts/secrets-allow.txt 并写理由
'@
exit 1
