#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成《CineFlow 开发计划书》Word 文档（前瞻：往哪走 / 先做什么 / 什么卡住了）。

与 `gen_report_docx.py` 的分工：
  · gen_report_docx.py   → 《开发计划与进度报告》：**回顾**（做了什么、怎么实现的）
  · gen_plan_docx.py     → 《开发计划书》：**前瞻**（目的地 / 作业面 / 雾区 / 执行顺序）

方法论来源：`mp-wayfinder`（把大块工作画成决策地图：目的地 · 决策 · 前沿 · 雾区 · 范围外）
          + `mp-to-spec`（把下一步要做的事写成规格模板）

为什么脚本化而不是手写 Word：
  报告里的每个数字（测试数、代码行数、APK 指纹、版本号）都来自**实测**。
  手写会立刻过期且无法核对；脚本化后重跑即可刷新，且数字来源可追溯到具体命令。

用法：
    python tool/gen_plan_docx.py [输出路径]

依赖：python-docx（DSH 运行时自带 1.2.0）
"""

import sys
import os
import subprocess
import hashlib
import re
from datetime import datetime
from pathlib import Path

from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

# ---------- 主题色（与 lib/core/theme.dart 的 Cf 令牌同源）----------
C_BG = "0B1020"
C_ACCENT = "0B7FA8"
C_ACCENT2 = "2E6BFF"
C_TEXT = "1A1A1A"
C_TEXT2 = "4A5568"
C_TEXT3 = "718096"
C_OK = "0F8A4D"
C_WARN = "B7791F"
C_DANGER = "C53030"
C_HEAD_BG = "EAF2F8"
C_CODE_BG = "F5F7FA"
C_STAR_BG = "FFF4E6"    # ★ 高优先项底色

FONT_CN = "微软雅黑"
FONT_CODE = "Consolas"

ROOT = Path(__file__).resolve().parent.parent


# =====================================================================
# 基础排版工具
# =====================================================================
def set_run(run, *, name=FONT_CN, size=10.5, bold=False, italic=False,
            color=None, code=False):
    """中文必须同时设 w:eastAsia，否则 Word 会回退成宋体。"""
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
    rFonts.set(qn('w:eastAsia'), fname)
    return run


def shade(element, fill):
    pr = element._element.get_or_add_tcPr() if hasattr(element._element, 'get_or_add_tcPr') \
        else element._element.get_or_add_pPr()
    sh = OxmlElement('w:shd')
    sh.set(qn('w:val'), 'clear')
    sh.set(qn('w:color'), 'auto')
    sh.set(qn('w:fill'), fill)
    pr.append(sh)


def para(doc, text="", *, size=10.5, bold=False, color=C_TEXT, align=None,
         space_before=0, space_after=4, indent=0, code=False):
    """
    普通段落。

    ⚠️ 走 `_rich()` 解析 `**粗体**` / `` `等宽` `` 标记 —— 否则标记会**字面显示**在
    Word 里（实测踩过：正文里出现一堆 `**文档与事实不符**`，非常难看）。
    """
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
        # ⚠️ 一律走 _rich() 解析 `**粗体**` / `` `等宽` `` 标记——即使 bold=True。
        #    否则标记会**字面显示**在 Word 里（实测踩过：正文出现一堆 `**……**`，很难看）。
        #    bold=True 表示「整段基调加粗」，_rich 里再叠加标记的粗体即可。
        _rich(p, text, size, color, base_bold=bold)
    return p


def h1(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(18)
    p.paragraph_format.space_after = Pt(8)
    set_run(p.add_run(text), size=17, bold=True, color=C_BG)
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
    _rich(p, text, size, color)
    return p


def _rich(p, text, size, base_color=C_TEXT, base_bold=False):
    """
    解析 `**粗体**` 与 `` `等宽` `` 两种轻量标记（**支持嵌套**）。

    这是**唯一**的文本渲染入口——`para` / `bullet` / 表格单元格 / callout 都调它。
    早期版本让部分调用点绕过它，结果标记**字面显示**在 Word 里
    （实测出现 11 处 `**`、6 处反引号），故改为统一入口。

    ⚠️ 嵌套是关键：文本里常见 `**`…`code`…`**` 这种「粗体里包一段代码」的写法。
    只做一层 re.split 会把内层的反引号留在粗体 run 里**字面显示**
    （实测残留 6 处）。故这里递归处理。
    """
    for tk in re.split(r'(\*\*.+?\*\*|`[^`]+`)', text):
        if not tk:
            continue
        if tk.startswith('**') and tk.endswith('**') and len(tk) > 4:
            # 粗体块：递归解析其内部，把嵌套的 `代码` 也拆出来
            _rich(p, tk[2:-2], size, base_color, base_bold=True)
        elif tk.startswith('`') and tk.endswith('`') and len(tk) > 2:
            set_run(p.add_run(tk[1:-1]), size=size - 0.5, code=True, color=C_ACCENT)
        else:
            set_run(p.add_run(tk), size=size, bold=base_bold, color=base_color)


def code_block(doc, lines):
    for i, line in enumerate(lines):
        p = doc.add_paragraph()
        pf = p.paragraph_format
        pf.space_before = Pt(3 if i == 0 else 0)
        pf.space_after = Pt(3 if i == len(lines) - 1 else 0)
        pf.line_spacing = 1.15
        pf.left_indent = Cm(0.4)
        shade(p, C_CODE_BG)
        set_run(p.add_run(line if line else " "), size=8.5, code=True, color="243B53")


def table(doc, headers, rows, *, widths=None, font_size=9.5, header_size=9.5,
          star_rows=()):
    """star_rows: 需要高亮的行下标（用于标 ★ 最高优先项）。"""
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
    for ri, row in enumerate(rows):
        cells = t.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            p.paragraph_format.space_after = Pt(1)
            p.paragraph_format.space_before = Pt(1)
            p.paragraph_format.line_spacing = 1.2
            _rich(p, str(val), font_size)
            if ri in star_rows:
                shade(cells[i], C_STAR_BG)
    if widths:
        for r in t.rows:
            for i, w in enumerate(widths):
                r.cells[i].width = Cm(w)
    return t


def callout(doc, title, body, *, color=C_WARN, bg="FFF8E6"):
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
    _rich(p2, body, 9.5)
    return t


# =====================================================================
# 实测取数（不写死估算值）
# =====================================================================
def sh(cmd, cwd=None):
    """执行命令。必须补 PATH：Go 不在本机 PATH 上（实测）。"""
    env = os.environ.copy()
    extra = [r'C:\Program Files\Go\bin', r'D:\dev\flutter\bin']
    env['PATH'] = os.pathsep.join(extra + [env.get('PATH', '')])
    try:
        r = subprocess.run(cmd, cwd=cwd or ROOT, shell=True,
                           capture_output=True, env=env)
        return r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')
    except Exception as e:
        return f"<{e}>"


def count_lines(files, exts):
    """
    统计行数。

    ⚠️ 必须用 splitlines()，**不要用 PowerShell 的 Get-Content**——
    本仓库源码是 LF 行尾，`Get-Content` 会**少算**（实测同一批文件：
    报 14,250 行而实际 16,931 行）。这是 AGENTS.md §3.1 记录的坑。
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


