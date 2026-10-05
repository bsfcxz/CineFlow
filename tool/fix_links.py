# -*- coding: utf-8 -*-
"""清洗指向已移除文档的链接（门禁断链）+ release.yml 的 \r 校验修复"""
import io
import re

BS = chr(92)

# ---------- 1) release.yml：PW_VER 提取行加 tr -d '\r' ----------
p = '.github/workflows/release.yml'
lines = io.open(p, encoding='utf-8').read().split('\n')
for i, l in enumerate(lines):
    if 'PW_VER=' in l and 'kAppVersion' in l and 'tr -d' not in l:
        lines[i] = l[:-1] + ' | tr -d "' + BS + 'r""' if l.endswith('"') else l
        # 更稳：直接重写整行
        lines[i] = ('        PW_VER="$(grep -o "const String kAppVersion = '
                    "'[^']*'" + '" lib/core/version.dart | sed "s/.*'
                    + BS + "'(.*" + BS + "')'.*/" + BS + '1/" | tr -d "'
                    + BS + 'r")"')
        print('release.yml PW_VER 行已修')
io.open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))

# ---------- 2) 断链清洗 ----------
EXCLUDED = ['task-board', 'review-checklist', 'TECH-SKILLS', 'OSS-SOURCES',
            'UPDATE-WORKFLOW', 'PROMPT-TEMPLATES', 'skills/cineflow',
            'ACKNOWLEDGEMENTS']
FILES = ['README.md', 'CONTRIBUTING.md', 'AGENTS.md', 'CHANGELOG.md',
         'docs/architecture.md', 'docs/CHANGELOG-GUIDE.md',
         'docs/lessons/README.md', 'docs/lessons/methodology.md',
         'docs/decisions/README.md',
         'docs/decisions/0001-flutter-go-libmpv-stack.md',
         'docs/decisions/0002-pure-dart-mvp.md',
         'docs/decisions/0003-remove-library-tab.md',
         'docs/decisions/0004-go-core-layer.md',
         'docs/decisions/0006-danmaku-source-and-rendering.md',
         'docs/decisions/0007-pan115-webapi-route.md',
         'docs/changelog/README.md', 'docs/changelog/v0.2.0.md']

link_re = re.compile(r'\[([^\]]*)\]\(([^)]*)\)')

def has_excluded(m):
    return any(e in m.group(2) for e in EXCLUDED)

for p in FILES:
    try:
        lines = io.open(p, encoding='utf-8').read().split('\n')
    except FileNotFoundError:
        continue
    out = []
    removed = 0
    for l in lines:
        links = list(link_re.finditer(l))
        bad = [m for m in links if has_excluded(m)]
        if not bad:
            out.append(l)
            continue
        # 表格行（| 开头）→ 整行删除
        if l.strip().startswith('|'):
            removed += 1
            continue
        # 列表行且链接是行内主体 → 删除整行
        stripped = l.strip()
        if stripped.startswith(('-', '*', '>')) and len(bad) == len(links):
            removed += 1
            continue
        # 其他：把坏链接替换为其显示文本（去链接语法）
        for m in sorted(bad, reverse=True):
            l = l[:m.start()] + m.group(1) + l[m.end():]
        out.append(l)
    if removed or out != lines:
        io.open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
        print(f'{p}: 删行 {removed}')
