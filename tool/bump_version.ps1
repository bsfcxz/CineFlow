# 版本号一致性门禁 + 发版时一次改齐。
#
# 背景：版本号曾散落四处且互不一致（缺陷 7.17）——
#   VERSION=0.2.0 / pubspec=1.0.0+1 / clientVersion=0.1.0 / 「我的」页硬编码 v0.1.0。
# 不一致的后果不只是难看：更新检查会误判「已是最新」而静默卡死老用户。
#
# 唯一权威：仓库根 VERSION（只写 X.Y.Z 一行）。
#   - pubspec.yaml 的 version: 必须是 "<VERSION>+<build>" 形式
#   - lib/core/version.dart 的 kAppVersion 必须等于 <VERSION>
#   - 代码里不得再出现硬编码的版本字面量（除 version.dart 本身）
#
# 用法：
#   powershell -File tool/bump_version.ps1 -Check              # 只校验（CI/收工前跑）
#   powershell -File tool/bump_version.ps1 -Version 0.3.0      # 改齐三处
#
# 退出码：0 = 一致；1 = 不一致或用法错误。

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

# 以脚本自身位置定位仓库根，不依赖调用者的工作目录
# （git rev-parse 用的是进程 cwd，脚本从别处调用会失败——实测踩过）
$root = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $root 'VERSION'))) {
    $gitRoot = git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
    if ($gitRoot -and (Test-Path (Join-Path $gitRoot 'VERSION'))) { $root = $gitRoot }
    else { Write-Host "[失败] 找不到仓库根（缺 VERSION）：$root"; exit 1 }
}
Set-Location $root

$versionFile = Join-Path $root 'VERSION'
$pubspecFile = Join-Path $root 'pubspec.yaml'
$dartFile    = Join-Path $root 'lib/core/version.dart'

foreach ($f in @($versionFile, $pubspecFile, $dartFile)) {
    if (-not (Test-Path $f)) { Write-Host "[失败] 找不到 $f"; exit 1 }
}

function Read-Utf8([string]$p) {
    return [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
}
function Write-Utf8([string]$p, [string]$text) {
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- 改齐模式 ----
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        Write-Host "[失败] 版本号必须形如 X.Y.Z，收到：$Version"
        exit 1
    }
    $old = (Read-Utf8 $versionFile).Trim()

    Write-Utf8 $versionFile "$Version`n"

    $ps = Read-Utf8 $pubspecFile
    $build = if ($ps -match '(?m)^version:\s*[\d.]+\+(\d+)') { $Matches[1] } else { '1' }
    $ps = [regex]::Replace($ps, '(?m)^version: .*$', "version: $Version+$build")
    Write-Utf8 $pubspecFile $ps

    $dart = Read-Utf8 $dartFile
    $dart = [regex]::Replace($dart, "const String kAppVersion = '[^']*';", "const String kAppVersion = '$Version';")
    Write-Utf8 $dartFile $dart

    Write-Host "[完成] VERSION $old -> $Version（pubspec 与 lib/core/version.dart 已同步，build=$build）"
    Write-Host "       别忘了：CHANGELOG.md 补该版本条目 + git tag v$Version"
    exit 0
}

# ---- 校验模式（默认）----
$errors = @()

$v = (Read-Utf8 $versionFile).Trim()
if ($v -notmatch '^\d+\.\d+\.\d+$') { $errors += "VERSION 内容不是 X.Y.Z：'$v'" }

$psText = Read-Utf8 $pubspecFile
$psVer = if ($psText -match '(?m)^version:\s*(\S+)') { $Matches[1] } else { $null }
if (-not $psVer) { $errors += 'pubspec.yaml 缺少 version: 行' }
elseif ($psVer -notmatch "^$([regex]::Escape($v))\+\d+$") {
    $errors += "pubspec.yaml 的 version（$psVer）与 VERSION（$v）不一致，应为 $v+<build>"
}

$dartText = Read-Utf8 $dartFile
$dartVer = if ($dartText -match "const String kAppVersion = '([^']*)'") { $Matches[1] } else { $null }
if (-not $dartVer) { $errors += 'lib/core/version.dart 缺少 kAppVersion' }
elseif ($dartVer -ne $v) {
    $errors += "lib/core/version.dart 的 kAppVersion（$dartVer）与 VERSION（$v）不一致"
}

# 硬编码版本字面量扫描：lib/ 下除 version.dart 外不应出现版本常量
#
# 两类都要抓（第二类曾漏网，导致登录页长期显示 v0.1.0 而应用已是 0.2.0）：
#   1) 赋值形式：clientVersion = '1.2.3'
#   2) 带 v 前缀的文案内嵌：'CineFlow v0.1.0 · 登录即代表同意…'
# 只认 **vX.Y.Z**（带 v 前缀）——裸 x.y.z 会误伤 UA 串里的
# "Version/17.0"、Safari 的 "605.1.15" 等外部版本号（实测踩过）。
$libDir = Join-Path $root 'lib'
$hardcoded = @()
Get-ChildItem $libDir -Recurse -File -Filter *.dart | ForEach-Object {
    if ($_.Name -eq 'version.dart') { return }
    $lines = [System.IO.File]::ReadAllLines($_.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # 跳过注释行：注释里引用历史版本号是合理且有益的
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('//') -or $trimmed.StartsWith('///') -or $trimmed.StartsWith('*')) {
            continue
        }
        $isAssign = $line -match "(clientVersion|appVersion|kAppVersion)\s*=\s*'?\d+\.\d+\.\d+"
        # 文案内嵌：只认 v1.2.3 形式（v 前缀是应用版本号的书写惯例）
        $isInText = $line -match "['""][^'""]*\bv\d+\.\d+\.\d+"
        if ($isAssign -or $isInText) {
            $hardcoded += "$($_.FullName.Substring($root.Length + 1)):$($i + 1)"
        }
    }
}
if ($hardcoded.Count -gt 0) {
    $errors += "发现硬编码版本字面量（应改用 lib/core/version.dart）：$($hardcoded -join ', ')"
}

Write-Host '== 版本号一致性 =='
Write-Host "  VERSION:              $v"
Write-Host "  pubspec.yaml:         $psVer"
Write-Host "  lib/core/version.dart: $dartVer"

if ($errors.Count -eq 0) {
    Write-Host '== 通过：三处一致，且无硬编码版本字面量 =='
    exit 0
}

Write-Host '== 结论：发现以下问题 =='
$errors | ForEach-Object { Write-Host "  - $_" }
Write-Host ''
Write-Host '修法：powershell -File tool/bump_version.ps1 -Version <X.Y.Z>'
exit 1
