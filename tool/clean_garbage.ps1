<#
.SYNOPSIS
    清理构建垃圾，**只保留发布所需的 APK 与其混淆符号表**。

.DESCRIPTION
    为什么需要独立脚本：
      `flutter clean` 会把 `build/symbols/` 也删掉 —— 而那是**排查线上崩溃的唯一依据**
      （AGENTS §9 明令「不要删除 build/symbols/」）。
      发布产物与混淆符号表必须**成对保留**：APK 是混淆过的，没有对应符号表，
      用户报的崩溃堆栈就是一堆 a.b.c，无法定位。
      本脚本因此不复用 `flutter clean`，而是精确删除、精确保留。

    保留（不可再生 / 排查依赖）：
      build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   发布产物
      build/app/outputs/flutter-apk/checksums.txt              完整性校验
      build/symbols/*.symbols                                  混淆符号表（与上面 APK 配套）

    删除（全部可重建）：
      build/app/intermediates · generated · tmp · kotlin · outputs/{apk,logs,mapping,...}
      build/ 下各插件目录、build/*.dill 编译缓存
      .dart_tool/{flutter_build,hooks_runner,build,build_resolvers}
      android/{.gradle,.kotlin}
      tool/icon/_gen            （Edge headless 残渣，gen_icons.sh 可重建）
      除 arm64 release 外的其他 APK（含 debug 包与另两个 ABI）

.PARAMETER KeepDebug
    额外保留 app-debug.apk（要跑真机冒烟前用）。

.PARAMETER DryRun
    只报告将删除什么，不动任何文件。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tool/clean_garbage.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tool/clean_garbage.ps1 -DryRun
    powershell -NoProfile -ExecutionPolicy Bypass -File tool/clean_garbage.ps1 -KeepDebug
#>
param(
    [switch]$KeepDebug,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# ---- 必须保留的（释放发布前务必确认这三类都在）----
$releaseApk = 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
$checksums  = 'build/app/outputs/flutter-apk/checksums.txt'
$symbolsDir = 'build/symbols'

Write-Host '== CineFlow 构建垃圾清理 =='
if ($DryRun) { Write-Host '（DryRun：只报告，不删除）' -ForegroundColor Yellow }
Write-Host ''

$freed = 0
function Remove-Target([string]$rel) {
    if (-not (Test-Path $rel)) { return }
    $abs = (Resolve-Path $rel).Path
    # 安全闸：只允许删本仓库内、且不在保留清单里的路径
    if ($abs -notlike "$root\*") { Write-Host "  [跳过] 越界路径：$abs" -ForegroundColor Yellow; return }
    if ($abs -eq (Resolve-Path $symbolsDir -ErrorAction SilentlyContinue).Path) {
        Write-Host '  [跳过] build/symbols（排查崩溃要用，§9 明令保留）' -ForegroundColor Green; return
    }
    $size = (Get-ChildItem $abs -Recurse -File -Force -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
    if (-not $size) { $size = (Get-Item $abs).Length }
    if ($DryRun) {
        Write-Host ("  [将删] {0,-46} {1,9:N1} MB" -f $rel, ($size / 1MB))
    } else {
        Remove-Item -LiteralPath $abs -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ("  [已删] {0,-46} {1,9:N1} MB" -f $rel, ($size / 1MB))
    }
    $script:freed += $size
}

# ---- 1) build/ 根下的目录（保留 app 与 symbols）----
Get-ChildItem 'build' -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('app', 'symbols') } |
    ForEach-Object { Remove-Target ("build\" + $_.Name) }

# ---- 2) build/app 下的中间产物（保留 outputs/flutter-apk）----
Get-ChildItem 'build\app' -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'outputs' } |
    ForEach-Object { Remove-Target ("build\app\" + $_.Name) }
Get-ChildItem 'build\app\outputs' -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'flutter-apk' } |
    ForEach-Object { Remove-Target ("build\app\outputs\" + $_.Name) }

# ---- 3) build 根的 dill 编译缓存（每个 80-105MB）----
Get-ChildItem 'build' -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.dill', '.json' } |
    ForEach-Object { Remove-Target ("build\" + $_.Name) }

# ---- 4) APK：只留 arm64 release（+ 可选 debug）----
Get-ChildItem 'build\app\outputs\flutter-apk' -File -Force -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -ne 'app-arm64-v8a-release.apk' -and
        $_.Name -ne 'checksums.txt' -and
        -not ($KeepDebug -and $_.Name -eq 'app-debug.apk')
    } |
    ForEach-Object { Remove-Target ("build\app\outputs\flutter-apk\" + $_.Name) }

# ---- 5) 其他可再生缓存 ----
foreach ($t in @('.dart_tool/flutter_build', '.dart_tool/hooks_runner',
                 '.dart_tool/build', '.dart_tool/build_resolvers',
                 'android/.gradle', 'android/.kotlin', 'tool/icon/_gen')) {
    Remove-Target $t
}

Write-Host ''
Write-Host '== 保留清单核对 =='
foreach ($k in @($releaseApk, $checksums)) {
    if (Test-Path $k) {
        Write-Host ("  [保留] {0,-52} {1,8:N2} MB" -f $k, ((Get-Item $k).Length / 1MB)) -ForegroundColor Green
    } else {
        Write-Host "  [缺失] $k" -ForegroundColor Yellow
    }
}
if (Test-Path $symbolsDir) {
    Get-ChildItem $symbolsDir -File | ForEach-Object {
        Write-Host ("  [保留] {0,-52} {1,8:N2} MB" -f ("build/symbols/" + $_.Name), ($_.Length / 1MB)) -ForegroundColor Green
    }
} else {
    Write-Host '  [缺失] build/symbols/ —— 线上崩溃将无法解析！' -ForegroundColor Red
    Write-Host '         重建：flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols' -ForegroundColor Yellow
}

Write-Host ''
if ($DryRun) {
    Write-Host ("可回收：{0:N2} GB（未执行）" -f ($freed / 1GB)) -ForegroundColor Yellow
} else {
    Write-Host ("已回收：{0:N2} GB" -f ($freed / 1GB)) -ForegroundColor Green
    Write-Host '提示：删了 .dart_tool 缓存后首次构建会变慢，属正常。'
}
exit 0
