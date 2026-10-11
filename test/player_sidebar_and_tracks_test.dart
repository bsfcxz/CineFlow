// 侧边栏 280dp + 半透明 + **轨道解析容错** 的守卫测试。
//
// ## 本轮修的最重要 bug（用户报障）
// > "播放吞噬星空剧场版时 cinflow 没有识别到这个视频的音频，
// >  它其实上有三个音频编码"
// > "播放复仇者联盟时它也没有识别出字幕，正常这个是有多个字幕的"
//
// **根因（真机取证）**：`parseTracks` 把整个 for 循环包在一个 `try` 里，
// 任一条轨道取值抛异常 ⇒ **整个列表变成空**。
// 真机证据（《复仇者联盟》MKV，16 条轨道）：
// ```
// [Kernel] track-list 事件：长度=16 → 解析出 音频0/字幕0   ← 全空
// ```
// 而 mpv 侧有 `Audio --aid=1` + 13 条 `Subs --sid=*`，
// 服务端也有 6 音频 / 8 字幕 ⇒ 是**解析**吃掉的。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/domain/player_constants.dart';
import 'package:cineflow/player/kernel_event_parser.dart';

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
  // ★★ 轨道解析容错（本轮最关键的修复）
  // ══════════════════════════════════════════════════════════
  group('★★ 轨道解析必须逐条兜底（防"看不到音轨/字幕"）', () {
    test('★★ 一条坏轨道不能毁掉整个列表', () {
      // 真实 mpv track-list 形状（取自真机日志）
      final data = <Map<String, dynamic>>[
        {
          'id': 1.0,
          'type': 'video',
          'ff-index': 0.0,
          'codec': 'hevc',
        },
        {
          'id': 1.0,
          'type': 'audio',
          'ff-index': 1.0,
          'codec': 'eac3',
          'demux-channels': 6.0,
          'title': 'Mandarin [Original]',
          'lang': 'chi',
        },
        // ★ 这条的 `demux-channels` 是**字符串**（服务端/内核类型不保证）
        //   ⇒ 老实现 `(t['demux-channels'] as num?)` 会抛 TypeError
        //   ⇒ 整个列表被 catch 成空
        {
          'id': 2.0,
          'type': 'audio',
          'ff-index': 2.0,
          'codec': 'dts',
          'demux-channels': '8',
        },
        {
          'id': 1.0,
          'type': 'sub',
          'ff-index': 3.0,
          'title': 'Simplified Chinese',
          'lang': 'chi',
        },
      ];
      final r = KernelEventParser.parseTracks(data);
      expect(r.audio.length, 2,
          reason: '★★ 坏的只是第 3 条（demux-channels 是字符串）——\n'
              '    但**其余两条必须保留**。老实现会返回 0 条。');
      expect(r.subtitle.length, 1);
      // 字符串数字也要解析出来（宽容转换）
      expect(r.audio[1].channels, 8,
          reason: '★ `"8"` 应解析成 8（不是 null、不是抛异常）');
    });

    test('★★ 数字型 title/lang 不能崩（服务端可能给 lang: 0）', () {
      final data = <Map<String, dynamic>>[
        {'id': 1.0, 'type': 'audio', 'lang': 0, 'title': 123, 'codec': 5},
        {'id': 1.0, 'type': 'sub', 'ff-index': 2.0},
      ];
      final r = KernelEventParser.parseTracks(data);
      expect(r.audio.length, 1, reason: '★★ 不能因为字段类型怪就丢掉整条');
      expect(r.subtitle.length, 1);
      expect(r.audio.first.language, '0', reason: '数字应宽容转成字符串');
      expect(r.audio.first.title, '123');
    });

    test('★ 形状不对时返回空（不崩）', () {
      expect(KernelEventParser.parseTracks(null).audio, isEmpty);
      expect(KernelEventParser.parseTracks('not json').audio, isEmpty);
      expect(KernelEventParser.parseTracks(<int>[1, 2]).audio, isEmpty);
      expect(KernelEventParser.parseTracks(const {}).audio, isEmpty);
    });

    test('★ 空列表安全', () {
      final r = KernelEventParser.parseTracks(const []);
      expect(r.audio, isEmpty);
      expect(r.subtitle, isEmpty);
    });

    test('★★ 解析必须**逐条** try（不是整个循环包一个 try）', () {
      final p = code('lib/player/kernel_event_parser.dart');
      final i = p.indexOf('static KernelTracks parseTracks');
      expect(i, greaterThanOrEqualTo(0));
      final end = p.indexOf('static Object? _tryDecode', i);
      final seg = p.substring(i, end > i ? end : (i + 2600).clamp(0, p.length));
      final forIdx = seg.indexOf('for (final t in');
      expect(forIdx, greaterThanOrEqualTo(0), reason: '找不到 for');
      final afterFor = seg.substring(forIdx);
      final tryIdx = afterFor.indexOf('try {');
      expect(tryIdx, greaterThanOrEqualTo(0), reason: 'for 内没有 try');
      // ★★ 关键：catch **不得 rethrow**（那等于没有逐条兜底）
      //
      // 注入实测抓到我第一版断言太弱：把 catch 体改成 `rethrow;`
      // 仍然满足"for 内有 try" ⇒ 测试全绿。必须断言 catch 的**行为**。
      final catchIdx = afterFor.indexOf('catch (', tryIdx);
      expect(catchIdx, greaterThanOrEqualTo(0), reason: 'try 后没有 catch');
      final catchBody = afterFor.substring(
          catchIdx, (catchIdx + 400).clamp(0, afterFor.length));
      expect(catchBody.contains('rethrow'), isFalse,
          reason: '★★ catch **不得 rethrow** —— 那等于没有逐条兜底\n'
              '    （一条坏轨仍会冒泡出去、整列表变空，即原 bug）');
      // 而且必须有"跳过该条、继续循环"的证据（debugPrint 或 add 之前的 continue）
      expect(catchBody.contains('debugPrint'), isTrue,
          reason: '★ 丢弃的坏轨要留下可查证据（否则无声丢数据）');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 侧边栏宽度 280dp
  // ══════════════════════════════════════════════════════════
  group('★★ 侧边栏宽度统一 280dp（用户要求）', () {
    test('★★ 基准值就是 280（对齐 Material NavigationDrawer）', () {
      expect(PlayerPanels.panelBaseWidth, 280,
          reason: '★ 用户指出"网上说 280dp 这个宽度不错" ——\n'
              '    核实后认同：Material 的 NavigationDrawer 规范宽度即 280dp');
    });

    test('★★ 典型屏宽下的取值', () {
      expect(PlayerPanels.panelWidth(393), 280);   // 手机竖屏
      expect(PlayerPanels.panelWidth(873), 280);   // 手机横屏
      expect(PlayerPanels.panelWidth(1200), 280);  // 平板/大屏
    });

    test('★★ 窄屏必须有 85% 钳制（否则 320dp 屏上占 88%）', () {
      expect(PlayerPanels.panelMaxScreenRatio, 0.85);
      expect(PlayerPanels.panelWidth(320), closeTo(272, 0.1));
      // 极窄屏仍不越界
      expect(PlayerPanels.panelWidth(200), closeTo(170, 0.1));
    });

    test('★ 退化输入不崩、不产生负宽', () {
      expect(PlayerPanels.panelWidth(0), 280);
      expect(PlayerPanels.panelWidth(-100), 280);
    });

    test('★★ 旧的"按方向两套比例"必须已删除', () {
      final c = code('lib/player/domain/player_constants.dart');
      for (final gone in [
        'settingsWidthRatio',
        'settingsMaxWidthLandscape',
        'playlistWidthRatioLandscape',
      ]) {
        expect(c.contains(gone), isFalse,
            reason: '★★ `$gone` 应已删除 —— 统一 280dp 后不再需要\n'
                '    按方向分两套比例（少一处可能不同步的数学）');
      }
    });

    test('★★ 三个面板（设置/弹幕/列表）必须同宽', () {
      final c = code('lib/player/domain/player_constants.dart');
      // ⚠️ 不要断言"精确的换行/空格"（实测过：实现写成一行时断言就失效）——
      //    断言**语义**：两个函数都转调 panelWidth。
      final re = RegExp(
          r'static double (settings|playlist)Width\(double screenWidth\) =>\s*'
          r'panelWidth\(screenWidth\);');
      expect(re.allMatches(c).length, 2,
          reason: '★ 播放列表与设置**同宽**（都转调 panelWidth）——\n'
              '    原来列表更窄（340/0.8），长剧名在窄面板里被截断');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 半透明侧边栏
  // ══════════════════════════════════════════════════════════
  group('★★ 侧边栏**完全透明**（用户最新要求）', () {
    test('★★★ panelBg 必须完全透明', () {
      final t = code('lib/player/presentation/player_ui_tokens.dart');
      // ★ 演变：0xF2(95%) → 0xD9(85%) → **transparent**（用户逐次要求）
      expect(t.contains('static const Color panelBg = Colors.transparent;'),
          isTrue,
          reason: '★★★ 用户要求："侧边栏全都改成透明的"\n'
              '    历程：0xF2(95%，与纯色无异) → 0xD9(85%，半透明)\n'
              '          → transparent（本轮）');
    });

    test('★★★ 完全透明后**必须**有文字阴影（否则不可读）', () {
      final t = code('lib/player/presentation/player_ui_tokens.dart');
      expect(t.contains('panelTextShadows'), isTrue,
          reason: '★★★ 去掉底色后，12–14px 纯色文字压在**视频像素**上：\n'
              '    亮画面（雪景/白墙）→ 白字完全看不见。\n'
              '    这是可用性问题，不是审美问题。');
      // 双层阴影（近距紧 + 远距散）
      final i = t.indexOf('panelTextShadows');
      final seg = t.substring(i, (i + 260).clamp(0, t.length));
      expect(RegExp(r'Shadow\(').allMatches(seg).length,
          greaterThanOrEqualTo(2),
          reason: '★ 单层阴影在中等亮度背景上最差（既压不住又盖不住）\n'
              '    ⇒ 双层（近距 + 远距），与 overlayIconShadows 同款配方');
    });

    test('★★★ 宿主必须真的施加文字阴影（否则定义了没用）', () {
      final h = File('lib/player/presentation/panels/player_panel_host.dart')
          .readAsStringSync();
      expect(h.contains('panelTextShadows'), isTrue,
          reason: '★★★ 定义了不施加 ⇒ 面板文字在亮画面上仍然看不见');
      expect(h.contains('DefaultTextStyle.merge'), isTrue,
          reason: '★★ 用 `merge` 在**树根**统一施加（含 SettingRow/\n'
              '    SliderRow/SegmentedGroup 等复用组件，以及将来新增的）\n'
              '    —— 逐处改必然漏掉几个');
    });

    test('★★ 遮罩必须够淡（否则透明面板看起来仍是黑板）', () {
      final t = code('lib/player/presentation/player_ui_tokens.dart');
      final m = RegExp(r'panelMask = Color\(0x([0-9A-Fa-f]{8})\)').firstMatch(t);
      expect(m, isNotNull, reason: '★ panelMask 要显式 ARGB');
      final argb = int.parse(m!.group(1)!, radix: 16);
      final alpha = (argb >> 24) & 0xFF;
      expect(alpha, lessThan(0x66),
          reason: '★ 面板已完全透明 ⇒ 遮罩若仍 38%（0x61）\n'
              '    面板区看起来还是一块压暗的板，"透明"就没意义了。\n'
              '    24%（0x3D）是实测取舍：够压住亮区让白字可读，\n'
              '    又明显能看出后面是视频');
      expect(alpha, greaterThan(0x20),
          reason: '★ 也不能几乎为 0 —— 那样面板区与周围画面无区别，\n'
              '    用户不知道"抽屉在哪"');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 外挂字幕（自查 Emby API 补的缺口）
  // ══════════════════════════════════════════════════════════
  group('★★ 外挂字幕（Emby IsExternal）', () {
    test('★★ 内核接口必须有 addExternalSubtitle', () {
      final k = code('lib/player/kernel.dart');
      expect(k.contains('Future<bool> addExternalSubtitle('), isTrue,
          reason: '★★ Emby 外挂字幕**不在容器里** ⇒ 内核的 track-list\n'
              '    看不到它们 ⇒ 必须由 App 主动加载（mpv: sub-add）。');
      expect(k.contains('Future<void> removeExternalSubtitles()'), isTrue,
          reason: '★ 换集要清理，否则上一集的字幕串到下一集');
    });

    test('★★ 接口被删/改名时宿主会编译失败（接口是硬约束）', () {
      // ## 为什么要单独守这条（注入实测的教训）
      // 把接口改名为 `removedX` 会让**实现方编译错**（err=4）
      // ⇒ 注入脚本按规则记作"编译错（不计）"，守卫无法以"变红"形式证明自己。
      //
      // 但**接口存在性本身**仍由上一个测试保证（`contains` 断言）。
      // 本条额外确认：**实现方的 override 与接口同名**
      // （否则 Dart 会报 missing concrete implementation）。
      for (final f in [
        'lib/player/native/native_kernel.dart',
        'lib/player/media3/media3_kernel.dart',
      ]) {
        final s = code(f);
        final i = s.indexOf('Future<bool> addExternalSubtitle(');
        expect(i, greaterThanOrEqualTo(0), reason: '$f 缺实现');
        // override 注解必须在它前面不远处
        final before = s.substring((i - 60).clamp(0, i), i);
        expect(before.contains('@override'), isTrue,
            reason: '★ $f 的实现必须有 @override（否则接口对不上）');
      }
    });

    test('★★ 两个内核都要实现', () {
      for (final f in [
        'lib/player/native/native_kernel.dart',
        'lib/player/media3/media3_kernel.dart',
      ]) {
        final s = code(f);
        expect(s.contains('Future<bool> addExternalSubtitle('), isTrue,
            reason: '$f 缺外挂字幕实现 ⇒ 该内核下外挂字幕永远看不到');
      }
    });

    test('★★ mpv 必须用 `sub-add` 命令', () {
      final n = code('lib/player/native/native_kernel.dart');
      expect(n.contains("'sub-add'"), isTrue,
          reason: '★★ mpv 加载外挂字幕的唯一方式是 `sub-add` 命令');
      expect(n.contains("'sub-remove'"), isTrue);
    });

    test('★★ 宿主必须真的调用（否则是死代码）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('_loadExternalSubtitles'), isTrue);
      expect(p.contains('addExternalSubtitle('), isTrue,
          reason: '★★ 只定义不调用 ⇒ 外挂字幕永远加载不了');
      // 至少两个调用点（主起播 + 换集）
      expect(RegExp(r'_loadExternalSubtitles\(launch\)').allMatches(p).length,
          greaterThanOrEqualTo(2),
          reason: '★ 主起播与换集**两条路径**都要加载');
    });

    test('★★ 外挂字幕的 url 绝不能进日志（安全红线）', () {
      for (final f in [
        'lib/player/native/native_kernel.dart',
        'lib/player/media3/media3_kernel.dart',
      ]) {
        final s = code(f);
        final i = s.indexOf('Future<bool> addExternalSubtitle(');
        expect(i, greaterThanOrEqualTo(0));
        final seg = s.substring(i, (i + 900).clamp(0, s.length));
        // 日志里不能出现 url 变量
        expect(RegExp(r'debugPrint\([^)]*\$url').hasMatch(seg), isFalse,
            reason: '★★ `DeliveryUrl` 含 api_key ⇒ 打日志 = 凭据泄露\n'
                '    （AGENTS §安全红线最高优先级）');
        expect(seg.contains('不打印'), isTrue,
            reason: '★ 要有明确注释说明"为何不打 url"');
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  // MediaSource 版本标签（用户要的"多大小多画质可选"）
  // ══════════════════════════════════════════════════════════
  group('★★ 版本选择要能区分画质/大小', () {
    test('★★ 必须有 fullVersionLabel（不能只用 versionLabel）', () {
      final m = code('lib/data/models.dart');
      expect(m.contains('String get fullVersionLabel'), isTrue,
          reason: '★★ 服务端给的 `Name` 常为空或重复（实测三路源全 null）\n'
              '    ⇒ 只用 versionLabel 会显示三行"默认版本"，无法选择');
    });

    test('★★ 版本选择 UI 必须用 fullVersionLabel', () {
      final d = code('lib/pages/detail_page.dart');
      expect(d.contains('m.fullVersionLabel'), isTrue,
          reason: '★ 详情页的版本 chip 要用新标签');
      // ⚠️ 用字符串拼接而不是插值 —— 源码里的 `${...}` 在测试里
      //    会被当成"测试自己的变量"（实测踩到：`d.mediaSources` 未定义）
      expect(d.contains(r'版本（${d.mediaSources.length} 路可选）'), isTrue,
          reason: '★ 标题带条数 —— 否则用户不知有几路可选（还要横向滚才发现）');
    });

    test('★ 必须有 bitrateLabel（辅助判断画质）', () {
      final m = code('lib/data/models.dart');
      expect(m.contains('String get bitrateLabel'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════
  // DeliveryUrl 解析
  // ══════════════════════════════════════════════════════════
  group('★ MediaStream 必须解析 DeliveryUrl', () {
    test('★★ DeliveryUrl / IsExternal 都要解析', () {
      final m = code('lib/data/models.dart');
      expect(m.contains("deliveryUrl: j['DeliveryUrl'] as String?"), isTrue,
          reason: '★ 不解析 DeliveryUrl ⇒ 外挂字幕没有直链可用');
      expect(m.contains("isExternal: j['IsExternal'] == true"), isTrue);
    });

    test('★ 文件名从 Path 提取（Windows/Unix 分隔符都处理）', () {
      final m = code('lib/data/models.dart');
      expect(m.contains('_fileNameOf'), isTrue);
      expect(m.contains("replaceAll('\\\\', '/')"), isTrue,
          reason: '★ Emby 的 Path 可能是 Windows 风格（反斜杠）');
    });
  });
}
