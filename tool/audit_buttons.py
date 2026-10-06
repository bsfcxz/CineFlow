#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按键可用性静态审查。

## 为什么做静态审查而不是只靠点击
真机点击每条路径成本高（需 dump 坐标、等加载、判页面），
且 uiautomator 对 Flutter 语义树时灵时不灵。
**先静态找出所有可疑点，再针对可疑点做真机点击** —— 这才是有效率的顺序。

## 检查项
1. **空实现**：onTap/onPressed 是空函数体（点了没反应）
2. **永久 null**：onTap/onPressed 恒为 null（死按钮）
3. **占位未实现**：showComingSoon（功能未做，需确认是否该做）
4. **命中区过小**：GestureDetector/InkWell 包 Icon 但无尺寸约束
5. **无按压反馈**：用 GestureDetector 而非 InkWell/IconButton 包裹的可点区域
6. **异步 fire-and-forget**：onTap 里 await 了但没 catch（失败静默）
"""
import re
import sys
from pathlib import Path

ROOT = Path(r'C:\Users\a1332\Desktop\bsfc\cineflow\lib')
out = []


def collect():
    return sorted(p for p in ROOT.rglob('*.dart'))


def scan_empty_handlers(files):
    """onTap/onPressed = 空实现"""
    out.append('## 1. 空实现（点了没反应）')
    found = False
    pat = re.compile(r'(onTap|onPressed|onChanged):\s*\(\s*[\w, ]*\s*\)\s*\{\s*\}')
    for f in files:
        for i, line in enumerate(f.read_text(encoding='utf-8').split('\n'), 1):
            if pat.search(line):
                out.append('   %s:%d  %s' % (f.name, i, line.strip()))
                found = True
    if not found:
        out.append('   （无）')
    out.append('')


def scan_null_handlers(files):
    """onTap/onPressed 恒为 null（死按钮）"""
    out.append('## 2. 永久 null（死按钮）')
    found = False
    pat = re.compile(r'(onTap|onPressed):\s*null\b')
    for f in files:
        for i, line in enumerate(f.read_text(encoding='utf-8').split('\n'), 1):
            if pat.search(line):
                out.append('   %s:%d  %s' % (f.name, i, line.strip()))
                found = True
    if not found:
        out.append('   （无）')
    out.append('')


def scan_coming_soon(files):
    """占位未实现"""
    out.append('## 3. 占位未实现（showComingSoon）')
    n = 0
    for f in files:
        for i, line in enumerate(f.read_text(encoding='utf-8').split('\n'), 1):
            if 'showComingSoon' in line and 'void showComingSoon' not in line:
                out.append('   %s:%d  %s' % (f.name, i, line.strip()))
                n += 1
    if n == 0:
        out.append('   （无）')
    out.append('')


def scan_small_targets(files):
    """GestureDetector 包 Icon 且无尺寸约束（命中区过小）"""
    out.append('## 4. 命中区可能过小（GestureDetector 直接包 Icon）')
    found = False
    for f in files:
        lines = f.read_text(encoding='utf-8').split('\n')
        for i, line in enumerate(lines):
            if 'GestureDetector(' in line:
                seg = '\n'.join(lines[i:i + 9])
                if re.search(r'child:\s*\n?\s*Icon\(', seg) and \
                   not re.search(r'minimumSize|constraints:|padding:\s*EdgeInsets|SizedBox\(\s*width:\s*4', seg):
                    out.append('   %s:%d  %s' % (f.name, i + 1, line.strip()))
                    found = True
    if not found:
        out.append('   （无）')
    out.append('')


def scan_no_feedback(files):
    """统计 GestureDetector vs InkWell/IconButton（按压反馈覆盖）"""
    out.append('## 5. 按压反馈覆盖（GestureDetector 无涟漪）')
    gd = ink = ib = 0
    per_file = {}
    for f in files:
        t = f.read_text(encoding='utf-8')
        a = t.count('GestureDetector(')
        b = t.count('InkWell(') + t.count('InkResponse(')
        c = t.count('IconButton(')
        gd += a
        ink += b
        ib += c
        if a:
            per_file[f.name] = a
    out.append('   GestureDetector: %d   InkWell: %d   IconButton: %d' % (gd, ink, ib))
    out.append('')
    out.append('   GestureDetector 使用最多的文件（这些地方没有涟漪反馈）：')
    for name, c in sorted(per_file.items(), key=lambda x: -x[1])[:10]:
        out.append('     %-32s %3d' % (name, c))
    out.append('')


def scan_uncaught_async(files):
    """onTap 里的 await 无 try/catch（失败静默）"""
    out.append('## 6. 交互回调里的 await 无 try/catch（失败静默）')
    found = False
    for f in files:
        lines = f.read_text(encoding='utf-8').split('\n')
        for i, line in enumerate(lines):
            if re.search(r'onTap:\s*\(\)\s*(async\s*)?\{', line) or \
               re.search(r'onPressed:\s*\(\)\s*(async\s*)?\{', line):
                seg = '\n'.join(lines[i:i + 12])
                if 'await ' in seg and 'try' not in seg and 'catch' not in seg:
                    out.append('   %s:%d' % (f.name, i + 1))
                    found = True
    if not found:
        out.append('   （无）')
    out.append('')


files = collect()
out.append('=' * 66)
out.append('按键 / 交互元素静态审查  （%d 个 dart 文件）' % len(files))
out.append('=' * 66)
out.append('')

scan_empty_handlers(files)
scan_null_handlers(files)
scan_coming_soon(files)
scan_small_targets(files)
scan_no_feedback(files)
scan_uncaught_async(files)

# 统计
out.append('## 汇总')
total = 0
for f in files:
    t = f.read_text(encoding='utf-8')
    total += t.count('onTap:') + t.count('onPressed:')
out.append('   可交互回调（onTap/onPressed）总数: %d' % total)

open(sys.argv[1], 'w', encoding='utf-8').write('\n'.join(out))
print('OK')