def count_go_tests():
    """
    实测 Go 用例数（**含子测试**）。

    ⚠️ 只数 `^--- PASS` 会漏掉缩进的子测试行（m115: 22 顶层 + 38 子 = 60）。
    只数顶层得 105，会误判"文档写的 143 是虚高"——这个错误我犯过。
    """
    total = 0
    for p in ['./internal/media', './internal/rpc',
              './internal/pan115', './internal/pan115/m115']:
        out = sh(f'go test {p} -v', cwd=ROOT / 'go')
        total += len(re.findall(r'(?m)^--- PASS', out))
        total += len(re.findall(r'(?m)^\s+--- PASS', out))
    return str(total) if total else '?'


def collect():
    d = {}
    d['ver'] = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
    ps = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
    for line in ps.splitlines():
        if line.startswith('version:'):
            d['build'] = line.split('+')[-1].strip()
            break

    for key, sub, exts in [('dart_src', 'lib', {'.dart'}),
                           ('dart_test', 'test', {'.dart'}),
                           ('go_src', 'go', {'.go'})]:
        files = [p for p in (ROOT / sub).rglob('*') if p.is_file()]
        if key == 'go_src':
            files = [p for p in files if not p.name.endswith('_test.go')]
        d[key] = count_lines(files, exts)
    d['go_test'] = count_lines(
        [p for p in (ROOT / 'go').rglob('*_test.go') if p.is_file()], {'.go'})
    d['kotlin'] = count_lines(
        [p for p in (ROOT / 'android/app/src/main/kotlin').rglob('*.kt')], {'.kt'})
    d['c'] = count_lines(
        [p for p in (ROOT / 'android/app/src/main/cpp').rglob('*')
         if p.is_file() and p.suffix in {'.c', '.txt'} and '.idea' not in str(p)],
        {'.c', '.txt'})

    out = sh('flutter test')
    d['flutter_test'] = '?'
    for line in out.splitlines():
        if 'All tests passed' in line:
            m = re.search(r'\+(\d+)', line)
            if m:
                d['flutter_test'] = m.group(1)

    d['go_test_n'] = count_go_tests()

    # APK 指纹
    apk = ROOT / 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
    if apk.exists():
        d['apk_mb'] = f"{apk.stat().st_size / 1024 / 1024:.2f}"
        d['apk_sha'] = hashlib.sha256(apk.read_bytes()).hexdigest()
    else:
        d['apk_mb'] = d['apk_sha'] = '（未构建）'

    # 符号表（必须与 APK 成对）
    syms = ROOT / 'build/symbols'
    d['symbols'] = len(list(syms.glob('*'))) if syms.exists() else 0

    # git 未提交项
    st = sh('git status --porcelain')
    lines_st = [x for x in st.splitlines() if x.strip()]
    d['uncommitted'] = len(lines_st)
    d['untracked'] = len([x for x in lines_st if x.startswith('??')])
    d['commits'] = sh('git rev-list --count HEAD').strip()

    # GitHub Release 状态（实测）
    d['releases'] = '?'
    return d


