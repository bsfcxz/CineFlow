// 导入本地弹幕文件 + 合并相同弹幕 + 不透明度语义的守卫测试。
//
// ## 覆盖的 5 项用户需求
// 1. 弹幕全部转简体（服务端 `chConvert`；这里守"默认值必须是简体"）
// 2. **合并相同弹幕**（`mergeDuplicates`）
// 3. **导入本地弹幕文件**（`parseDanmakuFile`，三种格式）
// 4. 显示区域 0–100 可拖动 + 字体大小可拖动（连续滑条）
// 5. **不透明度 0 = 完全隐藏**（描边必须跟着淡出，不能留轮廓）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/danmaku/danmaku_config.dart';
import 'package:cineflow/danmaku/danmaku_import.dart';
import 'package:cineflow/danmaku/danmaku_layout.dart';
import 'package:cineflow/danmaku/danmaku_models.dart';
import 'package:cineflow/player/domain/models/danmaku_panel_state.dart';

/// 剥注释读源码（§8.4：断言不得被注释满足）。
String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  // ══════════════════════════════════════════════════════════
  // ② 合并相同弹幕
  // ══════════════════════════════════════════════════════════
  group('★★ 合并相同弹幕（用户要求"并合并相同弹幕"）', () {
    test('★★ 完全相同的文本只留**最早**一条', () {
      final items = [
        const Danmaku(timeMs: 5000, text: '好帅', color: 0xFFFFFF),
        const Danmaku(timeMs: 9000, text: '好帅', color: 0xFF0000),
        const Danmaku(timeMs: 3000, text: '前排', color: 0xFFFFFF),
      ];
      final out = mergeDuplicates(items);
      expect(out.length, 2, reason: '两条"好帅"应合并成一条');
      expect(out.map((d) => d.text).toList(), ['好帅', '前排'],
          reason: '顺序保持（不重排）');
      expect(out.first.timeMs, 5000,
          reason: '★ 保留**最早**那条（首发在剧情点上，跟风重复在后面）');
      expect(out.first.color, 0xFFFFFF,
          reason: '保留最早那条的**全部属性**（颜色也应是它的）');
    });

    test('★ 忽略首尾空白差异（"好帅" 与 "好帅 " 视为同一条）', () {
      final items = [
        const Danmaku(timeMs: 1000, text: '好帅', color: 0xFFFFFF),
        const Danmaku(timeMs: 2000, text: '好帅 ', color: 0xFFFFFF),
        const Danmaku(timeMs: 3000, text: ' 好帅', color: 0xFFFFFF),
      ];
      expect(mergeDuplicates(items).length, 1);
    });

    test('★★ 不同时间的**不同**文本不合并（不能只按时间粗筛）', () {
      final items = [
        const Danmaku(timeMs: 1000, text: '好帅', color: 0xFFFFFF),
        // 同一句在不同剧情点出现是**合理的**（不是刷屏）
        const Danmaku(timeMs: 40000, text: '泪目', color: 0xFFFFFF),
      ];
      expect(mergeDuplicates(items).length, 2);
    });

    test('★ 无重复时**返回原列表**（不无谓分配）', () {
      final items = [
        const Danmaku(timeMs: 1000, text: 'A', color: 0xFFFFFF),
        const Danmaku(timeMs: 2000, text: 'B', color: 0xFFFFFF),
      ];
      expect(identical(mergeDuplicates(items), items), isTrue,
          reason: '没重复应原样返回 —— 省一次列表分配与遍历');
    });

    test('★ 空/单元素列表不崩', () {
      expect(mergeDuplicates(const []), isEmpty);
      expect(
          mergeDuplicates(
              const [Danmaku(timeMs: 0, text: 'x', color: 0xFFFFFF)]).length,
          1);
    });

    test('★★ overlay 必须真的调用 mergeDuplicates（默认合并）', () {
      final o = code('lib/danmaku/danmaku_overlay.dart');
      expect(o.contains('mergeDuplicates('), isTrue,
          reason: '★★ 不调用 ⇒ 合并是死代码，重复弹幕照样刷屏');
      // ⚠️ 是 `filterByLevel(mergeDuplicates(...))` ——
      //    故 mergeDuplicates 出现在 filterByLevel 之**后**（嵌套内层）。
      //    第一版我写反了方向（找 filterByLevel 在 merge 之后），
      //    测试正确地变红了。
      final i = o.indexOf('final shown = filterBlocked(');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到过滤链');
      final seg = o.substring(i, (i + 200).clamp(0, o.length));
      expect(seg.contains('filterByLevel('), isTrue);
      expect(seg.contains('mergeDuplicates('), isTrue,
          reason: '★ 合并必须在过滤链里（先合并再按等级/屏蔽词过滤）');
      expect(seg.indexOf('mergeDuplicates('),
          greaterThan(seg.indexOf('filterByLevel(')),
          reason: '★ mergeDuplicates 是 filterByLevel 的**内层参数**');
    });

    test('★★ ASS 文件不能被 JSON 分支抢走（真实 bug）', () {
      // ## 为什么单测这条（实现时抓到的真 bug）
      // 格式判定原来把"以 `[` 开头 ⇒ JSON"放在 ASS 之前，
      // 而 ASS **以 `[Script Info]` 开头** ⇒ 被当成 JSON 解析，
      // 用户看到"JSON 格式有误"。真机表现是"选 .ass 文件说格式错误"。
      final imp = code('lib/danmaku/danmaku_import.dart');
      final iAss = imp.indexOf("text.contains('[Script Info]')");
      final iJson = imp.indexOf("text.startsWith('{')");
      expect(iAss, greaterThanOrEqualTo(0));
      expect(iJson, greaterThanOrEqualTo(0));
      expect(iAss, lessThan(iJson),
          reason: '★★ ASS 判定必须在 JSON 之前 —— 否则 `[Script Info]`\n'
              '    会被 `startsWith(\'[\')` 抢走（真机表现：\n'
              '    选 .ass 文件报"JSON 格式有误"）');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ③ 导入本地弹幕文件
  // ══════════════════════════════════════════════════════════
  group('★★ 导入本地弹幕文件（B站 XML）', () {
    test('★★ 解析 B站 8 段 XML（颜色在 index 3、字号在 index 2）', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<i>
 <d p="1.5,1,25,16777215,1700000000,0,abc,123">第一条弹幕</d>
 <d p="3.25,1,25,16711680,1700000001,0,def,124">红色弹幕</d>
</i>''';
      final r = parseDanmakuFile(xml, fileName: 'test.xml');
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect(r.format, 'XML');
      expect(r.items.length, 2);
      expect(r.items[0].timeMs, 1500);
      expect(r.items[0].text, '第一条弹幕');
      expect(r.items[0].color, 16777215,
          reason: '★ 8 段布局：颜色在 index 3（不是 2）');
      expect(r.items[1].color, 16711680);
      expect(r.items[1].timeMs, 3250);
    });

    test('★★ 颜色必须夹到 24 位（防带 alpha 的 32 位色变全透明）', () {
      // 0xFFFFFFFF 带 alpha=255（不透明），但 0xFF00FF00 的 alpha 若是 0
      // 会变成全透明 —— 夹到 24 位是唯一安全做法
      const xml = '<i><d p="1,1,25,4286611584,0,0,0,0">x</d></i>';
      final r = parseDanmakuFile(xml);
      expect(r.ok, isTrue);
      expect(r.items.first.color, lessThan(1 << 24),
          reason: '★★ 颜色必须 < 2^24，否则 Flutter 会因 alpha=0 变全透明');
    });

    test('★★ XML 实体必须反转义（顺序：&amp; 最后，否则双重解码）', () {
      const xml = '<i><d p="1,1,25,16777215,0,0,0,0">'
          'a &amp;lt; b &lt; c &amp; d</d></i>';
      final r = parseDanmakuFile(xml);
      expect(r.items.first.text, 'a &lt; b < c & d',
          reason: '★★ `&amp;lt;` 应解成字面量 `&lt;`（不是 `<`）——\n'
              '    若先替换 &amp; 就会双重解码，用户看到的内容是错的');
    });

    test('★ 时间非法的行被跳过并计数（不静默丢）', () {
      const xml = '<i>'
          '<d p="abc,1,25,16777215,0,0,0,0">坏行</d>'
          '<d p="2,1,25,16777215,0,0,0,1">好行</d>'
          '</i>';
      final r = parseDanmakuFile(xml);
      expect(r.items.length, 1);
      expect(r.skipped, 1, reason: '★ 跳过的行数要如实告知用户');
    });

    test('★ 无 `<d>` 标签 ⇒ 明确报错（不是空列表假装成功）', () {
      final r = parseDanmakuFile('<i></i>');
      expect(r.ok, isFalse);
      expect(r.error, contains('没有找到弹幕'));
    });
  });

  group('★★ 导入本地弹幕文件（弹弹play JSON）', () {
    test('★★ 解析 4 段布局（颜色在 index 2，与 XML 不同）', () {
      const json = '{"comments":['
          '{"p":"1.5,1,16711680,user1","m":"JSON 弹幕"},'
          '{"p":"2.5,4,16777215,user2","m":"顶部弹幕"}'
          ']}';
      final r = parseDanmakuFile(json, fileName: 't.json');
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect(r.format, 'JSON');
      expect(r.items.length, 2);
      expect(r.items[0].color, 16711680,
          reason: '★ 4 段布局：颜色在 index 2');
      expect(r.items[0].text, 'JSON 弹幕');
      expect(r.items[1].mode, DanmakuMode.top,
          reason: '模式 4 = 顶部');
    });

    test('★ 容忍裸数组（部分工具导出）', () {
      const json = '[{"p":"1,1,16777215,u","m":"裸数组"}]';
      final r = parseDanmakuFile(json);
      expect(r.ok, isTrue);
      expect(r.items.length, 1);
    });

    test('★ JSON 语法错 ⇒ 明确报错', () {
      final r = parseDanmakuFile('{"comments":[}');
      expect(r.ok, isFalse);
      expect(r.error, contains('JSON'));
    });

    test('★ 没有 comments 字段 ⇒ 明确报错', () {
      final r = parseDanmakuFile('{"other":[]}');
      expect(r.ok, isFalse);
      expect(r.error, contains('comments'));
    });
  });

  group('★ 导入本地弹幕文件（ASS，尽力而为）', () {
    test('★ 提取 Dialogue 行 + 带 `\\move` 判为滚动', () {
      const ass = '[Script Info]\nTitle: t\n\n[Events]\n'
          'Format: Layer, Start, End, Style, Name, ML, MR, MV, Effect, Text\n'
          r'Dialogue: 0,0:00:01.50,0:00:06.00,Default,,0,0,0,,{\move(1920,100,-200,100)}滚动弹幕'
          '\n'
          r'Dialogue: 0,0:00:03.20,0:00:08.00,Default,,0,0,0,,{\pos(960,50)}固定弹幕'
          '\n';
      final r = parseDanmakuFile(ass, fileName: 't.ass');
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect(r.format, 'ASS');
      expect(r.items.length, 2);
      expect(r.items[0].text, '滚动弹幕',
          reason: '★ 必须剥掉 `{\\move(...)}` 样式标签');
      expect(r.items[0].mode, DanmakuMode.scroll);
      expect(r.items[1].mode, DanmakuMode.top,
          reason: '★ 没有 `\\move` ⇒ 按顶部固定');
      expect(r.items[0].timeMs, 1500, reason: '`0:00:01.50` = 1500ms');
    });

    test('★★ 文本含逗号不被截断（split 后要合并回文本）', () {
      const ass = '[Events]\n'
          r'Dialogue: 0,0:00:01.00,0:00:06.00,Default,,0,0,0,,待会儿见,朋友们'
          '\n';
      final r = parseDanmakuFile(ass);
      expect(r.items.first.text, '待会儿见,朋友们',
          reason: '★★ 文本里有逗号 —— 只 split 前 9 段再合并回文本');
    });
  });

  group('★★ 导入功能必须真的接线（防"死按钮"回归）', () {
    test('★★ 必须调 FilePicker（不是 debugPrint）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('FilePicker.pickFile'), isTrue,
          reason: '★★ 用户报障"这个导入本地弹幕文件好像点不开"——\n'
              '    原来只是 debugPrint（死按钮，违反 AGENTS §5.8）');
      // 反向：老的死按钮写法必须已消失
      expect(
          p.contains(
              "debugPrint('[PlayerFlow] 导入弹幕：待接 file_picker"),
          isFalse,
          reason: '★★ 死按钮的 debugPrint 必须删掉（不能留"配了没接线"的痕迹）');
    });

    test('★★ 用 file_picker 13.x 的**静态** API（不是 .platform）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('FilePicker.platform'), isFalse,
          reason: '★★ file_picker 13.x 是静态 API（`FilePicker.pickFile`），\n'
              '    旧版 `FilePicker.platform.pickFiles` 在 13.x 上不存在');
      expect(p.contains('readAsBytes'), isTrue,
          reason: '★ 13.x 没有 `withData`，字节要走 `readAsBytes()`');
    });

    test('★★ pubspec 必须有 file_picker', () {
      final y = File('pubspec.yaml').readAsStringSync();
      expect(y.contains('file_picker:'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════
  // ④ 连续滑条（字号 / 显示区域）
  // ══════════════════════════════════════════════════════════
  group('★★ 字号 / 显示区域改成连续滑条（用户要求"参考 B站"）', () {
    test('★★ 面板必须用 SliderRow（不是 SegmentedGroup）', () {
      final panel = code('lib/player/presentation/panels/'
          'player_danmaku_panel.dart');
      // 字号滑条
      expect(panel.contains("label: '字体大小'"), isTrue);
      // 显示区域滑条
      expect(panel.contains("label: '显示区域'"), isTrue);
      // 反向：字体大小**不该**再用 SegmentedGroup<DanmakuFontSize>
      expect(panel.contains('SegmentedGroup<DanmakuFontSize>'), isFalse,
          reason: '★★ 用户要求"字体大小也是可以拖动的"——\n'
              '    三档枚举必须换成滑条');
      // 类型选择仍在（改名为「弹幕类型」）
      expect(panel.contains("label: '弹幕类型'"), isTrue,
          reason: '★ 原「显示区域」标签语义错（取值是滚动/顶部/底部），\n'
              '    已改正为「弹幕类型」');
    });

    test('★★ 字号滑条范围 60–180（与 fontScale 0.6–1.8 一致）', () {
      final panel = code('lib/player/presentation/panels/'
          'player_danmaku_panel.dart');
      final i = panel.indexOf("label: '字体大小'");
      final seg = panel.substring(i, (i + 300).clamp(0, panel.length));
      expect(seg.contains('min: 60'), isTrue);
      expect(seg.contains('max: 180'), isTrue);
    });

    test('★★ 显示区域滑条下限必须 > 0（0 等于关闭弹幕，该用开关）', () {
      final panel = code('lib/player/presentation/panels/'
          'player_danmaku_panel.dart');
      final i = panel.indexOf("label: '显示区域'");
      final seg = panel.substring(i, (i + 300).clamp(0, panel.length));
      expect(seg.contains('min: 20'), isTrue,
          reason: '★ 显示区域 0 没有实用价值（等于没弹幕）——\n'
              '    那该用"弹幕开关"，不是把区域拖到 0');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ⑤ 不透明度 0 = 完全隐藏（修"为 0 时为全黑"）
  // ══════════════════════════════════════════════════════════
  group('★★ 不透明度 0 的语义（用户报障"为 0 时为全黑"）', () {
    test('★★ 描边必须乘 opacity（否则 0 时留轮廓）', () {
      final o = code('lib/danmaku/danmaku_overlay.dart');
      expect(o.contains('_strokePainterFor('), isTrue);
      // 反向：旧的固定 0xCC 描边必须消失
      expect(o.contains('const Color(0xCC000000)'), isFalse,
          reason: '★★ 用户报障的根因就是它：描边**固定 80% 不透明度**，\n'
              '    没乘 opacity ⇒ 不透明度 0 时填充透明了、\n'
              '    描边仍 80% ⇒ 满屏黑色/白色轮廓 = "为 0 时为全黑"');
      expect(o.contains('const Color(0xCCFFFFFF)'), isFalse);
      // 正向：必须与 opacity 相乘
      expect(o.contains('0.8 * opacity'), isTrue,
          reason: '★ 描边基色 0.8 必须乘用户 opacity，与填充同步淡出');
    });

    test('★★ 不透明度 ~0 时整层短路（不画）', () {
      final o = code('lib/danmaku/danmaku_overlay.dart');
      expect(o.contains('config.opacity <= 0.01'), isTrue,
          reason: '★★ B站 语义：不透明度 0 ⇒ 完全看不见。\n'
              '    双重保险：① 整层短路 ② 描边也淡出');
    });

    test('★★ 描边缓存 key 必须含 alpha（否则改了透明度仍命中旧缓存）', () {
      final o = code('lib/danmaku/danmaku_overlay.dart');
      // key 里已有 strokeColor.toARGB32() —— 那已包含 alpha，
      // 但要确认它**还在**（不能被"优化"掉）
      expect(o.contains('strokeColor.toARGB32()'), isTrue,
          reason: '★ key 必须含 alpha —— 否则拖动透明度滑条时\n'
              '    已缓存的弹幕仍用旧描边（"滑了没反应"）');
    });

    test('★★ opacityToConfig 必须允许 0（原来被夹到 0.2）', () {
      expect(DanmakuPanelState.opacityToConfig(0), 0.0,
          reason: '★★ 原来 `clamp(0.2, 1.0)` ⇒ 用户滑到 0 实际是 0.2，\n'
              '    与"0 = 看不见"的预期不符（B站 就是 0）');
      expect(DanmakuPanelState.opacityFromConfig(0), 0);
    });
  });

  // ══════════════════════════════════════════════════════════
  // ① 全部转简体
  // ══════════════════════════════════════════════════════════
  group('★★ 弹幕全部转简体（用户要求"识别匹配到的弹幕全部转为中文简体"）', () {
    test('★★ chConvert 默认必须是简体', () {
      const c = DanmakuConfig();
      expect(c.chConvert, DanmakuChConvert.simplified,
          reason: '★★ 默认必须是简体 —— 否则繁体弹幕直接显示');
    });

    test('★★ 请求必须带上 chConvert（配了要接线）', () {
      final client = code('lib/danmaku/danmaku_client.dart');
      expect(client.contains('chConvert'), isTrue,
          reason: '★★ 不带这个参数 ⇒ 服务端返回原文（可能繁体）');
      // 缓存 key 也要含它，否则切简繁后返回旧缓存
      expect(client.contains(r'$cv:'), isTrue,
          reason: '★ 缓存 key 必须含 chConvert —— 否则切简繁后拿到旧缓存');
    });
  });
}
