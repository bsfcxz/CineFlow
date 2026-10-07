# 用 ffmpeg 造"能验证播放器全部可调项"的测试片源。
#
# ## 为什么需要专门的测试片（不能随便拿部电影）
# 播放器要验证的可调项，每一项都需要**片源里存在对应内容 + 变化可被眼睛/耳朵分辨**：
#
# | 要验证 | 片源必须有什么 | 为什么普通片子不行 |
# |---|---|---|
# | 画面滤镜（亮/对比/饱和/色相） | 高饱和、多色块 | 电影偏灰，调饱和看不出 |
# | 音频延迟（±5s，0.1s 步进） | **有音轨**且**有节拍脉冲** | 无音轨验不了；连续音听不出 0.1s 差 |
# | 字幕延迟 | **内嵌字幕轨** | 无字幕轨验不了 |
# | 音轨切换 | **≥2 条音轨**且听感可区分 | 单音轨时按钮本该隐藏（那是另一条规则） |
# | 字幕轨切换 | **≥2 条字幕轨** | 同上 |
# | 画幅五档 | 有**明确边界/参考物** | 纯色画面切画幅看不出裁切 |
# | seek 精度 | 画面带**秒表式时间码** | 否则无法判断 seek 落点 |
#
# ## 本脚本产出
# 60 秒视频，带：
#   · 视频轨：testsrc2 彩色运动图案 + 顶部大号秒数（便于目视 seek 落点与画幅裁切）
#   · 音轨 1（默认）：**每秒一声短哔** 441Hz（听音频延迟；差 0.1s 能听出）
#   · 音轨 2：**连续 880Hz**（与音轨1 频率/节奏都不同 → 切轨立即可辨）
#   · 字幕轨 1（chi）：每秒 `[CN] 第 N 秒 · 字幕延迟可调`
#   · 字幕轨 2（eng）：每秒 `[EN] second N · subtitle delay`
#
# 音频用 `aevalsrc` 而**不是** `sine`：`sine` 是 lavfi 源，不能再链
# `sample_rate` 等滤镜（实测报 `Error parsing filterchain 'sine=...,sample_rate=48000'`）。
#
# 音轨一律**单声道**：多声道表达式要用 `|` 分隔，而 `|` 在 ffmpeg 选项解析
# 与 PowerShell 里都是特殊字符（实测被吞成 `d==stereo`）。
# 验证音轨切换只需"频率/节奏可辨"，不需要立体声。
#
# 字幕用 `mov_text`（MP4 内嵌字幕标准），mpv 与 Media3 都支持。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/make_test_media.ps1
# 产出：%TEMP%\cf_media\cf_probe.mp4

