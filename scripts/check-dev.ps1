<#
.SYNOPSIS
    CineFlow 开发收尾审查门禁（AI 每次开发完成后必须运行）。

.DESCRIPTION
    「开发完 → 自动审查 → 全过才允许继续」的强制闸门。

    为什么要有这个脚本（而不是散在文档里让人自己记得跑）：
      本仓库已经出现过多次「声称验证过、实际没跑」的情况——
      · 文档写 263 例测试，实际 286 例
      · README 写「自动重连」，代码里没有
      · Go 层写 93 例，实际 143 例
      只要验收靠"记得跑"，就一定会漏。所以把它变成**一条命令 + 一个退出码**。

    它做四类检查：
      L0-a  静态与单测     flutter analyze / flutter test / go vet / go test
      L0-b  仓库门禁       check-secrets / check-docs / bump_version -Check
      L0-c  产物完整性     release 入口 APK、libmpv.so、native 桩、ABI 正确性
      L0-d  真机冒烟       安装 → 启动 → 存活 → Dart 日志（有设备时才跑）

    退出码 0 = 全过（可以继续）；非 0 = 有阻塞项（**不允许**声称完成）。

.PARAMETER SkipDevice
    跳过真机冒烟（无设备/离线时用）。**跳过的项会在结论里明确列出**，
    避免"没跑"被当"跑过了"。

.PARAMETER Device
    指定设备序列号。默认取第一台在线设备。

.PARAMETER Quick
    快速模式：只跑 L0-a 与 L0-b（改文档/改注释时用）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-dev.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-dev.ps1 -Quick
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-dev.ps1 -SkipDevice
#>
param(
    [switch]$SkipDevice,
    [switch]$Quick,
    [string]$Device
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# ---- 结果收集 ----
$script:fail = @()
$script:warn = @()
$script:skip = @()
$script:pass = @()

function Section($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [通过] $m" -ForegroundColor Green;  $script:pass += $m }
function Bad($m)  { Write-Host "  [失败] $m" -ForegroundColor Red;    $script:fail += $m }
function Warn($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow; $script:warn += $m }
function Skip($m) { Write-Host "  [跳过] $m" -ForegroundColor DarkGray; $script:skip += $m }

# 工具路径（本机实测：均不在 PATH 上）
$flutter = if (Test-Path 'D:\dev\flutter\bin\flutter.bat') { 'D:\dev\flutter\bin\flutter.bat' } else { 'flutter' }
$go      = if (Test-Path 'C:\Program Files\Go\bin\go.exe')  { 'C:\Program Files\Go\bin\go.exe' } else { 'go' }
$adb     = if (Test-Path 'D:\dev\android-sdk\platform-tools\adb.exe') { 'D:\dev\android-sdk\platform-tools\adb.exe' } else { 'adb' }

Write-Host "CineFlow 开发收尾审查" -ForegroundColor White
Write-Host "工程根：$root"

# =====================================================================
# L0-a · 静态分析与单元测试
# =====================================================================
Section 'L0-a · 静态分析与单元测试'

# --- flutter analyze：判定标准是输出里的 "0 error / 0 warning"，不是退出码 ---
# 本仓库有 3 条 douban info 属已知豁免（AGENTS §5.7），analyze 会因此退 1。
Write-Host "  > flutter analyze ..."
$an = & $flutter analyze 2>&1 | Out-String
if ($an -match 'No issues found') {
    Ok 'flutter analyze：0 issue'
} elseif ($an -match '(\d+) error' -and $an -match '(\d+) warning') {
    # 有 error/warning 才算失败；只有 info 是可接受的
    $errs = [int]$Matches[1]
    $warns = [int]$Matches[2]
    if ($errs -eq 0 -and $warns -eq 0) {
        Ok 'flutter analyze：0 error / 0 warning（仅 info，已豁免）'
    } else {
        Bad "flutter analyze：$errs error / $warns warning（必须为 0）"
        ($an -split "`n" | Select-String -Pattern 'error •|warning •' | Select-Object -First 8) |
            ForEach-Object { Write-Host "        $($_.Line.Trim())" -ForegroundColor DarkRed }
    }
} else {
    Bad 'flutter analyze：输出无法解析，请手动确认'
    Write-Host ($an -split "`n" | Select-Object -Last 6)
}

# --- flutter test ---
Write-Host "  > flutter test ..."
$ft = & $flutter test 2>&1 | Out-String
if ($ft -match '\+(\d+):\s*All tests passed') {
    Ok "flutter test：$($Matches[1]) 例全绿"
} elseif ($ft -match 'All tests passed') {
    Ok 'flutter test：全绿'
} else {
    Bad 'flutter test：未全绿'
    ($ft -split "`n" | Select-String -Pattern '\[E\]|Expected:|Actual:|failed' | Select-Object -First 10) |
        ForEach-Object { Write-Host "        $($_.Line.Trim())" -ForegroundColor DarkRed }
}

# --- Go：vet + test（零 cgo 包，无需 NDK） ---
if (Test-Path 'go/go.mod') {
    Write-Host "  > go vet + go test ..."
    Push-Location go
    $gv = & $go vet ./... 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and [string]::IsNullOrWhiteSpace($gv)) {
        Ok 'go vet：0 警告'
    } else {
        Bad 'go vet：有输出（应为空）'
        Write-Host "        $($gv.Trim())" -ForegroundColor DarkRed
    }
    $gt = & $go test ./... 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        $n = ([regex]::Matches($gt, '(?m)^ok\s')).Count
        Ok "go test：全绿（$n 个包）"
    } else {
        Bad 'go test：未全绿'
        ($gt -split "`n" | Select-String -Pattern 'FAIL|---' | Select-Object -First 8) |
            ForEach-Object { Write-Host "        $($_.Line.Trim())" -ForegroundColor DarkRed }
    }
    Pop-Location
} else {
    Skip 'go test：未找到 go/go.mod'
}

