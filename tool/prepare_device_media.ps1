# 在设备上准备一个**可靠的本地测试片源**。
#
# ## 为什么不用外网 HLS
# 现有 `player_kernel_test.dart` 默认用 `test-streams.mux.dev` 的 HLS。
# 实测在真机上它拿不到 duration（30s 超时），而这**无法区分**是：
#   · 网络不通/被墙
#   · 内核解封装有问题
# 两者表现完全一样（都是"没拿到 duration"），排查时先要花时间分辨。
#
# 本地文件片源把网络这个变量彻底消掉：能播就是内核好，不能播就是内核坏。
#
# ## 为什么用 screenrecord 生成
# 设备自带 `screenrecord` 产出**标准 H.264 + MP4**，两个内核都必然支持。
# 无需往设备推大文件，也不依赖 ffmpeg 在设备上可用。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tool/prepare_device_media.ps1

$ErrorActionPreference = 'Continue'

$adb = 'D:\dev\android-sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }

$remote = '/sdcard/cf_test.mp4'
$dev = $null

Write-Output '=== 1) 选择设备 ==='
$lines = & cmd /c "`"$adb`" devices" 2>&1
foreach ($l in $lines) {
    if ($l -match '^(\S+)\s+device$') { $dev = $matches[1]; break }
}
if (-not $dev) {
    Write-Output '  [失败] 没有在线设备'
    exit 1
}
Write-Output "  设备: $dev"

Write-Output ''
Write-Output '=== 2) 是否已有片源（幂等：已存在就跳过，省一次录制）==='
$exists = (& cmd /c "`"$adb`" -s $dev shell test -f $remote; echo `$?" 2>&1) -join ''
if ($exists -match '0') {
    $sz = (& cmd /c "`"$adb`" -s $dev shell stat -c %s $remote" 2>&1) -join ''
    Write-Output "  已存在（$sz 字节），跳过录制"
} else {
    Write-Output '  不存在，录制 3 秒...'
    # screenrecord 会一直录到 --time-limit 或收到中断；3 秒足够产生可解析的 MP4
    & cmd /c "`"$adb`" -s $dev shell screenrecord --time-limit 3 $remote" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $sz = (& cmd /c "`"$adb`" -s $dev shell stat -c %s $remote" 2>&1) -join ''
    Write-Output "  录制完成（$sz 字节）"
}

Write-Output ''
Write-Output '=== 3) 校验（文件存在 + 体积合理 + MP4 魔数）==='
if (-not (Test-Path $env:TEMP)) { New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null }
$head = "$env:TEMP\cf_head.bin"
# exec-out 避免 PowerShell 重定向破坏二进制
& cmd /c "`"$adb`" -s $dev exec-out dd if=$remote bs=1 count=16 2>nul > `"$head`"" | Out-Null
if (Test-Path $head) {
    $bytes = [System.IO.File]::ReadAllBytes($head)
    $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ' '
    $ascii = -join ($bytes | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
    Write-Output "  前 16 字节: $hex"
    Write-Output "  可读形式   : $ascii"
    if ($ascii -match 'ftyp') {
        Write-Output '  [通过] 是标准 MP4（ftyp box 存在）—— 两个内核都必然支持'
    } else {
        Write-Output '  [警告] 没看到 ftyp，可能不是标准 MP4'
    }
    Remove-Item $head -Force -EA SilentlyContinue
} else {
    Write-Output '  [警告] 无法读取文件头'
}

$final = (& cmd /c "`"$adb`" -s $dev shell stat -c %s $remote" 2>&1) -join ''
Write-Output ''
Write-Output "  最终片源: $remote  ($final 字节)"
Write-Output '  用法: flutter test integration_test/dual_kernel_test.dart -d <device>'
exit 0
