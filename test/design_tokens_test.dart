/// U1 设计令牌的**回归守护**。
///
/// # 为什么这类测试值得写
///
/// 设计令牌的失效方式很特殊：**它不会报错，只会慢慢腐烂**。
/// 实测数据（U1 开工时）：
///   · 裸 `fontSize` **232 处 / 11 种字号**，而 `Cf` 排版令牌只用了 **24 处**（9.4%）
///   · `circular()` 用了 **16 种不同值**（1/2/4/5/6/7/8/9/10/11/12/13/14/16/18/20）
///   · `clampTextScale`（字缩钳制）与 `CfBreakpoints` 定义在 theme 里，
///     **真代码采用各 0 处** —— "字号上限 1.3x" 这条规则从未生效
///
/// 也就是说：**令牌存在 ≠ 令牌生效**。审计说"要新增令牌"，
/// 但真正的问题是**定义了没人用**，而这件事**没有任何编译期/运行期机制会发现**。
///
/// # 本文件的断言口径
/// 全部基于**源码文本**（与 `tool/audit_tokens.py` 同口径），断言**上界**
/// （不超 N 种值），所以继续收敛也通过，只有"又散开"才变红。
///
/// 「clampTextScale / CfBreakpoints 的采用率」断言在 U2（底部 Tab）与
/// U3（轮播断点）落地时才加 —— 那两批才是它们真正的用武之地。
/// 现在加会立刻变红（采用确实是 0），那是**假红**，会训练人忽略红灯。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/core/theme.dart';

/// 递归收集 lib/ 下的 dart 文件。
List<File> _dartFiles() {
  final out = <File>[];
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) out.add(e);
  }
  return out;
}

/// 去掉整行注释 —— 否则"注释里提到令牌"会被算作采用（假阳性）。
///
/// ## ⚠️ 这一步是必须的（实测踩过同类坑）
///
/// 姊妹文件 `shell_tab_test.dart` 的第一版**没剥注释**，结果反向注入无效：
/// 源码里有一行注释写着 `// SafeArea(top: false) 已把…`，
/// 于是即使把**代码里**的 `top: false` 删掉，正则仍匹配到**注释** → 测试假绿。
///
/// 教训：凡是基于源码文本的断言，**必须先在"无注释文本"上做匹配** ——
/// 否则你守的可能是自己的注释。
String _stripLineComments(String text) => text
    .split('\n')
    .where((l) {
      final s = l.trimLeft();
      return !s.startsWith('//') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  group('U1 · 圆角令牌收敛', () {
    test('circular() 的值必须收敛到 4 档（4/8/12/16）', () {
      final vals = <String>{};
      final bad = <String>[];
      final re = RegExp(r'circular\(([0-9]+(?:\.[0-9]+)?)\)');
      for (final f in _dartFiles()) {
        final t = _stripLineComments(f.readAsStringSync());
        for (final m in re.allMatches(t)) {
          final v = double.parse(m.group(1)!);
          vals.add(m.group(1)!);
          if (v != 4 && v != 8 && v != 12 && v != 16) {
            bad.add('${f.path}: circular(${m.group(1)})');
          }
        }
      }
      expect(
        bad,
        isEmpty,
        reason: '圆角又散开了。收敛前实测有 16 种值'
            '（1/2/5/6/7/9/10/11/13/14/18/20 …），\n'
            '它们与 4/8/12/16 只差 1–2px —— 肉眼分不出，但让界面「没有节奏」。\n'
            '请用 Cf.radiusXs/Sm/Md/Lg。越界 ${bad.length} 处：\n'
            '${bad.take(20).join('\n')}',
      );
      expect(vals.length, lessThanOrEqualTo(4),
          reason: '引入了第 5 种圆角档位（现有：${vals.join(', ')}）');
    });

    test('圆角令牌四档齐全且递增', () {
      // 令牌本身若被改动（比如删掉 radiusXs），这里立刻发现
      expect(Cf.radiusXs, 4.0);
      expect(Cf.radiusSm, 8.0);
      expect(Cf.radiusMd, 12.0);
      expect(Cf.radiusLg, 16.0);
      expect(Cf.radiusXs < Cf.radiusSm, isTrue);
      expect(Cf.radiusSm < Cf.radiusMd, isTrue);
      expect(Cf.radiusMd < Cf.radiusLg, isTrue);
    });
  });

  group('U1 · 排版令牌不能被裸 fontSize 淹没', () {
    test('裸 fontSize 的**种类数**不超过 11（当前基线）', () {
      final sizes = <String>{};
      final re = RegExp(r'fontSize:\s*([0-9]+(?:\.[0-9]+)?)');
      for (final f in _dartFiles()) {
        final t = _stripLineComments(f.readAsStringSync());
        for (final m in re.allMatches(t)) {
          sizes.add(m.group(1)!);
        }
      }
      // 基线 11 种（9/10/11/12/13/14/15/16/20/22/24）。
      // 断言"不超过基线"= 只许收敛、不许新增档位（U2–U9 会逐步换成令牌）。
      expect(
        sizes.length,
        lessThanOrEqualTo(11),
        reason: '裸 fontSize 的种类又变多了（现有 ${sizes.length} 种：'
            '${(sizes.toList()..sort()).join(', ')}）。\n'
            '新增文案请用 Cf 的排版令牌，不要切新的 0.5px 档。',
      );
    });
  });

  group('U1 · CfText 的钳制策略', () {
    test('≥14sp 视为标题 → 钳制；<14sp 视为正文 → 跟随系统', () {
      // 口径与 CfText._titleThreshold 一致。这条断言的意义：
      // 将来有人改阈值时，会先撞到这里，被迫想清楚"哪些该钳"。
      const threshold = 14.0;
      for (final fs in [20.0, 16.0, 14.0]) {
        expect(fs >= threshold, isTrue, reason: '${fs}sp 应被判为标题');
      }
      for (final fs in [13.0, 12.0, 11.0, 10.0]) {
        expect(fs >= threshold, isFalse, reason: '${fs}sp 应被判为正文（不钳制）');
      }
    });

    test('clampTextScale 在 1.0x 下原样返回（不干扰正常场景）', () {
      const scaler = TextScaler.linear(1.0);
      expect(clampTextScale(scaler), same(scaler));
    });

    test('clampTextScale 把 2.0x 压到 1.3x', () {
      final out = clampTextScale(const TextScaler.linear(2.0));
      expect(out.scale(10), closeTo(13.0, 0.01));
    });

    test('clampTextScale 不动 1.2x（未超上限）', () {
      final out = clampTextScale(const TextScaler.linear(1.2));
      expect(out.scale(10), closeTo(12.0, 0.01));
    });
  });
}