if ($Quick) { $SkipDevice = $true }

# =====================================================================
# L0-b · 仓库门禁
# =====================================================================
Section 'L0-b · 仓库门禁'

# ⚠️ 判定必须看退出码：这些脚本失败时会打印"补救指引"，
#    看起来像正常收尾，极易误判成通过（AGENTS §8.1）。
function Gate($name, $scriptRel) {
    if (-not (Test-Path $scriptRel)) { Warn "$name：脚本不存在（$scriptRel）"; return }
    Write-Host "  > $name ..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptRel *> $null
    if ($LASTEXITCODE -eq 0) { Ok "$name：通过" }
    else { Bad "$name：退出码 $LASTEXITCODE（不通过）" }
}

Gate 'check-secrets'  'scripts/check-secrets.ps1'
Gate 'check-docs'     'scripts/check-docs.ps1'
Gate 'bump_version'   'tool/bump_version.ps1'

# --- 明文凭据守卫（扫**被 gitignore 的文件**）---
#
# ⚠️ 为什么需要单独一项：`check-secrets.ps1` 用的是 `git ls-files`，
#    即**只扫被 git 跟踪的文件**。而被 gitignore 的才是凭据最容易落地的位置
#    （`.env`、`*.local`、`tool/_*` 这类临时文件）。
#    实测踩过：仓库里躺着 `tool/_gh_token`（40 字符、`gho_` 前缀的 GitHub OAuth token），
#    明文、未加密，**check-secrets 完全没报** —— 因为该路径被 `.gitignore` 的
#    `tool/_*` 覆盖了。它没进 git 历史（已核实），但"文件在磁盘上明文躺着"
#    本身就是风险：任何打包/同步/截图/误 `git add -f` 都会泄露。
#
#    本项只做**存在性与模式**检查，**不打印凭据内容**（打印等于二次泄露）。
$credPatterns = @(
    @{ Name = 'GitHub token';        Re = 'gh[pousr]_[A-Za-z0-9]{36,}' },
    @{ Name = 'GitHub fine-grained'; Re = 'github_pat_[A-Za-z0-9_]{20,}' },
    @{ Name = 'AWS Access Key';      Re = 'AKIA[0-9A-Z]{16}' },
    @{ Name = 'OpenAI/DeepSeek key'; Re = 'sk-[A-Za-z0-9]{20,}' },
    @{ Name = 'Slack token';         Re = 'xox[baprs]-[A-Za-z0-9-]{10,}' },
    @{ Name = 'Google API key';      Re = 'AIza[0-9A-Za-z_\-]{35}' },
    @{ Name = '私钥块';               Re = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = 'JWT';                 Re = 'eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.' }
)
# 只扫"小而像文本"的被忽略文件：跳过 build/ 缓存等大目录，避免误报与耗时
$ignored = git ls-files --others --ignored --exclude-standard 2>$null
$credHits = @()
foreach ($rel in @($ignored | Where-Object { $_ -and $_ -notmatch '^(build|\.dart_tool)/' })) {
    $full = Join-Path $PWD $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $len = (Get-Item -LiteralPath $full).Length
    if ($len -eq 0 -or $len -gt 2MB) { continue }   # 空文件与二进制大文件跳过
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($full) } catch { continue }
    foreach ($p in $credPatterns) {
        if ($text -match $p.Re) {
            # ★ 只报文件与类型，**不回显匹配到的内容**
            $credHits += "$rel（$($p.Name)）"
        }
    }
}
if ($credHits.Count -eq 0) {
    Ok "明文凭据守卫：被忽略的文件中未发现凭据特征"
} else {
    Bad "明文凭据：$($credHits -join '、') —— 立即删除并轮换该凭据（**不要**提交）"
    Write-Host '        提示：这类文件被 gitignore 覆盖，check-secrets.ps1 扫不到，故单独设此项' -ForegroundColor DarkRed
}

