# 起一个**跨命令存活**的 HTTP 服务，并验证它真在监听。
#
# ## 为什么不用 Start-Job
# 实测：`Start-Job` 起的 python http.server 在**下一次工具调用时就没了**
# （宿主机 curl 返回 000，Get-Job 为空）—— PowerShell 会话结束时 job 被回收。
# 于是集成测试跑到一半服务已死 → mpv 报 `error=-13 loading failed`
# （EACCES，看起来像权限问题，实际是**连接被拒**）。
#
# ## 改用 Start-Process
# 独立进程，不随 PowerShell 会话结束而终止；并把 pid 写文件便于后续 kill。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/serve_test_media.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/serve_test_media.ps1 -Stop

param(
    [string]$Dir = "$env:TEMP\cf_media",
    [int]$Port = 8765,
    [switch]$Stop
)

$ErrorActionPreference = 'Continue'
$pidFile = Join-Path $env:TEMP 'cf_http_srv.pid'

if ($Stop) {
    if (Test-Path $pidFile) {
        $oldPid = (Get-Content $pidFile -Raw).Trim()
        try {
            Stop-Process -Id ([int]$oldPid) -Force -ErrorAction Stop
            Write-Output "  已停止 HTTP 服务 (pid=$oldPid)"
        } catch {
            Write-Output "  停止失败（可能已退出）: $_"
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output '  没有记录在案的 pid'
    }
    exit 0
}

# ---------- 1) 前置：片源存在 ----------
$file = Join-Path $Dir 'cf_test.mp4'
if (-not (Test-Path $file)) {
    Write-Output "  [失败] 片源不存在: $file"
    Write-Output '         先跑 tool/prepare_device_media.ps1 + adb pull'
    exit 1
}
$zeros = 0
$bytes = [System.IO.File]::ReadAllBytes($file)[0..15]
$head = -join ($bytes | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
Write-Output "  片源: $file ($((Get-Item $file).Length) 字节, 头=$head)"
if ($head -notmatch 'ftyp') { Write-Output '  [失败] 不是标准 MP4'; exit 1 }

# ---------- 2) 停掉可能存在的旧实例（避免端口占用）----------
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -Raw).Trim()
    Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# ---------- 3) 起独立进程 ----------
$proc = Start-Process -FilePath 'python' `
    -ArgumentList '-m', 'http.server', "$Port", '--bind', '127.0.0.1' `
    -WorkingDirectory $Dir -PassThru -WindowStyle Hidden
Set-Content -Path $pidFile -Value $proc.Id -NoNewline
Write-Output "  已启动 HTTP 服务 pid=$($proc.Id) 端口=$Port 目录=$Dir"

# ---------- 4) 等它就绪并**验证**（不能假设起来了）----------
$ok = $false
for ($i = 1; $i -le 10; $i++) {
    Start-Sleep -Milliseconds 500
    $code = & curl.exe -s -o NUL -w '%{http_code}' "http://127.0.0.1:$Port/cf_test.mp4" 2>&1
    if ("$code" -eq '200') { $ok = $true; break }
}
if (-not $ok) {
    Write-Output '  [失败] 10 次探测内未返回 200，服务未就绪'
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Output "  [通过] 服务就绪（curl 返回 200）"

# ---------- 5) 建立 adb reverse 并验证 ----------
$adb = 'D:\dev\android-sdk\platform-tools\adb.exe'
$dev = $null
foreach ($l in (& cmd /c "`"$adb`" devices" 2>&1)) {
    if ($l -match '^(\S+)\s+device$') { $dev = $matches[1]; break }
}
if ($dev) {
    & cmd /c "`"$adb`" -s $dev reverse tcp:$Port tcp:$Port" 2>&1 | Out-Null
    $list = (& cmd /c "`"$adb`" -s $dev reverse --list" 2>&1) -join ' '
    Write-Output "  adb reverse: $($list.Trim())"
    $devCode = ((& cmd /c "`"$adb`" -s $dev shell curl -s -o /dev/null -w %{http_code} http://127.0.0.1:$Port/cf_test.mp4" 2>&1) -join '').Trim()
    Write-Output "  设备侧 curl -> $devCode"
    if ($devCode -match '200') {
        Write-Output '  [通过] 设备可从 127.0.0.1 取到片源'
    } else {
        Write-Output '  [警告] 设备侧未返回 200（可能无 curl；以磁测试为准）'
    }
}

Write-Output ''
Write-Output "  URL = http://127.0.0.1:$Port/cf_test.mp4"
Write-Output "  停止 = powershell -File tool/serve_test_media.ps1 -Stop"
exit 0
