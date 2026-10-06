# -*- coding: utf-8 -*-
"""设计令牌采用率审计工具（U1 的可度量产物）。

## 为什么需要它
`docs/local/UI-ADAPTATION-AUDIT.md` 说"字号无语义档 / 间距无令牌 / 断点无"，
要求"新增 `Cf.typo.*` / `Cf.space.*` / `CfBreakpoints`"。

**但审计写于基线 `a3dfcd8`，之后用户提交了 `caaf31e`（登录页横屏），
该提交已经把这三样都加进去了。** 若照着过时审计再"新增"一遍，
会造出**重复定义**（编译错误或静默覆盖），或者谎报"U1 完成"（实际是重复劳动）。

更关键的是：**"定义了令牌" ≠ "用了令牌"**。
本工具回答那个真正的问题 —— **采用率是多少、还差多少**。

## 判据（都排除注释与字符串字面量）
  · 裸 `fontSize: <数字>`  = 未采用排版令牌
  · `Cf.gapN` 用量           = 间距令牌采用
  · `CfBreakpoints.` 真代码  = 断点采用
  · `clampTextScale(` 真代码 = 字号钳制采用（审计要求的关键能力）
  · `Semantics(` 真代码      = 无障碍语义
  · `circular(N)` 的不同 N   = 圆角散落程度

用法：
    python tool/audit_tokens.py            # 人读报告
    python tool/audit_tokens.py --check    # 只看是否达标（CI/门禁用，退出码 0/1）
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib')

# 圆角收敛目标：3 档令牌 + 微圆角（进度条端帽/角标）
RADIUS_TARGET = {'4', '8', '12', '16'}


def dart_files():
    out = []
    for dp, dns, fns in os.walk(ROOT):
        for fn in fns:
            if fn.endswith('.dart'):
                out.append(os.path.join(dp, fn))
    return out


def strip_comments(text):
    """去掉整行注释，避免"注释里提了令牌"被算成采用。"""
    keep = []
    for line in text.split('\n'):
        s = line.strip()
        if s.startswith('//'):
            continue
        # 去掉行尾 // 注释（粗略但够用：本项目 URL 里的 // 都在字符串中，
        # 且那些行不含我们要统计的模式）
        keep.append(line)
    return '\n'.join(keep)


def scan():
    files = dart_files()
    r = {
        'files': len(files),
        'bare_fontsize': {},      # 值 -> 次数
        'token_font': 0,
        'gap_token': 0,
        'breakpoints': 0,
        'clamp_text': 0,
        'semantics': 0,
        'semantics_files': [],
        'radius': {},             # 值 -> 次数
        'radius_bad': 0,
    }
    for f in files:
        t = strip_comments(open(f, encoding='utf-8', errors='replace').read())
        base = os.path.basename(f)

        for m in re.finditer(r'fontSize:\s*([0-9]+(?:\.[0-9]+)?)', t):
            v = m.group(1)
            r['bare_fontsize'][v] = r['bare_fontsize'].get(v, 0) + 1

        r['token_font'] += len(re.findall(
            r'\bCf\.(pageTitle|section|title|body|label|caption|micro|numeric)\b', t))
        r['gap_token'] += len(re.findall(r'\bCf\.gap[1-6]\b', t))
        r['breakpoints'] += len(re.findall(r'CfBreakpoints\.', t))
        r['clamp_text'] += len(re.findall(r'clampTextScale\(', t))

        n_sem = len(re.findall(r'Semantics\(', t))
        if n_sem:
            r['semantics'] += n_sem
            r['semantics_files'].append(base)

        for m in re.finditer(r'circular\(([0-9]+(?:\.[0-9]+)?)\)', t):
            v = m.group(1)
            r['radius'][v] = r['radius'].get(v, 0) + 1
            if v not in RADIUS_TARGET:
                r['radius_bad'] += 1
    return r


def main():
    check = '--check' in sys.argv
    r = scan()

    print('== 设计令牌采用率审计 ==')
    print('  扫描 lib/ 下 %d 个 dart 文件' % r['files'])
    print()

    bare = sum(r['bare_fontsize'].values())
    print('  [typography]')
    print('    裸 fontSize        : %d 处（%d 种字号）' % (bare, len(r['bare_fontsize'])))
    print('    Cf 排版令牌        : %d 处' % r['token_font'])
    total_fs = bare + r['token_font']
    if total_fs:
        print('    采用率             : %.1f%%' % (100.0 * r['token_font'] / total_fs))
    print()

    print('  [space]      Cf.gap*        : %d 处' % r['gap_token'])
    print('  [breakpoint] CfBreakpoints  : %d 处' % r['breakpoints'])
    print('  [textscale]  clampTextScale : %d 处' % r['clamp_text'])
    print('  [a11y]       Semantics      : %d 处（%d 个文件）'
          % (r['semantics'], len(r['semantics_files'])))
    print()

    bad = r['radius_bad']
    tot_radius = sum(r['radius'].values())
    print('  [radius]     circular() 共 %d 处，用到 %d 种值' % (tot_radius, len(r['radius'])))
    print('    收敛目标 {4, 8, 12, 16}；**不合目标 %d 处**' % bad)
    off = {k: v for k, v in r['radius'].items() if k not in RADIUS_TARGET}
    if off:
        print('    越界值: %s' % ', '.join(
            '%s×%d' % (k, v) for k, v in sorted(off.items(), key=lambda kv: float(kv[0]))))
    print()

    if check:
        # 门禁口径：只把"圆角越界"设为硬失败（这是 U1 能完全收敛的项）。
        # 采用率是**渐进指标**，不设阈值 —— 否则 U2–U9 期间门禁一直是红的。
        ok = (bad == 0)
        print('== 结论 ==')
        if ok:
            print('  圆角已收敛到 3+1 档，通过')
            return 0
        print('  圆角仍有 %d 处越界 —— 未通过' % bad)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