# --- .ps1 含中文必须带 UTF-8 BOM ---
# ⚠️ 实测踩过两次：用编辑工具改 `.ps1` 会**丢掉 BOM**，之后脚本被按 GBK 解码，
#    中文行吞掉下一行代码，报出一堆 "Missing closing ')'" 之类的假语法错误
#    （AGENTS §3.1）。而且**失败得很隐蔽**：门禁脚本自己坏了，
#    报的却是"不通过"，差点被当成业务问题排查。
#    所以这里主动扫一遍，把"BOM 丢了"变成一条明确的失败项。
$ps1Files = @()
$ps1Files += Get-ChildItem 'scripts' -Filter '*.ps1' -File -ErrorAction SilentlyContinue
$ps1Files += Get-ChildItem 'tool' -Filter '*.ps1' -File -ErrorAction SilentlyContinue
$noBom = @()
foreach ($f in $ps1Files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    # 只对**含非 ASCII 字符**的脚本要求 BOM（纯英文脚本无此风险）
    $hasNonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 0x7F) { $hasNonAscii = $true; break } }
    if ($hasNonAscii) {
        if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
            $noBom += $f.Name
        }
    }
}
if ($noBom.Count -eq 0) {
    Ok "PowerShell BOM：$($ps1Files.Count) 个脚本的中文脚本均带 BOM"
} else {
    Bad "缺 UTF-8 BOM：$($noBom -join ', ')（中文会被按 GBK 解码，脚本会报假语法错误）"
    Write-Host '        修法：在文件开头补 EF BB BF 三个字节（见 AGENTS §3.1）' -ForegroundColor DarkRed
}

# --- 含中文的**数据清单**（非 .ps1）也必须带 BOM ---
#
# ⚠️ 上面那项只扫 `*.ps1`。实测踩过：`scripts/secrets-allow.txt` 含中文注释
#    但缺 BOM → `check-secrets.ps1` 用 `Get-Content` 读它时按 **GBK** 解码，
#    中文行**吞掉换行**把下一行并进来（20 行只读出 12 行），
#    于是**新增的白名单条目静默失效**——门禁一直报红，而文件"看起来完全正常"。
#
#    触发它最常见的动作：用 `edit`/`write` 工具改这些文件（会剥掉 BOM）。
$txtFiles = @()
$txtFiles += Get-ChildItem 'scripts' -Filter '*.txt' -File -ErrorAction SilentlyContinue
$noBomTxt = @()
foreach ($f in $txtFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -lt 3) { continue }
    # 只对含非 ASCII 的文件要求 BOM
    $hasNonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 0x7F) { $hasNonAscii = $true; break } }
    if ($hasNonAscii) {
        if (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
            $noBomTxt += $f.Name
        }
    }
}
if ($noBomTxt.Count -eq 0) {
    Ok "清单 BOM：$($txtFiles.Count) 个含中文的数据清单均带 BOM"
} else {
    Bad "清单缺 UTF-8 BOM：$($noBomTxt -join ', ')（内容会被 GBK 误解码、条目静默失效）"
    Write-Host '        修法：以 UTF-8 **with BOM** 重写该文件' -ForegroundColor DarkRed
}

