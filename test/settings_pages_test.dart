/// U8 设置三页（播放 / 弹幕 / 外观）的**回归守护**。
///
/// # 这个批次修了什么
///
/// | 问题 | 原状态 | 影响 |
/// |---|---|---|
/// | 选项 chip（倍速/长按倍速/默认倍速） | 裸 `GestureDetector`，高约 **30dp** | 只有 48dp 基线的 62%，且无按压反馈 |
/// | 开关 | 视觉 44×25，命中区 **25dp** | 48dp 的 52%（审计实测"开关 18h"） |
/// | 主题色块 | 裸 `GestureDetector` | 点**已选中**项时颜色不变 → 没有反馈就完全像没响应 |
///
/// 统一改法：`InkWell`（按压反馈）+ `CfTapTarget` / `ConstrainedBox`
/// （撑命中区，**视觉不变**）+ `CfText(clamp: true)`（固定行高容器里防字缩溢出）
/// + `Semantics`（读屏可读）。
///
/// # 为什么用源码断言
/// 三页都需要 `MediaProvider` / 弹幕 provider 才能渲染，widget 测试成本高。
/// 而本批改的都是**结构性约束**（有没有用 InkWell、命中区包没包），
/// 源码断言能精确守住，且反向注入可验证。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读源码并剥掉整行注释（否则注释里提到 InkWell/CfTapTarget 会造成假绿）。
String _code(String rel) => File(rel)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final s = l.trimLeft();
      return !s.startsWith('//') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  const pages = {
    '播放设置': 'lib/pages/playback_settings_page.dart',
    '外观设置': 'lib/pages/appearance_page.dart',
    '弹幕设置': 'lib/danmaku/danmaku_settings_page.dart',
  };

  group('U8 · 设置三页：无裸 GestureDetector', () {
    for (final e in pages.entries) {
      test('${e.key}：没有裸 GestureDetector（需按压反馈）', () {
        final src = _code(e.value);
        expect(
          src.contains('GestureDetector'),
          isFalse,
          reason: '${e.key}又用了裸 GestureDetector —— 它**没有按压反馈**。\n'
              '设置项尤其需要反馈：用户点了"没变化"会怀疑没生效，反复点。\n'
              '请用 InkWell；若只是要撑命中区，用 CfTapTarget。',
        );
      });
    }
  });

  group('U8 · 播放设置：命中区与字缩', () {
    final src = _code('lib/pages/playback_settings_page.dart');

    test('选项 chip 命中区 ≥48dp', () {
      expect(
        RegExp(r'minHeight:\s*48').hasMatch(src),
        isTrue,
        reason: '选项 chip 的命中区没撑到 48dp。\n'
            '原为 vertical:8 + 12sp 文字 ≈ 30dp（基线的 62%），\n'
            '手指容易点偏到相邻选项。',
      );
    });

    test('开关命中区用 CfTapTarget（视觉仍是 44×25）', () {
      expect(src.contains('CfTapTarget('), isTrue,
          reason: '开关的命中区没撑起来。原为 44×25 → 命中区仅 25dp（基线的 52%），\n'
              '审计实测"设置抽屉开关 18h"就是这类。');
      // 视觉尺寸应保持不变（不能靠"把开关画大"来满足触控）
      expect(RegExp(r'width:\s*44').hasMatch(src), isTrue,
          reason: '开关视觉宽度被改了 —— 应保持 44，只撑命中区');
      expect(RegExp(r'height:\s*25').hasMatch(src), isTrue,
          reason: '开关视觉高度被改了 —— 应保持 25，只撑命中区');
    });

    test('选项文字钳制字缩（行高固定 48，200% 会撑破）', () {
      expect(
        RegExp(r'CfText\([\s\S]{0,140}?clamp:\s*true').hasMatch(src),
        isTrue,
        reason: '选项文字没钳制。12sp 在 200% 下 → 24sp，\n'
            '会把 48dp 的行高撑破（文字被裁）。',
      );
    });

    test('选项带无障碍语义（button + selected + label）', () {
      expect(src.contains('Semantics('), isTrue);
      expect(src.contains('button: true'), isTrue);
      expect(src.contains('selected: selected'), isTrue,
          reason: '缺 selected —— 读屏用户不知道当前选的是哪个倍速');
      expect(src.contains('label: label'), isTrue);
    });
  });

  group('U8 · 外观设置：主题色块', () {
    final src = _code('lib/pages/appearance_page.dart');

    test('主题色块命中区 ≥72dp（色块 40 + 间距 7 + 文字行）', () {
      expect(RegExp(r'size:\s*72').hasMatch(src), isTrue,
          reason: '主题色块命中区不足。原为裸 GestureDetector 包 40×40 色块，\n'
              '命中区只有色块本身 —— 而色块下方还有主题名，点文字上没反应。');
    });

    test('主题色块带语义（读屏可读主题名与选中态）', () {
      expect(RegExp(r"semanticLabel:\s*'主题色").hasMatch(src), isTrue,
          reason: '主题色块缺语义 —— 读屏只能念出无名的可点区域');
      expect(src.contains('已选中'), isTrue,
          reason: '选中态没并进语义 —— 读屏用户不知道当前用的是哪个主题');
    });

    test('主题名钳制字缩（四项横排的窄格子）', () {
      expect(
        RegExp(r'CfText\([\s\S]{0,140}?clamp:\s*true').hasMatch(src),
        isTrue,
        reason: '主题名没钳制。四个主题横排时每格很窄，\n'
            '200% 下文字会互相挤压或换行。',
      );
    });
  });

  group('U8 · 弹幕设置', () {
    final src = _code('lib/danmaku/danmaku_settings_page.dart');

    test('用 Material 的 SwitchListTile（自带 ≥48dp 行高）', () {
      expect(src.contains('SwitchListTile'), isTrue,
          reason: '弹幕设置的开关改成了自绘 —— Material 的 SwitchListTile\n'
              '自带 48dp 行高与语义，自绘容易漏掉两者。');
    });

    test('没有裸 GestureDetector（与另两页一致）', () {
      expect(src.contains('GestureDetector'), isFalse);
    });
  });
}