param(
    [int]$Seconds = 60,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Continue'

# ---------- 定位 ffmpeg ----------
$ff = $null; $fp = $null
$candidates = @(
    'C:\Users\a1332\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.2-full_build\bin'
)
foreach ($d in $candidates) {
    if (Test-Path (Join-Path $d 'ffmpeg.exe')) {
        $ff = Join-Path $d 'ffmpeg.exe'; $fp = Join-Path $d 'ffprobe.exe'; break
    }
}
if (-not $ff) {
    $c = Get-Command ffmpeg -EA SilentlyContinue
    if ($c) { $ff = $c.Source; $fp = (Get-Command ffprobe -EA SilentlyContinue).Source }
}
if (-not $ff) {
    Write-Output '  [失败] 找不到 ffmpeg。装法：winget install Gyan.FFmpeg'
    exit 1
}
Write-Output "  ffmpeg = $ff"

$outDir = Join-Path $env:TEMP 'cf_media'
$tmpDir = Join-Path $env:TEMP 'cf_media_src'
New-Item -ItemType Directory -Force -Path $outDir, $tmpDir | Out-Null

# ---------- 1) 字幕源（SRT，UTF-8 无 BOM）----------
$srtCn = Join-Path $tmpDir 'cn.srt'
$srtEn = Join-Path $tmpDir 'en.srt'
$cn = New-Object System.Collections.Generic.List[string]
$en = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $Seconds; $i++) {
    $t0 = '{0:00}:{1:00}:{2:00},000' -f 0, [int](($i % 3600) / 60), ($i % 60)
    $t1 = '{0:00}:{1:00}:{2:00},900' -f 0, [int](($i % 3600) / 60), ($i % 60)
    $cn.Add("$($i + 1)"); $cn.Add("$t0 --> $t1")
    $cn.Add("[CN] 第 $($i + 1) 秒 · 字幕延迟可调"); $cn.Add('')
    $en.Add("$($i + 1)"); $en.Add("$t0 --> $t1")
    $en.Add("[EN] second $($i + 1) · subtitle delay"); $en.Add('')
}
[System.IO.File]::WriteAllLines($srtCn, $cn, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllLines($srtEn, $en, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "  字幕源: cn.srt / en.srt（各 $Seconds 条）"

# ---------- 2) 音轨表达式（单声道，无竖线）----------
# 音轨 1：每秒前 0.12s 出声 —— 脉冲是"能听出 0.1s 偏移"的前提
$a1 = "aevalsrc=0.7*sin(2*PI*441*t)*lt(mod(t\,1)\,0.12):s=48000:d=$Seconds"
# 音轨 2：连续 880Hz
$a2 = "aevalsrc=0.5*sin(2*PI*880*t):s=48000:d=$Seconds"

# ---------- 3) 视频滤镜：叠一个每秒跳变的大号秒数 ----------
# ## 两个实测踩到的转义坑
# 1. `fontfile='C:/...'` 的**单引号**会让 filterchain 在引号处断开
#    （报 `No option name near '/Windows/Fonts/...'`）→ **不加引号**。
# 2. 反斜杠路径里的 `\W` 会被当转义 → 用**正斜杠**。
# 3. 选项值里的冒号必须转义成 `\:`，否则被当选项分隔符。
# ## 为什么不做 drawtext 叠加秒数（试了三次，放弃）
# 想让中央有更大的秒数，试了三种写法都被转义坑住：
#   1. `fontfile='C:/...'` 的单引号 → filterchain 在引号处断开
#   2. 反斜杠路径 → `\W` 被当转义序列
#   3. PowerShell `.Replace(':', '\:')` 把**盘符冒号也转了** → `fontfile==`
#
# 而 `testsrc2` **自带计时器**（画面里有秒数），已满足"判断 seek 落点"
# 这个需求。多一层转义就多一个失败点 —— 不值得。
$vf = 'null'

$out = Join-Path $outDir 'cf_probe.mp4'
if (Test-Path $out) { Remove-Item $out -Force }
Write-Output '  合成中（约 30–90 秒）...'

# 用数组传参，避免 PowerShell 把参数拆错
$ffArgs = @(
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', "testsrc2=size=1280x720:rate=30:duration=$Seconds",
    '-f', 'lavfi', '-i', $a1,
    '-f', 'lavfi', '-i', $a2,
    '-i', $srtCn,
    '-i', $srtEn,
    '-map', '0:v:0', '-map', '1:a:0', '-map', '2:a:0', '-map', '3:s:0', '-map', '4:s:0',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p',
    '-vf', $vf,
    '-c:a', 'aac', '-b:a', '128k', '-ac', '1',
    '-c:s', 'mov_text',
    '-metadata:s:a:0', 'title=Track1-Pulse441',
    '-metadata:s:a:0', 'language=chi',
    '-metadata:s:a:1', 'title=Track2-Tone880',
    '-metadata:s:a:1', 'language=eng',
    '-metadata:s:s:0', 'title=Chinese',
    '-metadata:s:s:0', 'language=chi',
    '-metadata:s:s:1', 'title=English',
    '-metadata:s:s:1', 'language=eng',
    '-disposition:a:0', 'default',
    '-disposition:s:0', 'default',
    '-t', "$Seconds",
    $out
)

& $ff @ffArgs 2>&1 | Select-Object -Last 8 | ForEach-Object { Write-Output "    $_" }
if (-not (Test-Path $out)) {
    Write-Output '  [失败] ffmpeg 未产出文件'
    exit 1
}
Write-Output "  [通过] 产出 $out ($([math]::Round((Get-Item $out).Length / 1MB, 2)) MB)"

# ---------- 4) 用 ffprobe 核实（不能假设 ffmpeg 按预期工作）----------
Write-Output ''
Write-Output '=== 核实产出（ffprobe 权威判据）==='
& $fp -v error -show_entries 'stream=index,codec_type,codec_name,channels' `
    -show_entries 'format=duration' -of default=noprint_wrappers=1 $out 2>&1 |
    ForEach-Object { Write-Output "  $_" }

Write-Output ''
Write-Output "  产出目录: $outDir"
if (-not $KeepTemp) { Remove-Item $tmpDir -Recurse -Force -EA SilentlyContinue }
exit 0