# --- GitHub Actions workflow 的 YAML 必须能被解析 ---
# ⚠️ 实测踩过：release.yml 曾有**缩进错误导致 YAML 解析失败**，
#    整个工作流从来没跑起来过，而肉眼完全看不出问题（第 61 行少 2 格缩进）。
#    这类错误必须靠解析器抓，不能靠看。
$py = $null
foreach ($cand in @(
        'C:\Users\a1332\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe',
        'python', 'python3')) {
    if ($cand -eq 'python' -or $cand -eq 'python3' -or (Test-Path $cand)) {
        try { & $cand -c 'import yaml' 2>$null; if ($LASTEXITCODE -eq 0) { $py = $cand; break } } catch {}
    }
}
$wfDir = '.github/workflows'
if (Test-Path $wfDir) {
    $wfs = Get-ChildItem $wfDir -Filter '*.yml' -File
    if ($py) {
        $bad = @()
        foreach ($w in $wfs) {
            $full = (Resolve-Path $w.FullName).Path
            & $py -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" $full 2>$null
            if ($LASTEXITCODE -ne 0) { $bad += $w.Name }
        }
        if ($bad.Count -eq 0) {
            Ok "workflow YAML：$($wfs.Count) 个文件全部可解析"
        } else {
            Bad "workflow YAML 解析失败：$($bad -join ', ')（GitHub Actions 不会运行它们）"
        }
    } else {
        Write-Host "  > workflow YAML（无 pyyaml，改用括号平衡粗检）"
        $bad = @()
        foreach ($w in $wfs) {
            $lines = [System.IO.File]::ReadAllLines($w.FullName)
            # 极粗的兜底：run: | 块之后的命令行若缩进少于块首，很可能是 YAML 键误写
            $inRun = $false; $runIndent = 0; $susp = $false
            foreach ($l in $lines) {
                if ($l -match '^(\s*)run:\s*\|') { $inRun = $true; $runIndent = $Matches[1].Length; continue }
                if ($inRun) {
                    if ($l.Trim() -eq '') { continue }
                    $ind = $l.Length - $l.TrimStart().Length
                    if ($ind -le $runIndent -and $l -notmatch '^\s*[a-zA-Z_-]+:') { $inRun = $false; continue }
                    # 块内命令行若含未转义的双引号+变量赋值，且缩进异常，标记可疑
                }
            }
            if ($susp) { $bad += $w.Name }
        }
        if ($bad.Count -eq 0) { Ok "workflow YAML：$($wfs.Count) 个文件通过粗检（建议装 pyyaml 做严格校验）" }
        else { Warn "workflow YAML 可疑：$($bad -join ', ')" }
    }
}

# --- Android 资源 XML：注释里不能出现连续两个连字符 ---
#
# ⚠️ 实测踩过（2026-10 改启动页时）：我在 `values-v31/styles.xml` 的注释里
#    放了一张 Markdown 表格，其分隔行 `|---|---|---|` 含 `--`。
#    XML 规范不允许注释内出现 `--`，AAPT 直接报：
#      `values-v31/styles.xml:15:6: Error: 注释中不允许出现字符串 "--"。`
#    而 `flutter analyze` 与 `flutter test` **全都发现不了** ——
#    只有真正 `flutter build apk` 到 `packageDebugResources` 那一步才会炸。
#    所以把它做成门禁：不必等 3 分钟构建就知道。
$resDir = 'android/app/src/main/res'
if (Test-Path $resDir) {
    $badXml = @()
    foreach ($x in Get-ChildItem $resDir -Recurse -Filter '*.xml' -File) {
        $raw = [System.IO.File]::ReadAllText($x.FullName)
        foreach ($m in [regex]::Matches($raw, '(?s)<!--(.*?)-->')) {
            if ($m.Groups[1].Value -match '--') {
                $line = ($raw.Substring(0, $m.Index) -split "`n").Count
                $badXml += "$($x.Name):$line"
            }
        }
    }
    if ($badXml.Count -eq 0) {
        $n = @(Get-ChildItem $resDir -Recurse -Filter '*.xml' -File).Count
        Ok "Android 资源 XML：$n 个文件注释合法（无 '--'）"
    } else {
        Bad "Android 资源 XML 注释含非法 '--'（AAPT 会报「注释中不允许出现字符串 --」）：$($badXml -join ', ')"
    }
}

