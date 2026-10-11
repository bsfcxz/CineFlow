// 简繁转换守卫（用户报障："弹幕还是繁体的，都和你说过了"）。
//
// ## 背景：服务端转换**有效**，但覆盖不到两条路径
// 实测（弹弹play 公共代理，2026-10-11）：
// ```
// 剧场版：cv=0 vs cv=1 不同 119 条；cv=0 vs cv=2 不同 22575 条
// ⇒ 服务端转换器工作正常
// ```
// 但：
// · **本地导入的弹幕**不经过服务端 ⇒ `chConvert` 完全无效
// · 服务端转换不彻底的条目
// ⇒ 必须有客户端兜底。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cineflow/danmaku/chinese_convert.dart';

void main() {
  group('★★ 简体转换：幂等 + 覆盖高频字', () {
    test('★★ 用户截图里的原文必须被转换（报障原文逐条）', () {
      // 用户截图里的弹幕（吞噬星空剧场版：决战原始星）
      const cases = {
        '花錢的頂上去': '花钱的顶上去',
        '必須支援一下': '必须支援一下',
        '人類巨擘勢力因看中地球的特殊': '人类巨擘势力因看中地球的特殊',
        '都花錢了就必须好好看': '都花钱了就必须好好看',
        '看完肖戰版再看原著': '看完肖战版再看原着',
      };
      cases.forEach((trad, simp) {
        expect(toSimplified(trad), simp,
            reason: '★★ «$trad» 是用户截图里的原文\n'
                '    ⇒ 必须转成 «$simp»（导入路径靠这个兜底）');
      });
    });

    test('★★★ 幂等：转过的再转不变（防御性重转的前提）', () {
      const samples = [
        '花钱的顶上去',
        '必须支援一下',
        '这是一个测试',
        'abc 123 !!!',
        '',
        '简体已是最好的',
      ];
      for (final s in samples) {
        final once = toSimplified(s);
        final twice = toSimplified(once);
        expect(twice, once,
            reason: '★★★ 客户端会对"服务端已转过的内容"**再转一次**；\n'
                '    不幂等就会把简体转坏 ⇒ 必须保证 toSimplified(toSimplified(x))\n'
                '    == toSimplified(x)');
      }
    });

    test('★★ 常见繁体字覆盖（回归表）', () {
      const cases = {
        '繁體': '繁体',
        '這裡': '这里',
        '說話': '说话',
        '時間': '时间',
        '學習': '学习',
        '國家': '国家',
        '機會': '机会',
        '後面': '后面',
        '發現': '发现',
        '點擊': '点击',
        '音樂': '音乐',
        '經過': '经过',
        '還是': '还是',
        '為什麼': '为什么',
        '與眾不同': '与众不同',
        '從沒': '从没',
      };
      cases.forEach((trad, simp) {
        expect(toSimplified(trad), simp, reason: '«$trad» → «$simp»');
      });
    });

    test('★ 纯 ASCII / 数字 / 空串零改动', () {
      for (final s in ['', 'abc', '123', 'hello world!', '2333']) {
        expect(toSimplified(s), s);
      }
    });

    test('★ 映射表规模合理（不是空壳）', () {
      expect(t2sTable.length, greaterThan(300),
          reason: '★ 表太小说明覆盖不足；实测用户截图里的\n'
              '    錢/頂/勢/須/號/類/擘/說/話/們 都要在里面');
      for (final c in ['錢', '頂', '勢', '須', '號', '類', '說', '話', '們']) {
        expect(t2sTable.containsKey(c), isTrue,
            reason: '★ «$c» 出现在用户截图里 ⇒ 必须在表内');
      }
    });

    test('★ 表内不得有 identity 映射（繁体==简体是噪音）', () {
      final bad = t2sTable.entries.where((e) => e.key == e.value).toList();
      expect(bad, isEmpty,
          reason: '★ identity 条目是噪音（增加表大小但不改变行为）：\n'
              '    ${bad.take(5).map((e) => e.key).join(",")}');
    });
  });

  group('★★★ 导入路径必须做转换（用户报障的直接原因）', () {
    test('★★★ parseDanmakuFile 必须调用 toSimplified', () {
      final src = File('lib/danmaku/danmaku_import.dart').readAsStringSync();
      // 剥注释（§8.4：断言不得被注释满足）
      final code = src
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains('toSimplified(text)'), isTrue,
          reason: '★★★ 导入的是**用户本地文件**，不经过弹弹play 服务端\n'
              '    ⇒ 服务端 `chConvert` 完全无效。\n'
              '    实测修复前本文件**没有任何**简繁处理 ⇒\n'
              '    导入繁体弹幕就一直显示繁体（用户报障原文）');
      expect(code.contains("import 'chinese_convert.dart';"), isTrue,
          reason: '★ 用了就必须 import（否则 analyze 会报未定义）');
    });

    test('★★ 转换必须在**格式判定之前**（否则 ASS 特征可能被改坏）', () {
      final src = File('lib/danmaku/danmaku_import.dart').readAsStringSync();
      final iConv = src.indexOf('toSimplified(text)');
      final iAss = src.indexOf("contains('[Script Info]')");
      expect(iConv, greaterThanOrEqualTo(0));
      expect(iAss, greaterThanOrEqualTo(0));
      expect(iConv, lessThan(iAss),
          reason: '★★ 格式判定依赖英文字面量（`[Script Info]` / `Dialogue:` /\n'
              '    `<?xml`）—— 那些不会被简繁转换影响，但顺序上\n'
              '    先转再判更清晰（且将来若加中文特征判定会踩坑）');
    });
  });

  group('★ 设置页必须让用户看到当前档位', () {
    test('★ 弹幕设置页必须有简繁转换入口', () {
      final s = File('lib/danmaku/danmaku_settings_page.dart')
          .readAsStringSync();
      expect(s.contains('DanmakuChConvert.values'), isTrue,
          reason: '★ 用户报"弹幕还是繁体的" ⇒ 必须能在 UI 里看到/改档位，\n'
              '    否则无从自查（我第一版在 lib/pages/ 里找，漏了）');
      expect(s.contains('简繁转换'), isTrue);
    });
  });
}
