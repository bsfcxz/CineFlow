/// U7 详情页的**回归守护**。
///
/// # 这个批次修了什么（都是**算过**的，不是凭感觉）
///
/// ## 1. 演职员行在 2.0x 字缩下会溢出固定高容器
///
/// 实测内容高（Roboto 行高系数 1.171875，Flutter 未指定 `height` 时）：
///
///     1.0x → 62 + 7 + 12.89 + 10.55 =  92.44（富余 17.6）
///     1.5x →                         = 104.16（仍不溢出）
///     2.0x →                         = 115.88 → **溢出 5.9dp**
///
/// 所以**默认字号下行高 110 是合适的**，把它改大会在默认场景留多余空白。
/// 真正的问题是"2.0x 时文字撑破固定高容器" → 正确解法是**钳制那两行文字**
/// （`CfText(clamp: true)`），本测试用 `castContentHeight` 复算这条账。
///
/// ## 2. 头部海报 96×142 / 版本缩略图 128×72 写死（审计 U7 点名）
/// 改为按窗口尺寸类给值：大屏给足主视觉。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/core/theme.dart';
import 'package:cineflow/pages/detail_page.dart';

/// 读源码并剥掉整行注释（否则注释里提到 CfText 会造成假绿 —— 实测踩过）。
String _code(String rel) => File(rel)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final s = l.trimLeft();
      return !s.startsWith('//') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  group('U7 · 演职员行高与字缩', () {
    test('★ 复算审计那条账：2.0x 下**未钳制**会溢出 110', () {
      // 这条断言的意义：把"为什么必须钳制"变成一个**可执行的数字**。
      // 若将来有人把 110 改小、或把字号改大，这条会先红。
      final h = DetailPage.castContentHeight(textScale: 2.0);
      expect(
        h,
        greaterThan(DetailPage.castRowHeight),
        reason: '2.0x 下算得 $h dp，居然没超过 110 —— \n'
            '说明布局参数变了（头像/间距/字号），审计那条账要重算。',
      );
    });

    test('默认 1.0x 下有富余（所以不该盲目加大行高）', () {
      final h = DetailPage.castContentHeight();
      expect(h, lessThan(DetailPage.castRowHeight),
          reason: '默认字号下就溢出，说明 110 本身就太小 —— 那才该改行高。\n'
              '实测应为 92.44 (<110)。');
      expect(DetailPage.castRowHeight - h, greaterThan(10),
          reason: '默认下富余应 >10dp（实测 17.6）；若富余很小，\n'
              '说明参数被改过，需重新评估是否该调整行高而非仅钳制。');
    });

    test('钳制到 1.3x 后，内容高 ≤ 行高（这才是修法的效果）', () {
      // CfText 的 maxFactor 是 1.3 → 有效字缩不会超过 1.3
      final clamped = DetailPage.castContentHeight(textScale: 1.3);
      expect(
        clamped,
        lessThanOrEqualTo(DetailPage.castRowHeight),
        reason: '钳到 1.3x 后仍溢出（$clamped > 110）—— \n'
            '说明光靠 1.3 的钳制不够，得同时调小头像或字号。',
      );
    });

    test('内容高随字缩单调递增（参数没写反）', () {
      var prev = 0.0;
      for (final s in [1.0, 1.2, 1.5, 2.0, 3.0]) {
        final h = DetailPage.castContentHeight(textScale: s);
        expect(h, greaterThan(prev), reason: '字缩 $s 时高度未递增');
        prev = h;
      }
    });
  });

  group('U7 · 断点尺寸', () {
    test('海报宽随窗口类递增，Compact 保持原值 96', () {
      expect(DetailPage.posterWidthFor(CfBreakpoints.compact), 96.0,
          reason: 'Compact 应保持原值（改它是无谓的视觉变更）');
      expect(DetailPage.posterWidthFor(CfBreakpoints.medium),
          greaterThan(96.0));
      expect(DetailPage.posterWidthFor(CfBreakpoints.expanded),
          greaterThan(DetailPage.posterWidthFor(CfBreakpoints.medium)),
          reason: 'Expanded 应比 Medium 更大');
    });

    test('版本缩略图宽随窗口类递增，Compact 保持原值 128', () {
      expect(DetailPage.versionThumbWidthFor(CfBreakpoints.compact), 128.0);
      expect(DetailPage.versionThumbWidthFor(CfBreakpoints.medium),
          greaterThan(128.0));
      expect(
        DetailPage.versionThumbWidthFor(CfBreakpoints.expanded),
        greaterThan(DetailPage.versionThumbWidthFor(CfBreakpoints.medium)),
      );
    });

    test('海报高宽比接近 2:3（不因断点变形）', () {
      // _poster 里高度 = width * 1.48
      const classes = [
        CfBreakpoints.compact,
        CfBreakpoints.medium,
        CfBreakpoints.expanded,
      ];
      for (final wc in classes) {
        final w = DetailPage.posterWidthFor(wc);
        final h = w * 1.48;
        expect(h / w, closeTo(1.5, 0.05),
            reason: '窗口类 $wc 上海报比例偏离 2:3（$w×$h）→ 图片会被拉伸');
      }
    });

    test('未知窗口类退化为 Compact（不崩）', () {
      expect(DetailPage.posterWidthFor(999), 96.0);
      expect(DetailPage.versionThumbWidthFor(-1), 128.0);
    });
  });

  group('U7 · 源码约束（剥注释后断言）', () {
    final src = _code('lib/pages/detail_page.dart');

    test('演职员两行文字都钳制（固定高容器内必须钳）', () {
      final n = RegExp(r'CfText\([\s\S]{0,120}?clamp:\s*true').allMatches(src).length;
      expect(n, greaterThanOrEqualTo(2),
          reason: '演职员行（姓名 + 角色）的钳制丢了（匹配到 $n 处，期望 ≥2）。\n'
              '2.0x 字缩下内容高 115.88 > 行高 110 → 文字被裁。');
    });

    test('海报/缩略图不再用写死的 96×142 / 128×72', () {
      expect(RegExp(r'width:\s*96\b').hasMatch(src), isFalse,
          reason: '海报宽又写死 96 了 —— 大屏上主视觉会显得小气');
      expect(RegExp(r'height:\s*142\b').hasMatch(src), isFalse,
          reason: '海报高又写死 142 了');
      expect(RegExp(r'width:\s*128\b').hasMatch(src), isFalse,
          reason: '版本缩略图宽又写死 128 了');
    });

    test('用了断点工具', () {
      expect(RegExp(r'CfBreakpoints\.of\(').hasMatch(src), isTrue);
      expect(RegExp(r'DetailPage\.posterWidthFor\(').hasMatch(src), isTrue);
      expect(
          RegExp(r'DetailPage\.versionThumbWidthFor\(').hasMatch(src), isTrue);
    });
  });
}