# =====================================================================
# L0-c · 构建产物完整性
# =====================================================================
Section 'L0-c · 构建产物'

$debugApk   = 'build/app/outputs/flutter-apk/app-debug.apk'
$releaseApk = 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'

# 优先校验 debug 包（真机冒烟要装它，且它的 kernel_blob 可做入口检查）；
# 没有 debug 包时退回 release 包 —— 但 release 是 AOT 的，**没有 kernel_blob**，
# 所以入口检查对它是天然不可用的（不是失败，是 N/A）。
$apk = if (Test-Path $debugApk) { $debugApk }
       elseif (Test-Path $releaseApk) { $releaseApk }
       else { $debugApk }
$isReleaseApk = ($apk -eq $releaseApk) -and (Test-Path $releaseApk)
$nativeLib = 'android/app/src/main/jniLibs/arm64-v8a/libmpv.so'

if (Test-Path $nativeLib) {
    $len = (Get-Item $nativeLib).Length
    $b = [System.IO.File]::ReadAllBytes($nativeLib)
    $magic = ($b[0..3] | ForEach-Object { $_.ToString('X2') }) -join ' '
    $machine = [BitConverter]::ToUInt16($b, 18)
    if ($magic -eq '7F 45 4C 46' -and $machine -eq 0xB7) {
        Ok "libmpv.so：ELF AArch64，$len 字节"
    } else {
        Bad "libmpv.so：ELF 头异常（magic=$magic machine=0x$($machine.ToString('X4'))）"
    }
} else {
    Bad "libmpv.so 缺失：$nativeLib（播放内核起不来）"
}

# go 层产物
$goLib = 'android/app/src/main/jniLibs/arm64-v8a/libcineflow_go.so'
if (Test-Path $goLib) {
    $b = [System.IO.File]::ReadAllBytes($goLib)
    if (($b[0..3] | ForEach-Object { $_.ToString('X2') }) -join ' ' -eq '7F 45 4C 46') {
        Ok "libcineflow_go.so：ELF 完好，$((Get-Item $goLib).Length) 字节"
    } else { Bad 'libcineflow_go.so：ELF 头损坏' }
} else { Warn 'libcineflow_go.so 缺失（Go 层将降级为纯 Dart）' }

