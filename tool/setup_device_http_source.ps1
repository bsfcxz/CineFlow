# 搭建"设备可取的 HTTP 片源"环境，并**逐步校验每一步**。
#
# ## 为什么要写脚本而不是敲几条命令
# 上次失败正是因为环境没建成就跑测试，结果"失败原因"被误读。
# 本脚本每一步都**断言结果**，任一步不成立就明确报出，不再往下走。
#
# ## 为什么用 HTTP 而不是 /sdcard 直读
# manifest 只有 INTERNET 权限（无存储权限）。Android 13 的 scoped storage 下
# 应用 UID 对 /sdcard/xxx 能 stat 成功（`File.existsSync()` 返回 true，
# **很误导**）但 open 被拒 → 内核拿到"打不开的文件" → duration 恒 0。
# 所以集成测试一律走 HTTP（或应用私有目录）。

$ErrorActionPreference = 'Continue'
$adb = 'D:\dev\android-sdk\platform-tools\adb.exe'
$dev = $null
$port = 8765

function Step($n, $t) { Write-Output ''; Write-Output "=== $n) $t ===" }

# ---------- 1) 选设备 ----------
Step 1 '选择在线设备'
foreach ($l in (& cmd /c "`"$adb`" devices" 2>&1)) {
    if ($l -match '^(\S+)\s+device$') { $dev = $matches[1]; break }
}
if (-not $dev) { Write-Output '  [失败] 无在线设备'; exit 1 }
Write-Output "  设备 = $dev"

# ---------- 2) 拉取片源到宿主机 ----------
Step 2 '拉取设备片源到宿主机'
$dir = Join-Path $env:TEMP 'cf_media'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$local = Join-Path $dir 'cf_test.mp4'
if (Test-Path $local) { Remove-Item $local -Force }
& cmd /c "`"$adb`" -s $dev pull /sdcard/cf_test.mp4 `"$local`"" 2>&1 | Out-Null
if (-not (Test-Path $local)) { Write-Output '  [失败] pull 未产出文件'; exit 1 }
$sz = (Get-Item $local).Length
Write-Output "  宿主机片源 = $sz 字节"
if ($sz -lt 100000) { Write-Output '  [失败] 片源过小（可能是空/静止录屏）'; exit 1 }

# ---------- 3) 校验是 MP4（ftyp） ----------
Step 3 '校验片源是标准 MP4'
$bytes = [System.IO.File]::ReadAllBytes($local)[0..15]
$ascii = -join ($bytes | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
Write-Output "  前 16 字节 = $ascii"
if ($ascii -notmatch 'ftyp') { Write-Output '  [失败] 没有 ftyp box，不是标准 MP4'; exit 1 }
Write-Output '  [通过] 是标准 MP4'

# ---------- 4) 起 HTTP 服务并**确认它真在监听** ----------
Step 4 '启动宿主机 HTTP 服务'
$jobName = 'cf_http_srv'
Get-Job -Name $jobName -EA SilentlyContinue | Stop-Job -EA SilentlyContinue
Get-Job -Name $jobName -EA SilentlyContinue | Remove-Job -Force -EA SilentlyContinue
Start-Job -Name $jobName -ScriptBlock {
    param($d, $p)
    Set-Location $d
    & python -m http.server $p
} -ArgumentList $dir, $port | Out-Null
Start-Sleep -Seconds 3

# 用宿主机的 curl 验证（不走设备，先确认服务本身好）
$hostUrl = "http://127.0.0.1:$port/cf_test.mp4"
$code = & curl.exe -s -o NUL -w '%{http_code} %{size_download}' $hostUrl 2>&1
Write-Output "  宿主机取 $hostUrl -> $code"
if ("$code" -notmatch '^200') {
    Write-Output '  [失败] 宿主机 HTTP 服务未就绪'
    Get-Job -Name $jobName | Stop-Job; Get-Job -Name $jobName | Remove-Job -Force
    exit 1
}
Write-Output '  [通过] 服务就绪且能返回文件'

# ---------- 5) adb reverse 并**确认列表里真出现** ----------
Step 5 '建立 adb reverse 并确认'
& cmd /c "`"$adb`" -s $dev reverse tcp:$port tcp:$port" 2>&1 | ForEach-Object { Write-Output "  $($_.Trim())" }
$list = (& cmd /c "`"$adb`" -s $dev reverse --list" 2>&1) -join "`n"
Write-Output "  reverse 列表: $($list.Trim())"
if ($list -notmatch "$port") {
    Write-Output '  [失败] reverse 未建立（设备将取不到 127.0.0.1）'
    Get-Job -Name $jobName | Stop-Job; Get-Job -Name $jobName | Remove-Job -Force
    exit 1
}
Write-Output '  [通过] reverse 已建立'

# ---------- 6) 从**设备侧**确认能取到（关键一步） ----------
Step 6 '从设备侧确认能取到该 URL'
# 用 -s 静默 + 只看状态码，避免二进制污染控制台
$devCode = (& cmd /c "`"$adb`" -s $dev shell curl -s -o /dev/null -w %{http_code} $hostUrl" 2>&1) -join ''
Write-Output "  设备 curl 状态码 = [$($devCode.Trim())]"
if ($devCode -notmatch '200') {
    Write-Output '  [警告] 设备侧未返回 200。'
    Write-Output '         设备可能没有 curl；这**不必然**说明网络不通。'
    Write-Output '         判据改由集成测试给出（它会真的去取流）。'
} else {
    Write-Output '  [通过] 设备确实能从 127.0.0.1:'"$port"' 取到片源'
}

# ---------- 7) 输出给下一步用 ----------
Step 7 '环境就绪，供集成测试使用'
Write-Output "  片源 URL : $hostUrl"
Write-Output "  跑法     : flutter test integration_test/dual_kernel_test.dart -d $dev --dart-define=CF_TEST_URL=$hostUrl"
Write-Output "  清理     : adb -s $dev reverse --remove-all ; Get-Job -Name $jobName | Stop-Job; Remove-Job"
Write-Output ''
Write-Output '  注意：HTTP 服务以后台 job 形式留在本会话中（名字 cf_http_srv）。'
exit 0
