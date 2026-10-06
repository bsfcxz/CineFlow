# CineFlow APK 签名校验
#
# 为什么需要单独一个脚本：
#   `flutter build apk --release` **在没有正式签名时会静默回退 debug 签名**
#   （见 android/app/build.gradle.kts 的告警分支）。也就是说，
#   "构建成功"**不等于**"打出了可发布的包" —— v0.3.0 就是这么发出去的
#   （实测证书 DN = CN=Android Debug）。
#
#   本脚本把"签名是否为正式发布密钥"变成**可机械判定**的事，
#   用法与门禁一致：**看退出码**（0=通过）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/verify_signing.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/verify_signing.ps1 -Apk <路径>
#
# 判据：
#   · 证书 DN **不得**含 `CN=Android Debug`（Android SDK 公共调试密钥）
#   · **必须**有 v2 或 v3 签名（minSdk 24+ 只认这两者）
#
# ⚠️ apksigner 必须加 `--verbose`：不加时它不打印 "Verified using v2 scheme: true"
#    这类行（实测踩过，会导致误判"缺少 v2/v3 签名"）。

[CmdletBinding()]
param(
    [string]$Apk
)

$ErrorActionPreference = 'Continue'

function Ok($m) { Write-Host "  [通过] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [失败] $m" -ForegroundColor Red }
function Warn($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }

# ---- 定位 APK ----
$dir = 'build/app/outputs/flutter-apk'
if ($Apk) {
    if (-not (Test-Path -LiteralPath $Apk)) { Bad "APK 不存在：$Apk"; exit 1 }
    $found = @(Get-Item -LiteralPath $Apk)
} else {
    if (-not (Test-Path $dir)) { Bad "找不到产物目录 $dir（先构建）"; exit 1 }
    $found = @(Get-ChildItem $dir -Filter '*-release.apk' -File -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { Bad "$dir 下没有 *-release.apk"; exit 1 }
}

# ---- 定位 apksigner ----
$btRoot = 'D:\dev\android-sdk\build-tools'
if (-not (Test-Path $btRoot)) {
    foreach ($c in @("$env:LOCALAPPDATA\Android\Sdk\build-tools", "$env:ANDROID_HOME\build-tools")) {
        if (Test-Path $c) { $btRoot = $c; break }
    }
}
if (-not (Test-Path $btRoot)) { Bad '找不到 Android build-tools（需要 apksigner）'; exit 1 }
$bt = Get-ChildItem $btRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
$apksigner = Join-Path $bt.FullName 'apksigner.bat'
if (-not (Test-Path $apksigner)) { Bad "找不到 $apksigner"; exit 1 }

Write-Host ''
Write-Host '=== CineFlow APK 签名校验 ==='
Write-Host "  工具: $apksigner"

$fail = 0
foreach ($f in $found) {
    Write-Host ''
    Write-Host ("  --- {0}  ({1:N2} MB) ---" -f $f.Name, ($f.Length / 1MB))

    $out = & cmd /c "`"$apksigner`" verify --verbose --print-certs `"$($f.FullName)`" 2>&1" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Bad "apksigner verify 退出码 $LASTEXITCODE"
        $out | Select-Object -First 4 | ForEach-Object { Write-Host "        $_" }
        $fail++
        continue
    }

    $v2 = ($out | Select-String 'Verified using v2 scheme.*: (\w+)')
    $v3 = ($out | Select-String 'Verified using v3 scheme.*: (\w+)')
    $v2ok = $v2 -and ($v2.Line -match ':\s*true')
    $v3ok = $v3 -and ($v3.Line -match ':\s*true')
    Write-Host ("        签名方案: v2={0}  v3={1}" -f $v2ok, $v3ok)

    $dn = ($out | Select-String 'certificate DN:').Line
    if ($dn) {
        $dnVal = ($dn -split 'certificate DN:', 2)[1].Trim()
        Write-Host "        证书 DN : $dnVal"
        if ($dnVal -match 'CN=Android Debug') {
            Bad '这是 debug 签名（Android SDK 公共调试密钥）—— 不可正式分发'
            $fail++
        } else {
            Ok '不是 debug 签名'
        }
    } else {
        Warn '未取到证书 DN'
    }

    $sha = ($out | Select-String 'SHA-256 digest:').Line
    if ($sha) {
        Write-Host ('        SHA-256 : ' + ($sha -split 'SHA-256 digest:', 2)[1].Trim())
    }

    if ($v2ok -or $v3ok) {
        Ok 'v2/v3 签名存在'
    } else {
        Bad '缺少 v2/v3 签名（现代 Android 会拒绝安装）'
        $fail++
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host '  结论：签名校验通过（可用于正式分发）' -ForegroundColor Green
    exit 0
} else {
    Write-Host "  结论：$fail 项不通过 —— **不要发布这个包**" -ForegroundColor Red
    Write-Host '        修法：确认 keystore 可读（CF_KEY_PROPERTIES 或 %USERPROFILE%\cineflow-keystore\key.properties）后重新构建'
    exit 1
}