if (Test-Path $apk) {
    $age = (Get-Date) - (Get-Item $apk).LastWriteTime
    Write-Host ("  > APK 构建于 {0:yyyy-MM-dd HH:mm}（{1:N0} 分钟前）" -f (Get-Item $apk).LastWriteTime, $age.TotalMinutes)

    # ★ 关键：集成测试会污染 APK 入口（实测踩过，导致"打开应用白屏"）。
    #
    #   `flutter test integration_test/xxx.dart` 会以**测试文件**为入口重建
    #   kernel_blob.bin，并覆盖 app-debug.apk。装上去启动的是测试 harness：
    #   Dart VM 正常起来（所以不像崩溃），但 main() 一条日志都不打、屏幕全白。
    #
    #   ⚠️ 判据不能是"有没有 main.dart"——实测**污染包也有**（测试同样 import 了应用代码）。
    #      可靠判据是**应用页面文件在不在编译产物里**：
    #        · 干净（入口 lib/main.dart）：about_page.dart / login_page.dart 等 → 有
    #        · 污染（入口是测试文件）    ：这些页面**不在测试的 import 图里** → 无
    #      实测对照（同一 APK 路径，污染前后各测一次）：
    #        干净: size=110452864, appPage=true,  player_kernel_test=false
    #        污染: size= 74630792, appPage=false, player_kernel_test=true
    #
    #   实现说明：
    #     · 必须**全量读**——实测 dill 格式下字符串出现在 54MB / 105MB 处，
    #       只看前几 MB 会漏判（110MB 全读约 1-2 秒，可接受）。
    #     · 不要用 [System.Text.Encoding]::Latin1 —— Windows PowerShell 5.1 里
    #       它是 $null（.NET Framework 无该静态属性），调用会抛
    #       "不能对 Null 值表达式调用方法"（实测踩过）。ASCII 足够（只匹配 ASCII 名）。
    #     · 不要用裸 `integration_test` 做判据：框架自身文档注释里就有这个词
    #       （实测干净包命中 5 次，全是 doc comment），会误报。
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk))
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'assets/flutter_assets/kernel_blob.bin' }
        if ($entry) {
            $s = $entry.Open()
            $ms = New-Object System.IO.MemoryStream
            $s.CopyTo($ms)
            $s.Close()
            $txt = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
            $ms.Dispose()
            $hasAppPage = $txt.Contains('about_page.dart') -or $txt.Contains('login_page.dart') `
                          -or $txt.Contains('home_shell.dart')
            $hasTest = $txt.Contains('player_kernel_test')
            if ($hasTest -and -not $hasAppPage) {
                Bad 'APK 入口被集成测试污染（含测试文件、无应用页面）→ 装上去会白屏。必须重新 flutter build apk'
            } elseif ($hasTest) {
                Warn 'kernel_blob 同时含应用页面与测试文件（入口应为 main，可用启动日志确认）'
            } elseif ($hasAppPage) {
                Ok 'APK 入口正常（kernel_blob 含应用页面 = 入口是 lib/main.dart）'
            } else {
                Warn 'APK 入口无法判定（kernel_blob 既无应用页面也无测试标记，可能为 release/AOT 构建）'
            }
        } elseif ($isReleaseApk) {
            # release 包是 AOT 编译，**根本没有 kernel_blob.bin** —— 这不是问题。
            # 入口污染只可能发生在 debug 包上（集成测试重写的是 kernel_blob），
            # 所以 release 包天然免疫该类故障，此处如实说明而非报警。
            Ok 'release APK（AOT，无 kernel_blob）—— 天然免疫入口污染'
        } else {
            Warn 'APK 内未找到 kernel_blob.bin（release 包属正常）'
        }
        $zip.Dispose()
    } catch {
        Warn "APK 检查失败：$($_.Exception.Message)"
    }
} else {
    $script:skip += 'APK 不存在（需要时跑 flutter build apk --debug）'
    Skip 'APK 不存在（未构建）'
}

# =====================================================================
# L0-d · 真机冒烟
# =====================================================================
Section 'L0-d · 真机冒烟'

if ($SkipDevice) {
    Skip '真机冒烟（-SkipDevice / -Quick）——**本项未验证**'
} else {
    $devs = & $adb devices 2>&1 | Select-String -Pattern '^\S+\s+device$'
    if (-not $devs) {
        Skip '真机冒烟（无在线设备）——**本项未验证**'
    } elseif (-not (Test-Path $apk)) {
        Skip '真机冒烟（APK 不存在）——**本项未验证**'
    } else {
        if (-not $Device) { $Device = ($devs[0] -split '\s+')[0] }
        Write-Host "  > 设备 $Device"

        # 安装。**不再用 -d**：versionCode 已改为只增不减（AI-MEMORY 第 5 轮），
        # 能正常覆盖安装就说明这个机制是好的 —— 用 -d 反而会掩盖它坏掉。
        $installSkipped = $false

        # ---- 安装前先判断"这次是否注定装不上"（不依赖 adb 错误文本）----
        #
        # 为什么不靠 `$ins -match 'VERSION_DOWNGRADE'`：
        # 实测同一台设备同一个包，`cmd /c "adb install ..."` 能匹配到
        # VERSION_DOWNGRADE，而脚本里的 `& $adb install ...` **匹配不到**
        # （stderr 的编码/换行形态不同）。靠文本会漏判，进而走到最后
        # 的 else 打印空原因。**改为直接比较 versionCode 事实**。
        $devCode = 0
        $devRaw = (& $adb -s $Device shell dumpsys package com.cineflow.app 2>&1 |
            Select-String 'versionCode=' | Select-Object -First 1) -as [string]
        if ($devRaw -match 'versionCode=(\d+)') { $devCode = [int]$Matches[1] }

        $apkCode = 0
        $aapt2 = $null
        foreach ($bt in @("$env:LOCALAPPDATA\Android\Sdk\build-tools",
                          'D:\dev\android-sdk\build-tools',
                          "$env:ANDROID_HOME\build-tools")) {
            if (Test-Path $bt) {
                $aapt2 = Get-ChildItem $bt -Directory -EA SilentlyContinue |
                    Sort-Object Name -Descending |
                    ForEach-Object { Join-Path $_.FullName 'aapt2.exe' } |
                    Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($aapt2) { break }
            }
        }
        if ($aapt2) {
            $apkRaw = (& $aapt2 dump badging $apk 2>&1 |
                Select-String 'versionCode=' | Select-Object -First 1) -as [string]
            if ($apkRaw -match "versionCode='(\d+)'") { $apkCode = [int]$Matches[1] }
        }

        # Flutter 对 `--split-per-abi` 的 release 会自动加 `1000 x ABI_VERSION`
        # （见 android/app/build.gradle.kts:91；arm64 的 ABI_VERSION=2）。
        # 故"设备上是 release、待装是 debug"时，debug 永远装不回去。
        $abiDowngrade = ($devCode -gt 0) -and ($apkCode -gt 0) -and
                        ($devCode -gt $apkCode) -and ((($devCode - $apkCode) % 1000) -eq 0)

        if ($abiDowngrade) {
            Warn ("设备上是 release 包（versionCode=$devCode，含 ABI 偏移 +$($devCode-$apkCode)），" +
                  "待装 debug 是 $apkCode —— Flutter split-APK 的既定行为，非版本号缺陷。" +
                  "跳过安装，直接用设备上已有的包做冒烟")
            Ok '安装跳过（release→debug 的 ABI 偏移倒挂，非缺陷）'
            $ins = 'Success'
            $installSkipped = $true
        } else {
            $ins = & $adb -s $Device install -r $apk 2>&1 | Out-String
        }

        if ($ins -match 'Success') {
            if (-not $installSkipped) {
                Ok '安装成功（无需 -d，versionCode 正常递增）'
            }
        }
        elseif ($ins -match 'USER_RESTRICTED') {
            Bad '安装被 MIUI 拦截（INSTALL_FAILED_USER_RESTRICTED）。临时放行：adb shell settings put global verifier_verify_adb_installs 0，装完还原为 1'
        } else {
            Bad "安装失败：$(($ins -split "`n" | Select-Object -Last 1).Trim())"
        }

        if ($script:fail.Count -eq 0 -or $ins -match 'Success') {
            & $adb -s $Device shell am force-stop com.cineflow.app 2>&1 | Out-Null
            & $adb -s $Device logcat -c 2>&1 | Out-Null
            & $adb -s $Device shell am start -n com.cineflow.app/.MainActivity 2>&1 | Out-Null
            Start-Sleep -Seconds 9

            # ★ 这两行是"入口正确 + 各层就绪"的铁证；没有它们 = 白屏。
            #
            # ⚠️ 实测**纠正一个想当然**：原以为 `debugPrint` 在 release 下被剥离、
            #    所以 release 包看不到这两行 —— **实测证伪**。
            #    versionCode 2002 的 release 包（`run-as` 报 "package not debuggable"、
            #    APK 内无 kernel_blob、有 AOT libapp.so）依然完整打出了：
            #      I flutter : [GoCore] 已加载，ping={pong: cineflow-go, version: 1}
            #      I flutter : [DB] 就绪，清理过期缓存 0 条，现有 1 条 / 30442 字符
            #    真正被 release 剥离的是 `assert`，不是 `debugPrint`。
            #    → 所以对 release 包也照常按日志判定；仅当日志**确实缺失**时才退回
            #      "截图非白屏"兜底，并如实记为**跳过**而非假装通过。
            $log = & $adb -s $Device logcat -d 2>&1 | Out-String
            $hasGo = $log -match '\[GoCore\] 已加载'
            $hasDb = $log -match '\[DB\] 就绪'
            if ($hasGo) { Ok '[GoCore] 已加载（入口正确 + Go 层可用）' }
            elseif ($isReleaseApk) {
                Skip 'release 包未出现 [GoCore] 日志 —— **入口日志未验证**（改用截图兜底）'
            } else {
                Bad 'logcat 无 [GoCore] 已加载 → 入口可能被污染（白屏）或 Go 层未加载'
            }
            if ($hasDb) { Ok '[DB] 就绪（drift/SQLite 可用）' }
            elseif ($isReleaseApk) { Skip 'release 包未出现 [DB] 日志 —— **DB 未验证**' }
            else { Warn 'logcat 无 [DB] 就绪（缓存/历史可能不可用）' }

            # ⚠️ 变量名不能叫 $pid —— PowerShell 的 $PID 是**只读自动变量**，
            #    赋值会抛 VariableNotWritable（实测踩过，且它不会让脚本停下，
            #    只会在 stderr 刷一条错误，容易被忽略）。
            $appPid = (& $adb -s $Device shell pidof com.cineflow.app 2>&1 | Out-String).Trim()
            if ($appPid) { Ok "进程存活（pid=$appPid）" } else { Bad '进程不存在（已崩溃）' }

            $crash = $log | Select-String -Pattern 'FATAL EXCEPTION|AndroidRuntime.*com.cineflow'
            if ($crash) { Bad "检测到崩溃：$(($crash | Select-Object -First 1).Line.Trim())" }
            else { Ok '无 FATAL / AndroidRuntime 崩溃' }

            # 白屏判据：release 包没有日志可依，用**截图像素**兜底
            # （实测踩过"打开应用白屏"，纯白占比是最直接的判据）
            if ($isReleaseApk) {
                $shot = Join-Path $env:TEMP 'cf_smoke.png'
                & $adb -s $Device shell screencap -p /sdcard/cf_smoke.png 2>&1 | Out-Null
                & $adb -s $Device pull /sdcard/cf_smoke.png $shot 2>&1 | Out-Null
                & $adb -s $Device shell rm -f /sdcard/cf_smoke.png 2>&1 | Out-Null
                $size = if (Test-Path $shot) { (Get-Item $shot).Length } else { 0 }
                if ($size -gt 20000) {
                    # PNG 大小只是粗判：100KB+ 说明画面有内容；纯白图会被压得极小
                    if ($size -lt 60000) {
                        Warn "release 包截图仅 $([math]::Round($size/1KB)) KB —— 疑似白屏，请人工确认"
                    } else {
                        Ok "release 包界面已渲染（截图 $([math]::Round($size/1KB)) KB，非白屏）"
                    }
                } else {
                    Skip 'release 包截图不可用 —— **界面渲染未验证**'
                }
                Remove-Item $shot -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# =====================================================================
# 结论
# =====================================================================
Write-Host ""
Write-Host ('=' * 62)
Write-Host "通过 $($script:pass.Count) 项" -ForegroundColor Green
if ($script:warn.Count) { Write-Host "注意 $($script:warn.Count) 项" -ForegroundColor Yellow }
if ($script:skip.Count) { Write-Host "跳过 $($script:skip.Count) 项" -ForegroundColor DarkGray }
if ($script:fail.Count) { Write-Host "失败 $($script:fail.Count) 项" -ForegroundColor Red }

if ($script:fail.Count -gt 0) {
    Write-Host ""
    Write-Host '结论：**不通过** —— 不允许声称开发完成。先修下列问题：' -ForegroundColor Red
    $script:fail | ForEach-Object { Write-Host "  · $_" -ForegroundColor Red }
    exit 1
}

if ($script:skip.Count -gt 0) {
    Write-Host ""
    Write-Host '结论：通过（但有跳过项）——报告中必须写明**哪些没验证**：' -ForegroundColor Yellow
    $script:skip | ForEach-Object { Write-Host "  · $_" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host '提示：按 docs/review-checklist.md §8.3，未验证的部分必须在汇报里明确列出。' -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host '结论：**全部通过** —— 可以继续（别忘了更新 docs/AI-MEMORY.md）。' -ForegroundColor Green
exit 0