def probe_github():
    """实测 GitHub 的 Release / tag 状态（文档曾标注为「未知」）。"""
    info = {'releases': '?', 'tags': '?', 'url_ok': '?'}
    try:
        import urllib.request, json
        req = urllib.request.Request(
            'https://api.github.com/repos/bsfcxz/CineFlow/releases',
            headers={'User-Agent': 'cineflow-plan'})
        with urllib.request.urlopen(req, timeout=20) as r:
            info['releases'] = str(len(json.loads(r.read().decode('utf-8'))))
        req2 = urllib.request.Request(
            'https://api.github.com/repos/bsfcxz/CineFlow/tags',
            headers={'User-Agent': 'cineflow-plan'})
        with urllib.request.urlopen(req2, timeout=20) as r:
            tags = json.loads(r.read().decode('utf-8'))
            info['tags'] = ', '.join(t['name'] for t in tags) if tags else '（无）'
    except Exception as e:
        info['releases'] = f'<{e}>'
    return info


# =====================================================================
# 生成文档
# =====================================================================
def build(out_path: Path):
    D = collect()
    GH = probe_github()
    doc = Document()

    sec = doc.sections[0]
    sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
    sec.left_margin = sec.right_margin = Cm(2.2)
    sec.top_margin = sec.bottom_margin = Cm(2.0)

    st = doc.styles['Normal']
    st.font.name = FONT_CN
    st.font.size = Pt(10.5)
    st.element.rPr.rFonts.set(qn('w:eastAsia'), FONT_CN)

    # ---------------- 封面 ----------------
    para(doc, "", space_after=36)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("CineFlow"), size=40, bold=True, color=C_BG)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("影 流"), size=20, bold=True, color=C_ACCENT)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("万影成流 · 一触即映"), size=11, color=C_TEXT3)
    para(doc, "", space_after=24)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("开 发 计 划 书"), size=26, bold=True, color=C_BG)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("往哪走 · 先做什么 · 什么卡住了"), size=11, color=C_TEXT2)
    para(doc, "", space_after=28)

    info = [
        ("项目", "CineFlow（影流）— Material 风格的 Emby 第三方播放器"),
        ("平台", "Android 手机端（iOS / 桌面 / 平板 / TV 已明确搁置）"),
        ("基线版本", f"{D['ver']}（build {D['build']}）"),
        ("播放内核", "安卓原生 mpv（自持 libmpv.so + Kotlin/JNI 桥 + Flutter 纹理输出）"),
        ("源码", "https://github.com/bsfcxz/CineFlow"),
        ("当前进度", "约 70%（距「可正式分发」的终点）"),
        ("生成时间", datetime.now().strftime('%Y-%m-%d %H:%M')),
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

    para(doc, "", space_after=18)
    callout(doc, "本计划书怎么用",
            "它回答**前瞻**问题：**接下来往哪走、先做什么、什么卡住了**。"
            "分工：`PROJECT-STATUS.md` 看**回顾**（做了什么）、`AI-MEMORY.md` 看**台账**"
            "（上轮谁改了什么，每轮必读写）、`task-board.md` 看**任务卡**（派工）。\n"
            "**所有数字均为命令实测输出**，非估算。",
            color=C_ACCENT, bg="EAF2F8")

    doc.add_page_break()

    # ---------------- 零、核查发现 ----------------
    h1(doc, "零、先说三个核查发现（建议先修）")
    para(doc, "在做计划前先核对现状，发现三处**文档与事实不符**。"
              "它们不阻塞开发，但会误导后来者，其中一条影响对外可信度。",
         size=10)
    para(doc, "")
    table(doc,
          ["#", "问题", "实测证据", "影响"],
          [
              ["A", "**README 指向死链**",
               "`README.md:12` 写 `github.com/1357980024/CineFlow`，"
               "实测 **HTTP 403**；真实仓库是 `bsfcxz/CineFlow`",
               "用户点「Releases」会 404"],
              ["B", f"**GitHub 上 {GH['releases']} 个 Release，但 tag 存在**",
               f"API 实测：releases = **{GH['releases']}**；tags = **{GH['tags']}**",
               "证实 `release.yml` 此前语法错误**从未成功运行**——"
               "v0.2.0 只打了 tag、**没有产物**。而 README 宣称「见 Releases 页面」"],
              ["C", "**`AGENTS.md` 的计划书相对路径少一层**",
               "计划书在 `Desktop\\cineflow.html`；`AGENTS.md` 写 `../cineflow.html` "
               "→ 解析为 `Desktop\\bsfc\\cineflow.html` → `File.Exists` = **False**。"
               "正确写法是 **`../../cineflow.html`**",
               "按 AGENTS 的路径找不到计划书"],
          ],
          widths=[0.8, 4.4, 7.6, 3.8])

    callout(doc, "⚠️ 本核查中我自己出过一次错并被实测纠正",
            "判断「计划书路径谁对谁错」时，我一度写成「AGENTS 是对的、PROJECT-STATUS 是错的」"
            "——那是被 `Test-Path` 对含 `..` 路径的行为误导（先 `Join-Path` 得到未规范化的串）。"
            "改用 `[System.IO.Path]::GetFullPath()` 规范化 + `[System.IO.File]::Exists()` 后"
            "结论**反转**：AGENTS 少了一层 `..`。\n"
            "**教训**：路径判定必须规范化后再判，不要直接 `Test-Path` 含 `..` 的串。",
            color=C_DANGER, bg="FDECEC")

    doc.add_page_break()

    # ---------------- 一、目的地 ----------------
    h1(doc, "一、目的地（Destination）")
    para(doc, "wayfinder 的第一个动作是**命名终点**。终点决定范围，所有任务都朝它收敛。",
         size=9.5, color=C_TEXT3)
    para(doc, "")
    para(doc, "到达终点 = 一个可以正式分发的 v1.0：", bold=True, size=11.5)
    bullet(doc, "**能装**：release 签名（非 debug），可覆盖安装，任意 arm64 手机可装")
    bullet(doc, "**能播**：播放器整页 UI 经**人眼真机走查**（画面出图 / 手势 / 弹幕叠加），"
                "且有后台播放与通知栏控制")
    bullet(doc, "**能发布**：GitHub Releases 上有带校验和的正式产物，README 与事实一致")
    bullet(doc, "**能维护**：核心改动有单测与门禁守着，新人（或新 AI 会话）读三份文档即可接手")
    para(doc, "")
    callout(doc, "当前距离终点：约 70%",
            "缺口集中在「**可分发**」与「**已视觉验证**」两件事上，**不是功能数量**——"
            "功能面其实已超出「能发布」所需（115、弹幕都是超前完成的）。",
            color=C_ACCENT, bg="EAF2F8")

    # ---------------- 二、已定决策 ----------------
    h1(doc, "二、已定的决策（不要再重新讨论）")
    para(doc, "以下决策均已留痕（ADR 或 AGENTS 条款），直接引用即可。", size=9.5, color=C_TEXT3)
    para(doc, "")
    table(doc,
          ["决策", "结论", "出处"],
          [
              ["播放内核", "**安卓原生 mpv**（自持 libmpv.so + Kotlin/JNI + **Flutter 纹理**输出），已弃用 media_kit", "ADR 0009"],
              ["渲染出口", "**Flutter 纹理**而非 PlatformView —— 消除手势仲裁问题", "ADR 0009"],
              ["平台范围", "**仅 Android 手机端**，其余明确搁置", "AGENTS §1"],
              ["媒体抽象", "`MediaProvider` 中立化，边界类型 `Media*`", "ADR 0002 / §7.19"],
              ["本地存储", "**drift/SQLite**（TTL 在写入时固化）", "ADR 0005"],
              ["路由", "**go_router**", "ADR 0005"],
              ["Go 层桥接", "**JSON-over-FFI**（Synurang 未落地，替换时 Dart 契约不变）", "ADR 0004"],
              ["弹幕源", "官方直连 + 自建兼容**双形态**（认证方式不同，不统一）", "ADR 0006"],
              ["弹幕渲染", "**自绘 CustomPainter**（不用 canvas_danmaku，只借鉴算法）", "ADR 0006"],
              ["115 路线", "**webapi（cookie）**，非官方开放平台；**有风控风险**，登录页已明示", "ADR 0007"],
              ["媒体库 Tab", "**已移除**（只保留 首页/排行榜/我的）", "ADR 0003"],
              ["发布纪律", "**未经用户审批绝不发版**；只增不删", "AI-DISTRIBUTION D1–D10"],
              ["自身许可", "**Apache-2.0**", "CF-P1-OSS-008"],
          ],
          widths=[2.6, 11.6, 2.4])

    doc.add_page_break()

    # ---------------- 三、进度核查 ----------------
    h1(doc, "三、进度核查（实测）")
    h2(doc, "3.1 八阶段")
    table(doc,
          ["阶段", "内容", "进度", "缺口（这是关键）"],
          [
              ["一", "工程初始化", "**✅ 完成**", "—"],
              ["二", "Emby API", "**~97%**", "**401 自愈**（缺陷 7.7）"],
              ["三", "播放核心", "**~96%**", "**K3 会话层**（通知栏/后台/耳机键/音频焦点）+ **片源回归**"],
              ["四", "UI/UX", "**~80%**", "**列表页重构**（ADR 0003 后待重做）"],
              ["五", "弹幕", "**~70%**", "发送 / 手动匹配 / 密度图；**官方 API 未联调**"],
              ["六", "多平台", "搁置", "用户明确缩小范围"],
              ["七", "测试与发布", "**~70%**", "**release 签名**（缺陷 7.16，**发布前必做**）"],
              ["八", "115 网盘", "**~55%**", "**真实账号联调**（无账号）"],
          ],
          widths=[1.2, 3.0, 1.9, 10.5])

    h2(doc, "3.2 实测数字")
    table(doc,
          ["项", "实测值", "命令"],
          [
              ["Dart 单测", f"**{D['flutter_test']} 例全绿**", "`flutter test`"],
              ["Go 单测", f"**{D['go_test_n']} 例全绿**（含子测试）", "`go test ./...`"],
              ["真机集成", "**1 例通过**", "`flutter test integration_test/… -d <id>`"],
              ["flutter analyze", "**0 error / 0 warning**", "`flutter analyze`"],
              ["Go 源码", f"{D['go_src'][0]} 文件 / {D['go_src'][1]:,} 行", "—"],
              ["Dart 源码", f"{D['dart_src'][0]} 文件 / {D['dart_src'][1]:,} 行", "—"],
              ["版本", f"{D['ver']}（build {D['build']}）", "`VERSION` = pubspec = version.dart"],
              ["未提交改动", f"**{D['uncommitted']} 项**（其中未跟踪 {D['untracked']} 项）", "`git status --porcelain`"],
              ["Git 提交数", f"{D['commits']} 次", "`git rev-list --count HEAD`"],
          ],
          widths=[3.4, 7.4, 5.8])

    callout(doc, "⚠️ Go 测试计数的坑（本次亲手踩到）",
            "`Select-String '^--- PASS'` 只数**顶层**测试；子测试行是**缩进**的"
            "（m115 有 22 个顶层 + 38 个子测试 = 60）。只数顶层得 **105**，"
            "会得出「文档写的 143 是虚高」的**错误结论**。\n"
            "**正确算法要连缩进的 `--- PASS` 一起数**（或读 `go test -json` 的 Test 维度 pass 事件）。",
            color=C_WARN, bg="FFF8E6")

    h2(doc, "3.3 发布候选（已就绪，等审批）")
    table(doc,
          ["项", "值"],
          [
              ["产物", "`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`"],
              ["大小 / 版本", f"**{D['apk_mb']} MB** / versionCode **2002** / versionName {D['ver']}"],
              ["SHA256", f"`{D['apk_sha'][:32]}…`" if D['apk_sha'] != '（未构建）' else "（未构建）"],
              ["内核", "mpv（含 libmpv.so，**零 media_kit 痕迹**）"],
              ["混淆符号表", f"`build/symbols/` **{D['symbols']} 个文件** —— 与 APK **成对**，勿删"],
              ["GitHub Release", f"**{GH['releases']} 个**（tag：{GH['tags']}）→ **尚未发布**"],
          ],
          widths=[3.4, 13.2])
    callout(doc, "发版纪律（D1–D10）",
            "**未经用户明确审批，不打 tag、不创建/修改/删除任何 Release。**"
            "上传**只增不删**——旧版本是用户回滚的唯一退路。",
            color=C_DANGER, bg="FDECEC")

    doc.add_page_break()

    # ---------------- 四、作业面 ----------------
    h1(doc, "四、作业面（地图）")
    para(doc, "能说清的问题就立卡（即使被阻塞）；说不清的进第五节「雾区」；越界的进第六节「范围外」。",
         size=9.5, color=C_TEXT3)

    h2(doc, "4.1 ★ 前沿（立即可做，无阻塞）")
    table(doc,
          ["序", "任务", "卡号", "为什么现在做", "完成判据"],
          [
              ["1", "**提交未提交改动**", "—",
               f"**最高优先**。{D['uncommitted']} 项改动（含整个内核迁移与 "
               f"{D['apk_mb']}MB 产物链路）**只在工作区，没有回滚点**",
               "`check-dev.ps1` 退出码 0 → commit"],
              ["2", "**真机走查播放器整页**", "—",
               "集成测试**只驱动内核**（仅 1 例 testWidgets），**画面/手势/弹幕叠加从没人看过**",
               "真机点进播放器，截图 + logcat 证据"],
              ["3", "**修 README 地址与发布描述**", "CF-P4-DOCS-012",
               "指向 403 死链；且宣称「见 Releases」而 Releases 为空",
               "链接可达 + 描述与实测一致"],
              ["4", "**release 签名**", "CF-P7-RELEASE-013",
               "**发布前必做**（缺陷 7.16）；当前 debug 签名**不能正式分发**",
               "`key.properties` 就位，产物用正式签名"],
              ["5", "**401 自愈**", "CF-P2-EMBY-011",
               "缺陷 7.7；token 失效现在只能看错误页",
               "拦截器识别 401 → 清会话 → 回登录页 + 单测"],
              ["6", "**WakeLock**", "CF-P3-KERNEL-006",
               "缺陷 7.11，播放中可能熄屏（体验硬伤）",
               "播放中屏幕常亮，真机验证"],
          ],
          widths=[0.8, 3.4, 2.9, 5.6, 3.9], star_rows=(0, 1))

    h2(doc, "4.2 需前置（阻塞中）")
    table(doc,
          ["任务", "卡号", "被什么阻塞", "解阻条件"],
          [
              ["**K3 Media3 会话层**", "CF-P3-KERNEL-004",
               "无技术阻塞，但**依赖播放器 UI 走查先确认现状**", "先做 4.1-2"],
              ["**片源回归**（4K DV / PGS / 多音轨）", "CF-P3-KERNEL-005",
               "需要**片源样本**", "用户提供或自备样本"],
              ["**列表页 UI 重构**", "CF-P4-UI-019",
               "需要**信息架构决策**（ADR 0008 待写）", "先定信息架构"],
              ["**115 真实联调**", "CF-P8-115-030",
               "**无真实 115 账号**", "用户提供账号（注意风控风险）"],
              ["**115 会话失效引导**", "CF-P8-115-034", "依赖联调结论", "联调后"],
              ["**接入 Synurang**", "CF-P1-GO-020",
               "本机**无 Rust + protoc**", "装工具链"],
              ["**Play 商店素材**", "—", "需 512×512 图标 + Feature Graphic", "设计资源"],
          ],
          widths=[4.6, 3.4, 5.4, 3.2])

    h2(doc, "4.3 可并行")
    bullet(doc, "4.1 的 **3（文档）、4（签名）、5（401）、6（WakeLock）彼此无依赖**，可并行推进")
    bullet(doc, "4.1 的 **2（播放器走查）是 4.2 多项的前置**，应最先做")

    doc.add_page_break()

    # ---------------- 五、雾区 ----------------
    h1(doc, "五、雾区（Not yet specified）")
    para(doc, "**能看出要来、但还说不清**的问题。它们**都在范围内**，只是还不够锐利到能立卡。"
              "随前沿推进，会逐块「毕业」成正式任务卡。", size=9.5, color=C_TEXT3)
    para(doc, "")
    table(doc,
          ["雾区", "为什么还说不清", "等什么才能看清"],
          [
              ["**列表页的信息架构**",
               "ADR 0003 删掉了媒体库页，但「用什么替代」没有决策。"
               "是「首页内嵌分区」还是「搜索页强化筛选」还是别的？取决于真实浏览习惯",
               "4.1-2 的走查反馈 + 用户偏好"],
              ["**音频焦点与后台播放的具体行为**",
               "需要自研（Media3 的焦点实现在 ExoPlayer 里，session 层不做）。"
               "但「暂停后恢复策略」「多应用抢占时的提示」细节未定",
               "K3 落地时的实测"],
              ["**发布节奏**",
               "v0.3.0 之后是 0.3.x 修补还是直接奔 0.4？取决于首次发布后的用户反馈"
               "（目前 **0★、0 Release**，还没有真实用户）",
               "首次发布后的反馈"],
              ["**libmpv.so 的合规收尾**",
               "已确定是 **LGPL-3.0**（`--disable-gpl` + `--enable-version3`），"
               "且**最可能**来自 `media-kit/libmpv-android-video-build`，"
               "但 GitHub 上有 9 个同名仓库，**未 100% 锁定**",
               "向候选仓库确认，或直接按 LGPL-3.0 履行义务"],
              ["**弹幕官方 API 联调**",
               "本机网络不可达（`api.dandanplay.net` HTTPS 返回 000），只靠单测守协议",
               "换网络环境或有自建服务"],
              ["**models.dart 的 Emby 线格式抽取**",
               "缺陷 §7.20。要不要抽成独立适配器，取决于是否有第二个走 `MediaProvider` 的源"
               "——目前 115 走独立页面，所以不急",
               "再接入一个源时"],
          ],
          widths=[3.8, 8.6, 4.2])

    # ---------------- 六、范围外 ----------------
    h1(doc, "六、范围外（Out of scope）")
    para(doc, "**有意排除**，不属于本次终点。不会「毕业」，除非重画终点。",
         size=9.5, color=C_TEXT3)
    para(doc, "")
    table(doc,
          ["排除项", "为什么"],
          [
              ["iOS / 桌面 / 平板 / TV", "用户明确「只做手机端」（计划书阶段六搁置）"],
              ["转码播放", "实测本服务器（Emby 4.10.0.40 免费版）**不具备转码能力**"
                          "（`SupportsTranscoding=false`）。待服务器具备能力后再评估"],
              ["自建弹幕渲染引擎", "已用自绘 CustomPainter（ADR 0006）；不引入 canvas_danmaku 作为依赖"],
              ["官方开放平台 115 路线", "需申请 AppId，用户已选 webapi 路线（ADR 0007）"],
              ["上架应用商店", "需 512×512 素材 + 正式签名 + 隐私政策，超出本次终点"],
          ],
          widths=[4.6, 12.0])

    doc.add_page_break()

    # ---------------- 七、下一步规格 ----------------
    h1(doc, "七、下一步规格（按 to-spec 模板）")
    para(doc, "把排序第 2 的**播放器整页走查**写成规格 —— 它是 4.2 多项的前置，值得写清楚。",
         size=9.5, color=C_TEXT3)

    h2(doc, "7.1 问题（用户视角）")
    para(doc, "内核迁移完成后，**没有任何人真正看过播放器页面的实际表现**。"
              "集成测试只验证了「Dart → MethodChannel → Kotlin → JNI → libmpv」这条链路能起播，"
              "但**用户看到的是播放器整页**：控制层能不能正常显隐、手势滑动会不会误触发、"
              "弹幕层有没有盖住字幕、退出后应用会不会崩。这些都是**只有人眼能判断**的。")
    para(doc, "风险在于：内核测试全绿会给人「播放已经好了」的错觉，"
              "而实际上 **UI 层可能整个是坏的**（比如视频层尺寸为 0、控制层遮挡全屏）。",
         bold=True, color=C_DANGER)

    h2(doc, "7.2 解法（用户视角）")
    para(doc, "在真机上完整走一遍播放流程，**用截图与日志留证**，"
              "把发现的问题立卡，而不是「看起来还行」就过。")

    h2(doc, "7.3 用户故事")
    stories = [
        "作为用户，我想点进任意影片就能看到画面，以便确认播放是通的",
        "作为用户，我想轻点屏幕能唤出/隐藏控制层，以便不被打扰地看片",
        "作为用户，我想看到进度条能拖动且立即响应，以便跳到想看的片段",
        "作为用户，我想横向滑动调亮度、纵向滑动调音量，以便躺着也能操作",
        "作为用户，我想看到弹幕浮在画面上且不吃掉我的手势，以便边看边发弹幕",
        "作为用户，我想看到字幕不被弹幕完全遮挡，以便看清对话",
        "作为用户，我想切音轨/字幕/倍速后立即生效，以便适配不同片源",
        "作为用户，我想退出播放后应用不崩溃，以便继续浏览",
        "作为用户，我想退出播放后服务器会话清零，以便下次从头播",
        "作为用户，我想旋转屏幕时布局正确适配，以便横竖屏都可用",
    ]
    for i, s in enumerate(stories, 1):
        bullet(doc, s, marker=f"{i}.", size=10)

    h2(doc, "7.4 实现决策")
    bullet(doc, "**不改代码，先走查**：这一轮的产出是**问题清单 + 截图证据**，不是补丁")
    bullet(doc, "**走查路径**（AGENTS §8.2）：登录 → 首页 → 详情 → 播放 → 返回 → `pidof` 存活")
    bullet(doc, "**留证要求**：每个用户故事至少一张截图或一行 logcat")
    bullet(doc, "**坐标陷阱**：横屏 `input tap` 走竖屏坐标系（`lx = W - py, ly = px`），"
                "且横屏下 uiautomator 语义大量失效（实测 31 节点仅 9 个有有效 bounds）"
                "→ **横屏优先用 `debugDumpApp` 确认控件存在，点击回竖屏做**")
    bullet(doc, "**崩溃判据**：必须用 `adb shell pidof com.cineflow.app`，"
                "**不能凭 `Lost connection to device` 下结论**（那只表示调试连接断了）")

    h2(doc, "7.5 测试决策")
    bullet(doc, "**这一轮不写新单测**（走查本身不是可自动化的行为）")
    bullet(doc, "但若发现缺口，**把可逻辑化的部分提为 `public static` 补测试**"
                "（先例：`PlayerPage.parseDefaultRate`、`LibraryPage.sortDirectionFor`）")
    bullet(doc, "**回归线**：走查后必须重跑 `integration_test/player_kernel_test.dart`，"
                "确认没有回归（它是唯一能碰到 JNI 的测试）")

    callout(doc, "⚠️ 走查前必须先重建 APK",
            "`flutter test integration_test/...` 会**污染 `app-debug.apk` 的入口**"
            "（Dart VM 正常起来但白屏，logcat 无 `[GoCore]`/`[DB]`）。"
            "`check-dev.ps1` 有自动检出（已反向注入验证）。",
            color=C_DANGER, bg="FDECEC")

    doc.add_page_break()

    # ---------------- 八、执行顺序 ----------------
    h1(doc, "八、执行顺序建议")
    para(doc, "依据：**风险优先 + 前置依赖**。不是按「功能多少」排。", size=9.5, color=C_TEXT3)
    para(doc, "")
    code_block(doc, [
        "第 1 步  提交未提交改动              <- 先有回滚点，再动别的",
        "          |",
        "第 2 步  真机走查播放器整页           <- 是 K3 与列表页重构的前置",
        "          |",
        "第 3 步  +-- 修 README 地址/描述       <- 三项无依赖，可并行",
        "         +-- release 签名（发布前必做）",
        "         +-- WakeLock（体验硬伤）",
        "          |",
        "第 4 步  401 自愈                     <- 独立，可与第 3 步并行",
        "          |",
        "第 5 步  K3 Media3 会话层             <- 依赖第 2 步的结论",
        "          |",
        "第 6 步  列表页 UI 重构                <- 依赖信息架构决策（雾区）",
        "          |",
        "第 7 步  审批并发布 v0.3.0             <- 需用户明确批准（D1）",
    ])
    para(doc, "")
    callout(doc, "为什么「提交」排第一",
            f"当前 **{D['uncommitted']} 项改动**（含整个播放内核迁移、记忆库、门禁脚本、关于页）"
            f"**全部只在工作区**，而 git 里只有 **{D['commits']} 次提交**。"
            "一次误操作就没了，且**没有历史可回滚**。记忆库自己也把这条列为待办 #4。",
            color=C_DANGER, bg="FDECEC")

    # ---------------- 九、维护约定 ----------------
    h1(doc, "九、维护约定")
    h2(doc, "本文件何时更新")
    table(doc,
          ["时机", "动作"],
          [
              ["**雾区有块「毕业」**", "从第五节移到第四节，并建任务卡"],
              ["**决策落定**", "写进第二节（附 ADR 链接），从雾区删除"],
              ["**终点变化**", "重画第一节，并重新审视第六节的范围外清单"],
              ["**每轮收工**", "只需更新 `AI-MEMORY.md`；本文件**按季度或阶段完成时**刷新"],
          ],
          widths=[4.2, 12.4])

    h2(doc, "与其他文档的一致性")
    bullet(doc, "第二节的每条决策**必须有 ADR 或 AGENTS 条款背书**，不得只写结论")
    bullet(doc, "第三节的数字**必须来自命令输出**，不得复制上一版（本仓库已多次因此写错）")
    bullet(doc, "第四节的任务卡**必须与 `task-board.md` 双向对应**（卡号一致）")
    bullet(doc, "冲突时优先级：**用户当轮指令 > AGENTS.md > AI-MEMORY.md > 本文件**")

    # ---------------- 附录 ----------------
    h1(doc, "附录：核查方法与局限")
    h2(doc, "做了的")
    bullet(doc, "用 GitHub API 实测 releases / tags / 仓库可达性（**发现 A、B**）")
    bullet(doc, "用 `[System.IO.File]::Exists()` + `GetFullPath()` 实测计划书路径（**发现 C**）")
    bullet(doc, "用 `flutter test`、`go test -v`、`splitlines()` 实测测试数与代码行数")
    bullet(doc, f"用 `git status --porcelain` 实测未提交状态（**{D['uncommitted']} 项**）")

    h2(doc, "没做的（诚实标注）")
    bullet(doc, "**没有真机走查播放器** —— 本计划书把这件事列为下一步，而不是声称已完成",
           color=C_DANGER)
    bullet(doc, "**没有验证 `libmpv.so` 的确切来源仓库**（9 个同名仓库未逐个比对）")
    bullet(doc, "**没有联调 115**（无账号）")
    bullet(doc, "**没有跑 `check-dev.ps1` 全量**（含真机冒烟，耗时数分钟）；"
                "本次只做了 `flutter analyze` / `flutter test` / `go test` 三项硬门禁")

    para(doc, "", space_after=16)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run("— 计划书结束 —"), size=9.5, color=C_TEXT3)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run(f"CineFlow 影流 · {D['ver']} · "
                      f"生成于 {datetime.now().strftime('%Y-%m-%d %H:%M')}"),
            size=8.5, color=C_TEXT3)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(out_path))
    return D, out_path


if __name__ == '__main__':
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        ROOT.parent / 'CineFlow-开发计划书.docx'
    D, p = build(out)
    print(f"[完成] {p}")
    print(f"       版本 {D['ver']}(build {D['build']})  "
          f"测试 Dart {D['flutter_test']} / Go {D['go_test_n']}")
    print(f"       未提交 {D['uncommitted']} 项 · 提交 {D['commits']} 次")
    print(f"       APK {D['apk_mb']} MB · 符号表 {D['symbols']} 个")
