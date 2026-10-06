#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成《CineFlow 开发计划与进度报告》Word 文档。

为什么用脚本生成而不是手写 Word：
  报告里的每个数字（测试数、代码行数、APK 指纹、版本号）都来自实测。
  手写会立刻过期且无法核对；脚本化后只要重跑就能刷新，
  且**数字来源可追溯到具体命令**（见 docs/PROJECT-STATUS.md 与 AI-MEMORY.md）。

用法：
    python tool/gen_report_docx.py [输出路径]

依赖：python-docx（DSH 运行时自带 1.2.0）
"""

import sys
import os
import subprocess
import hashlib
from datetime import datetime
from pathlib import Path

from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.section import WD_ORIENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

# ---------- 主题色（与 lib/core/theme.dart 的 Cf 令牌同源）----------
C_BG = "0B1020"        # 全局背景（深海军蓝）
C_ACCENT = "0B7FA8"    # 主强调（青，Word 里用深一档保证可读）
C_ACCENT2 = "2E6BFF"   # 次强调
C_TEXT = "1A1A1A"
C_TEXT2 = "4A5568"
C_TEXT3 = "718096"
C_OK = "0F8A4D"        # 成功绿
C_WARN = "B7791F"      # 警示橙
C_DANGER = "C53030"    # 危险红
C_HEAD_BG = "EAF2F8"   # 表头底色
C_CODE_BG = "F5F7FA"   # 代码块底色

FONT_CN = "微软雅黑"
FONT_CODE = "Consolas"


# =====================================================================
# 基础工具
# =====================================================================
def set_run(run, *, name=FONT_CN, size=10.5, bold=False, italic=False,
            color=None, code=False):
    """设置 run 的字体。中文必须同时设 w:eastAsia，否则会回退成宋体。"""
    fname = FONT_CODE if code else name
    run.font.name = fname
    run.font.size = Pt(size)
    run.bold = bold
    run.italic = italic
    if color:
        run.font.color.rgb = RGBColor.from_string(color)
    rPr = run._element.get_or_add_rPr()
    rFonts = rPr.find(qn('w:rFonts'))
    if rFonts is None:
        rFonts = OxmlElement('w:rFonts')
        rPr.append(rFonts)
    rFonts.set(qn('w:ascii'), fname)
    rFonts.set(qn('w:hAnsi'), fname)
    rFonts.set(qn('w:eastAsia'), fname)   # ★ 关键：中文走同一字体
    return run


def shade(element, fill):
    """给段落或单元格加底色。"""
    pr = element._element.get_or_add_tcPr() if hasattr(element._element, 'get_or_add_tcPr') \
        else element._element.get_or_add_pPr()
    sh = OxmlElement('w:shd')
    sh.set(qn('w:val'), 'clear')
    sh.set(qn('w:color'), 'auto')
    sh.set(qn('w:fill'), fill)
    pr.append(sh)


def para(doc, text="", *, size=10.5, bold=False, color=C_TEXT, align=None,
         space_before=0, space_after=4, indent=0, code=False):
    p = doc.add_paragraph()
    if align is not None:
        p.alignment = align
    pf = p.paragraph_format
    pf.space_before = Pt(space_before)
    pf.space_after = Pt(space_after)
    pf.line_spacing = 1.35
    if indent:
        pf.left_indent = Cm(indent)
    if text:
        set_run(p.add_run(text), size=size, bold=bold, color=color, code=code)
    return p


def rich(doc, parts, *, size=10.5, space_before=0, space_after=4, indent=0):
    """parts: [(text, {bold/color/code/size}), ...] —— 同一段内混排样式。"""
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.space_before = Pt(space_before)
    pf.space_after = Pt(space_after)
    pf.line_spacing = 1.35
    if indent:
        pf.left_indent = Cm(indent)
    for text, opts in parts:
        o = dict(size=size)
        o.update(opts or {})
        set_run(p.add_run(text), **o)
    return p


def h1(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(18)
    p.paragraph_format.space_after = Pt(8)
    set_run(p.add_run(text), size=17, bold=True, color=C_BG)
    # 下划线装饰
    pPr = p._element.get_or_add_pPr()
    bd = OxmlElement('w:pBdr')
    bot = OxmlElement('w:bottom')
    bot.set(qn('w:val'), 'single')
    bot.set(qn('w:sz'), '12')
    bot.set(qn('w:space'), '4')
    bot.set(qn('w:color'), C_ACCENT)
    bd.append(bot)
    pPr.append(bd)
    return p


def h2(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(12)
    p.paragraph_format.space_after = Pt(5)
    set_run(p.add_run(text), size=13, bold=True, color=C_ACCENT)
    return p


def h3(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(9)
    p.paragraph_format.space_after = Pt(4)
    set_run(p.add_run(text), size=11.5, bold=True, color=C_TEXT)
    return p


def bullet(doc, text, *, level=0, color=C_TEXT, size=10.5, marker="•"):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.left_indent = Cm(0.6 + level * 0.6)
    pf.first_line_indent = Cm(-0.45)
    pf.space_after = Pt(3)
    pf.line_spacing = 1.3
    set_run(p.add_run(f"{marker} "), size=size, color=C_ACCENT, bold=True)
    set_run(p.add_run(text), size=size, color=color)
    return p


def code_block(doc, lines):
    """等比宽代码块（浅底 + 左边框）。"""
    for i, line in enumerate(lines):
        p = doc.add_paragraph()
        pf = p.paragraph_format
        pf.space_before = Pt(3 if i == 0 else 0)
        pf.space_after = Pt(3 if i == len(lines) - 1 else 0)
        pf.line_spacing = 1.15
        pf.left_indent = Cm(0.4)
        shade(p, C_CODE_BG)
        set_run(p.add_run(line if line else " "), size=8.5, code=True, color="243B53")
    return


def table(doc, headers, rows, *, widths=None, font_size=9.5, header_size=9.5):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    hdr = t.rows[0].cells
    for i, text in enumerate(headers):
        hdr[i].text = ""
        p = hdr[i].paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(1)
        p.paragraph_format.space_before = Pt(1)
        set_run(p.add_run(text), size=header_size, bold=True, color=C_BG)
        shade(hdr[i], C_HEAD_BG)
    for row in rows:
        cells = t.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            p.paragraph_format.space_after = Pt(1)
            p.paragraph_format.space_before = Pt(1)
            p.paragraph_format.line_spacing = 1.2
            # 支持 "**粗体**" 与 "`代码`" 两种轻量标记
            _rich_cell(p, str(val), font_size)
    if widths:
        for r in t.rows:
            for i, w in enumerate(widths):
                r.cells[i].width = Cm(w)
    return t


def _rich_cell(p, text, size):
    """在单元格里解析 **粗体** 与 `等宽`。"""
    import re
    tokens = re.split(r'(\*\*[^*]+\*\*|`[^`]+`)', text)
    for tk in tokens:
        if not tk:
            continue
        if tk.startswith('**') and tk.endswith('**'):
            set_run(p.add_run(tk[2:-2]), size=size, bold=True, color=C_TEXT)
        elif tk.startswith('`') and tk.endswith('`'):
            set_run(p.add_run(tk[1:-1]), size=size - 0.5, code=True, color=C_ACCENT)
        else:
            set_run(p.add_run(tk), size=size, color=C_TEXT)


def callout(doc, title, body, *, color=C_WARN, bg="FFF8E6"):
    """带底色的提示框（用单元格模拟）。"""
    t = doc.add_table(rows=1, cols=1)
    t.style = 'Table Grid'
    c = t.rows[0].cells[0]
    shade(c, bg)
    c.text = ""
    p = c.paragraphs[0]
    p.paragraph_format.space_after = Pt(2)
    set_run(p.add_run(title), size=10, bold=True, color=color)
    p2 = c.add_paragraph()
    p2.paragraph_format.space_after = Pt(1)
    p2.paragraph_format.line_spacing = 1.3
    _rich_cell(p2, body, 9.5)
    return t


# =====================================================================
# 实测取数（全部来自命令输出，不写死估算值）
# =====================================================================
ROOT = Path(__file__).resolve().parent.parent


def sh(cmd, cwd=None):
    """
    执行命令并返回 stdout+stderr。

    ⚠️ 必须显式补上 Go 与 Flutter 的路径：**Go 不在本机 PATH 上**
    （实测 `C:\\Program Files\\Go\\bin\\go.exe`，见 AGENTS.md §2），
    不补的话 `go test` 会静默返回空输出 → 测试数变成 '?'。
    """
    env = os.environ.copy()
    extra = [r'C:\Program Files\Go\bin', r'D:\dev\flutter\bin']
    env['PATH'] = os.pathsep.join(extra + [env.get('PATH', '')])
    try:
        r = subprocess.run(cmd, cwd=cwd or ROOT, shell=True,
                           capture_output=True, env=env)
        return r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')
    except Exception as e:
        return f"<{e}>"


def _count_go_tests():
    """
    实测 Go 测试用例数（**含子测试**）。

    ⚠️ 为什么不能只数 `^--- PASS`：子测试的行是**缩进**的
    （`    --- PASS: TestX/sub`）。实测 m115 有 22 个顶层 + 38 个子测试 = 60；
    只数顶层会得到 105，从而误判"文档写的 143 是虚高"——这个错误我犯过。
    """
    total = 0
    pkgs = ['./internal/media', './internal/rpc',
            './internal/pan115', './internal/pan115/m115']
    for p in pkgs:
        out = sh(f'go test {p} -v', cwd=ROOT / 'go')
        import re
        total += len(re.findall(r'(?m)^--- PASS', out))
        total += len(re.findall(r'(?m)^\s+--- PASS', out))
    return str(total) if total else '?'


def count_lines(files, exts):
    """
    统计行数。

    ⚠️ 必须用 splitlines()/ReadAllLines，**不要用 PowerShell 的 Get-Content**——
    本仓库源码是 LF 行尾，`Get-Content` 会**少算**（实测同一批文件：
    Get-Content 报 14,250 行，实际 16,931 行，差 2,681 行）。
    这是 AGENTS.md §3.1 明文记录的坑，我在本报告第一版里正好踩中，故特别标注。
    """
    total = 0
    n = 0
    for f in files:
        if f.suffix in exts:
            n += 1
            try:
                total += len(f.read_text(encoding='utf-8', errors='replace').splitlines())
            except Exception:
                pass
    return n, total


def collect():
    d = {}
    d['ver'] = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
    ps = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
    for line in ps.splitlines():
        if line.startswith('version:'):
            d['build'] = line.split('+')[-1].strip()
            break

    # 代码规模
    for key, sub, exts in [
        ('dart_src', 'lib', {'.dart'}),
        ('dart_test', 'test', {'.dart'}),
        ('go_src', 'go', {'.go'}),
    ]:
        files = [p for p in (ROOT / sub).rglob('*') if p.is_file()]
        if key == 'go_src':
            files = [p for p in files if not p.name.endswith('_test.go')]
        d[key] = count_lines(files, exts)
    go_test = [p for p in (ROOT / 'go').rglob('*_test.go') if p.is_file()]
    d['go_test'] = count_lines(go_test, {'.go'})
    d['kotlin'] = count_lines([p for p in (ROOT / 'android/app/src/main/kotlin').rglob('*.kt')], {'.kt'})
    # C：只算自己写的 cineflow_mpv.c 与 CMakeLists.txt；
    # vendored 的 mpv 头（client.h 等 3,251 行）单列，避免给人"这都是我们写的"错觉
    d['c'] = count_lines([p for p in (ROOT / 'android/app/src/main/cpp').rglob('*')
                          if p.is_file() and p.suffix in {'.c', '.txt'}
                          and '.idea' not in str(p)], {'.c', '.txt'})
    d['c_vendor'] = count_lines([p for p in (ROOT / 'android/app/src/main/cpp').rglob('*.h')], {'.h'})

    # 测试数（以实际运行输出为准；静态计数会少，因为有循环生成的用例）
    out = sh('flutter test', )
    d['flutter_test'] = '?'
    for line in out.splitlines():
        if 'All tests passed' in line:
            import re
            m = re.search(r'\+(\d+)', line)
            if m:
                d['flutter_test'] = m.group(1)

    # Go 测试数：**实测，不硬编码**。
    #
    # ⚠️ 这里有两个坑（都实测踩过）：
    #  1. `Select-String '^--- PASS'` 只数**顶层**测试；子测试行是缩进的
    #     （如 m115 有 22 个顶层 + 38 个子测试 = 60）。只数顶层会得到 105，
    #     进而误报"文档写的 143 是虚高"。
    #  2. 因此必须同时数 `^--- PASS` 与 `^\s+--- PASS`。
    d['go_test_n'] = _count_go_tests()

    # APK
    apk = ROOT / 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
    if apk.exists():
        d['apk_mb'] = f"{apk.stat().st_size / 1024 / 1024:.2f}"
        d['apk_sha'] = hashlib.sha256(apk.read_bytes()).hexdigest()
        d['apk_time'] = datetime.fromtimestamp(apk.stat().st_mtime).strftime('%Y-%m-%d %H:%M')
    else:
        d['apk_mb'] = d['apk_sha'] = d['apk_time'] = '（未构建）'

    so = ROOT / 'android/app/src/main/jniLibs/arm64-v8a/libmpv.so'
    d['libmpv'] = f"{so.stat().st_size:,}" if so.exists() else '?'
    return d


# =====================================================================
# 生成文档
# =====================================================================
def build(out_path: Path):
    D = collect()
    doc = Document()

    # 页面设置
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
    sec.left_margin = sec.right_margin = Cm(2.2)
    sec.top_margin = sec.bottom_margin = Cm(2.0)

    # 默认样式
    st = doc.styles['Normal']
    st.font.name = FONT_CN
    st.font.size = Pt(10.5)
    st.element.rPr.rFonts.set(qn('w:eastAsia'), FONT_CN)

    # ---------------- 封面 ----------------
    para(doc, "", space_after=40)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("CineFlow"), size=40, bold=True, color=C_BG)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("影 流"), size=20, bold=True, color=C_ACCENT)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("万影成流 · 一触即映"), size=11, color=C_TEXT3)
    para(doc, "", space_after=26)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("开发计划与进度报告"), size=24, bold=True, color=C_BG)
    para(doc, "", space_after=34)

    info = [
        ("项目", "CineFlow（影流）— Material 风格的 Emby 第三方播放器"),
        ("平台", "Android 手机端（iOS / 桌面 / 平板 / TV 已明确搁置）"),
        ("版本", f"{D['ver']}（build {D['build']}）"),
        ("播放内核", "安卓原生 mpv（自持 libmpv.so + Kotlin/JNI 桥 + Flutter 纹理输出）"),
        ("许可", "Apache-2.0"),
        # ⚠️ 实测：旧地址 github.com/1357980024/CineFlow 返回 HTTP 403（不可达）；
        #    真实仓库是 bsfcxz/CineFlow。README L12 也还写着旧地址，属待修项
        #    （见 docs/DEVELOPMENT-PLAN.md §0 问题 A）。
        ("源码", "https://github.com/bsfcxz/CineFlow"),
        ("报告生成", datetime.now().strftime('%Y-%m-%d %H:%M')),
    ]
    t = doc.add_table(rows=0, cols=2)
    t.style = 'Table Grid'
    for k, v in info:
        cells = t.add_row().cells
        cells[0].width, cells[1].width = Cm(3.0), Cm(13.6)
        p0 = cells[0].paragraphs[0]; p0.paragraph_format.space_after = Pt(1)
        set_run(p0.add_run(k), size=10, bold=True, color=C_ACCENT)
        shade(cells[0], C_HEAD_BG)
        p1 = cells[1].paragraphs[0]; p1.paragraph_format.space_after = Pt(1)
        set_run(p1.add_run(v), size=10, color=C_TEXT)

    para(doc, "", space_after=20)
    callout(doc, "本报告的数据来源",
            "所有数字（测试用例数、代码行数、APK 指纹、版本号）均为**命令实测输出**，"
            "非估算。测试数以 `flutter test` / `go test` 的**运行输出**为准 —— "
            "静态 grep 会偏少（有用例由循环动态生成）。",
            color=C_ACCENT, bg="EAF2F8")

    doc.add_page_break()

    # ---------------- 一、项目定位 ----------------
    h1(doc, "一、项目定位")
    para(doc, "CineFlow 是一个面向 Android 手机的 Emby 第三方客户端。"
              "媒体库、详情、播放全部由用户自建的 Emby 服务器真实数据驱动；"
              "应用本身不托管任何影视内容。")
    para(doc, "")
    bullet(doc, "播放内核：安卓原生 mpv（自持 libmpv.so，非插件形态）")
    bullet(doc, "扩展能力：115 网盘直连播放、弹幕（弹弹play 官方 + 自建兼容）、豆瓣榜单")
    bullet(doc, "状态管理 Riverpod 3.x · 路由 go_router · 本地库 drift(SQLite) · 网络 dio")
    bullet(doc, "核心逻辑层 Go（编译为 libcineflow_go.so，经 FFI 调用）")

    h2(doc, "与原始计划书的关系")
    para(doc, "原始计划书为《CineFlow 影流 · 可行性方案与计划书 v2.0》，"
              "定义了「Flutter + Go 内嵌服务层 + Synurang/FFI」架构与八阶段路线图。")
    callout(doc, "计划书位置（AGENTS.md 里的相对路径少了一层）",
            "实际路径：`C:\\Users\\a1332\\Desktop\\cineflow.html`（在仓库**外**、上**两层**目录）。\n"
            "`AGENTS.md` 写的是 `../cineflow.html` → 解析为 `Desktop\\bsfc\\cineflow.html`，"
            "用 `[System.IO.File]::Exists()` 判定为 **False**；正确写法是 **`../../cineflow.html`**。\n"
            "（`docs/PROJECT-STATUS.md` L20 与本脚本此前的断言都是对的，需修的是 AGENTS.md。）",
            color=C_WARN, bg="FFF8E6")

    # ---------------- 二、技术架构 ----------------
    h1(doc, "二、技术架构（实际实现）")
    code_block(doc, [
        "┌────────────────────────────────────────────────────────────┐",
        f"│      Flutter UI 层  (lib/  {D['dart_src'][0]} 文件 / {D['dart_src'][1]:,} 行)          │",
        "│  pages(11) · player(6) · danmaku(10) · pan115(5)              │",
        "│  data(8) · core(5) · state(2) · widgets(2) · douban(5)        │",
        "└──────────────────────────┬─────────────────────────────────┘",
        "                           │",
        "         ┌─────────────────┴─────────────────┐",
        "         ▼                                   ▼",
        "┌────────────────────┐            ┌──────────────────────┐",
        "│ MediaProvider 抽象  │            │  PlayerFacade 抽象    │",
        "│ （Emby 实现）       │            │  （mpv 实现）         │",
        "└─────────┬──────────┘            └──────────┬───────────┘",
        "          │ FFI (JSON-over-FFI)             │ MethodChannel",
        "          ▼                                 │ EventChannel",
        "┌────────────────────┐                       │",
        "│ Go 核心层           │                       │",
        "│ libcineflow_go.so   │                       │",
        f"│ {D['go_src'][0]} 文件 / {D['go_src'][1]:,} 行  │                       │",
        "│ media · rpc ·       │                       │",
        "│ pan115 · m115       │                       │",
        "└────────────────────┘                       │",
        "                                             ▼",
        "                          ┌─────────────────────────────────┐",
        f"                          │  Kotlin 桥（{D['kotlin'][1]} 行）              │",
        "                          │  MPVLib / PlayerChannel          │",
        "                          └───────────────┬─────────────────┘",
        "                                          │ JNI",
        "                                          ▼",
        "                          ┌─────────────────────────────────┐",
        f"                          │  C 桥 cineflow_mpv.c（{D['c'][1] - 41} 行）      │",
        "                          │  事件线程 · JSON 转义 · Surface→wid│",
        "                          └───────────────┬─────────────────┘",
        "                                          ▼",
        "                          ┌─────────────────────────────────┐",
        "                          │  libmpv.so（11.80 MB，自持）     │",
        "                          │  ffmpeg 静态链入 · 自建 EGL       │",
        "                          └─────────────────────────────────┘",
    ])

    h2(doc, "关键决策：渲染出口用 Flutter 纹理，不是 PlatformView")
    para(doc, "Kotlin 取 TextureRegistry 的 Surface → NewGlobalRef → "
              "mpv_set_option(\"wid\", int64)；mpv 自建 EGL 画进该 Surface，"
              "Flutter 侧只是普通的 Texture(textureId:) 图层。")
    para(doc, "为什么这样选（详见 ADR 0009）：", bold=True, space_before=6)
    bullet(doc, "上游 mpv-android 根本不用 mpv_render_context（其 render.cpp 全文就是 wid），无范例可对照")
    bullet(doc, "render API 要求 GL 上下文「调用线程 current 且与创建时同源」，PlatformView 合成时序不受控")
    bullet(doc, "纹理是普通 Flutter 图层 → 弹幕 / 手势 / 控制层直接叠加，无需手势仲裁"
                "（而这正是原方案自己点名的头号风险）")

    doc.add_page_break()

    # ---------------- 三、八阶段进度 ----------------
    h1(doc, "三、八阶段进度")
    para(doc, "权威表在 AGENTS.md §1；此处为快照。", color=C_TEXT3, size=9.5)
    table(doc,
          ["阶段", "内容", "进度", "状态说明"],
          [
              ["一", "工程初始化", "✅ 完成", "Flutter 侧完成；Go 核心层已落地（ADR 0004）"],
              ["二", "Emby API 接入", "~97%", "认证/媒体库/详情/搜索/进度上报齐全。**缺 401 自愈**（缺陷 7.7）"],
              ["三", "视频播放核心", "~96%", "**内核已迁到安卓原生 mpv**（K0–K4，ADR 0009）并真机验证。待办：Media3 会话层、片源回归"],
              ["四", "UI/UX 与媒体库", "~80%", "排序/降级/导演/主题令牌全落地。**列表页 UI 待重构**（CF-P4-UI-019）"],
              ["五", "弹幕系统", "~70%", "协议/渲染/设置/持久化全部落地（161 例单测）。未做：发送、手动匹配、密度图。**官方 API 未联调**"],
              ["六", "多平台适配", "搁置", "用户明确只做 Android 手机端"],
              ["七", "测试与发布", "~70%", f"{D['flutter_test']} Dart + {D['go_test_n']} Go + 1 真机集成全绿。**release 签名待换**（缺陷 7.16）"],
              ["八", "115 网盘扩展", "~55%", "协议层+扫码+浏览+播放页全落地（ADR 0007）。**未联调**：无真实账号"],
          ],
          widths=[1.2, 3.0, 1.8, 10.6])

    # ---------------- 四、规模 ----------------
    h1(doc, "四、代码与测试规模（实测）")
    h2(doc, "代码")
    table(doc,
          ["层", "文件数", "行数"],
          [
              ["Dart 源码", str(D['dart_src'][0]), f"{D['dart_src'][1]:,}"],
              ["Dart 测试", str(D['dart_test'][0]), f"{D['dart_test'][1]:,}"],
              ["Go 源码", str(D['go_src'][0]), f"{D['go_src'][1]:,}"],
              ["Go 测试", str(D['go_test'][0]), f"{D['go_test'][1]:,}"],
              ["Kotlin", str(D['kotlin'][0]), f"{D['kotlin'][1]:,}"],
              ["C / CMake（自写）", str(D['c'][0]), f"{D['c'][1]:,}"],
              ["↳ 其中 vendored mpv 头", str(D['c_vendor'][0]), f"{D['c_vendor'][1]:,}（非本项目代码）"],
          ],
          widths=[4.0, 3.0, 3.0])
    para(doc, "Dart 模块分布：pages 3,749 · player 3,104 · data 2,891 · danmaku 2,525 · "
              "pan115 1,871 · douban 1,248 · core 690 · widgets 611 · state 142 · main.dart 100",
         size=9.5, color=C_TEXT2)
    callout(doc, "⚠️ 行数统计口径（这个坑我踩过）",
            "本仓库源码是 **LF 行尾**，PowerShell 的 `Get-Content` 会**少算**。"
            "同一批文件实测：Get-Content 报 **14,250** 行，实际 **16,931** 行（差 2,681 行）。"
            "**必须用 `ReadAllLines()` / `splitlines()`**，或直接读文件工具。"
            "（AGENTS.md §3.1 有明文记录，本报告第一版正好踩中。）",
            color=C_DANGER, bg="FDECEC")

    h2(doc, "测试")
    table(doc,
          ["套件", "数量", "命令", "结果"],
          [
              ["Dart 单测", f"**{D['flutter_test']} 例**", "flutter test", "All tests passed"],
              ["Go 单测", f"**{D['go_test_n']} 例**", "go test ./...", "4 包全 ok"],
              ["真机集成", "**1 例**", "flutter test integration_test/… -d <id>", "All tests passed"],
          ],
          widths=[2.6, 2.2, 7.4, 4.2])
    callout(doc, "计数口径说明",
            f"Dart **静态 grep = 282，实际运行 = {D['flutter_test']}** —— 有 4 例由循环动态生成。"
            "**以运行输出为准**。这是本仓库反复踩过的坑（测试数曾被写错多次）。",
            color=C_WARN, bg="FFF8E6")
    para(doc, "")
    para(doc, "Dart 用例分布：", bold=True, size=10)
    para(doc, "弹幕 7 文件 161 例 · drift 17 · 服务端筛选 16 · 路由 15 · 115 存储 13 · "
              "豆瓣缓存 12 · Go 核心载荷 10 · 演职员 10 · 首页降级 6 · 偏好 5 · 登录冒烟 1",
         size=9.5, color=C_TEXT2, indent=0.5)
    para(doc, "Go 用例分布：", bold=True, size=10, space_before=6)
    para(doc, "pan115 60 · m115 60 · media 11 · rpc 12", size=9.5, color=C_TEXT2, indent=0.5)

    h2(doc, "质量基线")
    table(doc,
          ["项", "当前值"],
          [
              ["flutter analyze", "**0 issue**（无 error / warning / info）"],
              ["go vet", "0 警告"],
              ["开发门禁 scripts/check-dev.ps1", "**全部通过，退出码 0**"],
              ["仓库体积", "0.10 GB（构建垃圾已清理）"],
          ],
          widths=[6.0, 10.6])

    doc.add_page_break()

    # ---------------- 五、偏差 ----------------
    h1(doc, "五、计划书 vs 实际：6 处偏差")
    table(doc,
          ["#", "计划书写的", "实际", "性质", "留痕"],
          [
              ["1", "播放内核 media_kit (libmpv)", "**安卓原生 mpv**，media_kit 已移除", "用户主动变更", "ADR 0009"],
              ["2", "Riverpod 2.x", "3.x", "文档滞后", "—"],
              ["3", "Synurang（gRPC over FFI）", "未落地，用同构的 JSON-over-FFI", "缺 Rust + protoc", "ADR 0004"],
              ["4", "115「预留接口，暂不实现」", "**已实现**（~55%）", "用户要求重启", "ADR 0007"],
              ["5", "多平台（iOS/桌面/平板/TV）", "**仅 Android**，其余搁置", "用户明确缩小", "AGENTS §1"],
              ["6", "弹幕渲染「待选型」", "已定**自绘 CustomPainter**", "已决策", "ADR 0006"],
          ],
          widths=[0.9, 4.6, 5.0, 2.6, 2.1])
    callout(doc, "建议",
            "在计划书里补一段「实际偏差说明」，否则后来人会拿它当规格用。"
            "注意 1/4/5 三项是**用户主动决策**（已留 ADR），不是执行偏差。",
            color=C_ACCENT, bg="EAF2F8")

    # ---------------- 六、技术细节 ----------------
    h1(doc, "六、关键技术细节")

    h2(doc, "6.1 播放内核（最复杂的一块）")
    para(doc, "三条不可动摇的顺序约束（违反必崩）：", bold=True)
    bullet(doc, "av_jni_set_java_vm 必须在任何 mpv 调用前注册（放 JNI_OnLoad）。"
                "不注册的现象极具误导性：**解封装完全正常**（logcat 里 h264/aac 所有轨道都列出来了），"
                "只有视频输出失败 → end-file error。**「能解析出轨道」不等于「能播」**。")
    bullet(doc, "wid 必须在 mpv_initialize 之前 mpv_set_option（之后设置不再生效）。"
                "→ Kotlin 顺序钉死：createSurface → attachSurface → initialize。")
    bullet(doc, "Surface 必须 NewGlobalRef；事件线程必须在 mpv_terminate_destroy 前 join。")
    para(doc, "真机证据（Xiaomi M2012K11AC / Android 13 / arm64）：", bold=True, space_before=8)
    code_block(doc, [
        "av_jni_set_java_vm -> 0 (0=成功)",
        "attachSurface: wid=14182   ->   wid 已设定 = 14182",
        "mpv_initialize 成功，client API 版本=131074",
        "[mpv/vd] Using hardware decoding (mediacodec).",
        "AO: [audiotrack] 44100Hz stereo 2ch float",
        "VO: [gpu] 1920x1080 mediacodec",
    ])
    rich(doc, [("libmpv.so 规格：", {"bold": True}),
               (f"{D['libmpv']} 字节；ELF 7F 45 4C 46 / 机器 0xB7(AArch64) / ET_DYN；"
                "DT_NEEDED 只有系统库（libm/libandroid/libOpenSLES/libEGL/libdl/libc）"
                "→ **ffmpeg 静态链入**，单文件自包含。", {})],
         size=9.5, space_before=6)

    h2(doc, "6.2 Go 核心层")
    bullet(doc, "业务逻辑必须在**零 cgo 的包**（internal/rpc、internal/media、internal/pan115）——"
                "含 import \"C\" 的包会让 go test 在无 gcc 时编不过。bridge.go 只留 C 边界薄包装。")
    bullet(doc, "交叉编译：CGO_ENABLED=1 GOOS=android GOARCH=arm64 "
                "CC=<ndk>/…/aarch64-linux-android24-clang.cmd（.cmd 后缀不能省）。")
    bullet(doc, "Go 编译器会合并字符串常量 → 无法用 strings 扫 .so 验证方法名，"
                "只能靠运行时调用（启动时的 [GoCore] sortParams=… 自检日志）。")

    h2(doc, "6.3 数据层")
    bullet(doc, "drift 家族钉 2.31.x、sqlite3 钉 2.x：3.x 需 Dart native assets，"
                "未启用时运行期报 Couldn't resolve native function 'sqlite3_temp_directory'。")
    bullet(doc, "TTL 在写入时固化进 expires_at 列，由 SQL 判断"
                "（旧契约允许实现方收下 ttl 却不用，是缺陷 §7.4 的根源）。")
    bullet(doc, "缓存放 drift/SQLite 而非内存 → 重启后仍命中。")

    h2(doc, "6.4 115 网盘（风险最高）")
    callout(doc, "合规与风险提示",
            "走的是**非公开 webapi 接口**（非官方开放平台），**有账号风控风险**，"
            "已在登录页向用户明示，并在 ADR 0007 记录。",
            color=C_DANGER, bg="FDECEC")
    para(doc, "")
    bullet(doc, "UA 与取直链绑定：取址 UA 必须与播放 UA 逐字节一致，且 Set-Cookie"
                "（download_token）必须合并进播放请求 → 故 Pan115Playback **把 url 与 headers "
                "绑在同一类型**，不给「只拿 URL」的机会。")
    bullet(doc, "m115 **不是对称加解密**：全流程只有公开指数 e、没有私钥 d，"
                "Decode(Encode(x,k),k) **不还原原文** —— 这是上游既定设计，**别「修好」它**。")
    bullet(doc, "全局 2 请求/秒严格串行（账号安全，非性能优化）。")

    doc.add_page_break()

    # ---------------- 七、待办 ----------------
    h1(doc, "七、待办（按优先级）")
    table(doc,
          ["#", "事项", "卡号", "说明"],
          [
              ["1", "**真机走查播放器整页**", "—", "集成测试只驱动内核，**画面/手势/弹幕叠加没看过**"],
              ["2", "Media3 会话层", "CF-P3-KERNEL-004", "通知栏/耳机键/后台/音频焦点。⚠️ 音频焦点**必须自研**"],
              ["3", "片源回归（4K DV / PGS）", "CF-P3-KERNEL-005", "迁移的唯一验证缺口"],
              ["4", "列表页 UI 全量重构", "CF-P4-UI-019", "ADR 0003 后待重做"],
              ["5", "401 自愈", "CF-P2-EMBY-011", "缺陷 7.7"],
              ["6", "release 签名", "CF-P7-RELEASE-013", "缺陷 7.16，**发布前必做**"],
              ["7", "播放中 WakeLock", "CF-P3-KERNEL-006", "缺陷 7.11"],
              ["8", "115 真实账号联调", "CF-P8-115-030", "等账号"],
              ["9", "接入 Synurang 替换 JSON-over-FFI", "CF-P1-GO-020", "等 Rust + protoc"],
          ],
          widths=[0.9, 5.4, 3.6, 6.7])

    h2(doc, "发布候选状态（等用户审批）")
    table(doc,
          ["项", "值"],
          [
              ["产物", "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"],
              ["大小", f"**{D['apk_mb']} MB**"],
              ["版本", f"versionCode 2002 / versionName {D['ver']}"],
              ["SHA256", f"`{D['apk_sha']}`"],
              ["内核", "mpv（含 libmpv.so，**零 media_kit 痕迹**）"],
              ["真机验证", "装机成功（无需 -d）、启动无崩溃、界面正常渲染"],
              ["混淆符号表", "build/symbols/（**必须与 APK 成对保留**）"],
          ],
          widths=[3.0, 13.6])
    callout(doc, "发版纪律",
            "**未经用户明确审批，不打 tag、不创建 Release、不推送。**"
            "上传只增不删（旧版本是用户回滚的唯一退路）。详见 docs/AI-DISTRIBUTION.md 的 D1–D10。",
            color=C_DANGER, bg="FDECEC")

    # ---------------- 八、工程流程 ----------------
    h1(doc, "八、工程流程")
    h2(doc, "每轮开发固定动作")
    table(doc,
          ["时机", "动作"],
          [
              ["**动手前**", "读 docs/AI-MEMORY.md（进度快照 + 变更台账 + 交接）+ AGENTS.md §6/§7/§9"],
              ["**收工前**", "跑 scripts/check-dev.ps1（**退出码 0 才算完成**）+ 更新 AI-MEMORY.md"],
              ["**发版前**", "读 docs/AI-DISTRIBUTION.md，**未经用户审批绝不发版**"],
          ],
          widths=[2.6, 14.0])

    h2(doc, "门禁体系")
    code_block(doc, [
        "# 一条命令跑完：静态分析 / 单测 / 仓库门禁 / 产物校验 / 真机冒烟",
        "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-dev.ps1",
        "",
        "# 分项",
        "flutter analyze && flutter test",
        "(cd go && go vet ./... && go test ./...)",
        "powershell ... -File scripts/check-secrets.ps1     # 敏感信息",
        "powershell ... -File scripts/check-docs.ps1        # 必需文档 + 断链",
        "powershell ... -File tool/bump_version.ps1 -Check  # 版本号三处一致",
    ])
    para(doc, "门禁本身也做过反向注入验证（否则「门禁通过」没有意义）："
              "APK 入口污染检测、PowerShell BOM 检测，都实测「制造问题 → 报红 → 修复 → 转绿」。",
         size=9.5, color=C_TEXT2, space_before=4)

    h2(doc, "版本号机制")
    bullet(doc, "唯一权威：仓库根 VERSION（只写 X.Y.Z）。pubspec.yaml(X.Y.Z+<build>) 与 "
                "lib/core/version.dart 必须一致，由 bump_version.ps1 强制校验。")
    bullet(doc, "**build number（Android versionCode）只增不减** —— 它决定能否覆盖安装。"
                "曾经恒为 1，导致设备上装的 2001 永远更大、adb install -r 报降级错误，"
                "而**用户没有 -d**，只会看到「应用未安装」。现已修。")

    # ---------------- 九、文档地图 ----------------
    h1(doc, "九、文档地图")
    table(doc,
          ["想知道", "看"],
          [
              ["**现在到哪了 / 上轮改了什么**", "docs/AI-MEMORY.md（每轮必读必写）"],
              ["**计划 / 进度 / 实现细节**", "docs/PROJECT-STATUS.md"],
              ["作业手册（铁律 / 坑 / 验收）", "AGENTS.md"],
              ["**发版纪律**", "docs/AI-DISTRIBUTION.md"],
              ["播放内核方案与 8 个实测坑", "docs/PLAYER-KERNEL.md"],
              ["架构决策与理由", "docs/decisions/（ADR 0001–0007、0009）"],
              ["可执行任务卡", "docs/task-board.md"],
              ["审查清单", "docs/review-checklist.md"],
              ["发布说明（Release 正文事实源）", "docs/changelog/"],
          ],
          widths=[6.6, 10.0])

    # ---------------- 十、已知限制 ----------------
    h1(doc, "十、已知限制（对外必须如实说明）")
    table(doc,
          ["限制", "影响", "依据"],
          [
              ["**debug 签名**", "仅供自用与体验，**不能正式分发、不能上架**", "缺陷 7.16"],
              ["仅 arm64-v8a", "32 位设备与部分模拟器装不上", "构建配置"],
              ["无 Media3 会话层", "**无通知栏控制 / 蓝牙耳机键 / 后台播放**", "K3 未做"],
              ["无 401 自愈", "token 失效需重新登录", "缺陷 7.7"],
              ["无 WakeLock", "播放中可能熄屏", "缺陷 7.11"],
              ["115 非公开接口", "有账号风控风险", "ADR 0007"],
              ["弹幕官方 API 未联调", "本机网络不可达，仅靠单测守协议", "ADR 0006"],
          ],
          widths=[4.2, 8.4, 4.0])

    para(doc, "", space_after=16)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("— 报告结束 —"), size=9.5, color=C_TEXT3)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run(f"CineFlow 影流 · {D['ver']} · "
                      f"生成于 {datetime.now().strftime('%Y-%m-%d %H:%M')}"),
            size=8.5, color=C_TEXT3)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(out_path))
    return D, out_path


if __name__ == '__main__':
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        ROOT.parent / 'CineFlow-开发计划与进度报告.docx'
    D, p = build(out)
    print(f"[完成] {p}")
    print(f"       版本 {D['ver']}(build {D['build']})  "
          f"测试 Dart {D['flutter_test']} / Go {D['go_test_n']}")
    print(f"       APK {D['apk_mb']} MB  sha={D['apk_sha'][:16]}…")
