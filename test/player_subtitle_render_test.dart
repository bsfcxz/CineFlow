// 字幕显示通路守卫（真机报障："字幕还是没有显示出在画面中"）。
//
// ## 守护的完整链路（任一环断裂 = 用户看不到字幕）
// ```
//  [1] Media3 有 PgsParser（依赖齐）
//  [2] setSubtitleParserFactory 开启了内嵌字幕解析
//  [3] onCues 把 cue 上报原生 → Dart（emitCues）
//  [4] Dart 侧 kernel.cuesStream 暴露 cue
//  [5] 宿主订阅 + setState（带指纹去重）
//  [6] subtitleLayer 传进 PlayerPageSlots
//  [7] PlayerUiPage 真的把它叠进 Stack（且在弹幕之下）
//  [8] SubtitleOverlay 限制在**画面矩形**内（不能铺满屏）
//  [9] mpv 内核**不**走这条（否则画两遍）
// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cineflow/player/kernel.dart';

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
  group('★★★ 字幕显示链路（九个环节，缺一用户就看不到）', () {
    test('★★★ [1] 必须引 media3-exoplayer-hls（否则 Media3 打不开文件）', () {
      final g = File('android/app/build.gradle.kts').readAsStringSync();
      expect(g.contains('media3-exoplayer-hls'), isTrue,
          reason: '★★★ 真机取证：`ClassNotFoundException: '
              r'HlsMediaSource$Factory` at Media3Channel.open'
              '\n    ⇒ 切 Media3 后**黑屏 + 时长 00:00**。\n'
              '    `DefaultMediaSourceFactory` 按 MIME **反射**建 source，\n'
              '    编译期不报错、运行期才炸');
    });

    test('★★★ [2] 必须显式开启内嵌字幕解析', () {
      final k = code('android/app/src/main/kotlin/com/cineflow/app/'
          'player/Media3Channel.kt');
      expect(k.contains('setSubtitleParserFactory'), isTrue,
          reason: '★★★ Media3 1.4 起字幕处理**延迟到 SubtitleParser**；\n'
              '    不设 ⇒ 字幕轨**列得出来但不产出 cue**\n'
              '    （真机：面板 8 条字幕都在，画面里一条都没有）');
      // ⚠️ API 名不带 experimental 前缀（我按记忆写错过）
      expect(k.contains('experimentalSetSubtitleParserFactory'), isFalse,
          reason: '★★ 真实签名是 `setSubtitleParserFactory`（已用 javap\n'
              '    从 media3-exoplayer-1.4.1.aar 核实）——\n'
              '    `experimental` 前缀是我按记忆写错的，编译直接 Unresolved');
      expect(k.contains('DefaultSubtitleParserFactory'), isTrue,
          reason: '★ 用总厂（按 MIME 分派 PgsParser/SubripParser/…）');
    });

    test('★★★ [3] onCues 必须上报（否则 cue 烂在原生侧）', () {
      final k = code('android/app/src/main/kotlin/com/cineflow/app/'
          'player/Media3Channel.kt');
      expect(k.contains('override fun onCues('), isTrue,
          reason: '★★★ Media3 解析出 cue 后**等外部绘制**；\n'
              '    本项目不引 media3-ui（视频走 Flutter 纹理）⇒\n'
              '    不上报的话 cue 就烂在原生侧，画面永远空白');
      // 位图必须转 PNG（Cue.bitmap 是 android.graphics.Bitmap）
      expect(k.contains('CompressFormat.PNG'), isTrue,
          reason: '★ 跨 MethodChannel 只能传字节 ⇒ 位图转 base64 PNG');
      // 空 cue 也要发（清屏信号）
      expect(k.contains("put(\"type\", \"cues\")"), isTrue);
    });

    test('★★★ [4] Dart 侧必须暴露 cuesStream 并解析', () {
      final m = code('lib/player/media3/media3_kernel.dart');
      expect(m.contains("case 'cues':"), isTrue,
          reason: '★★★ 原生发了 cues 事件，Dart 不接就等于没发');
      expect(m.contains('Stream<List<SubtitleCue>> get cuesStream'), isTrue);
      expect(m.contains('base64Decode'), isTrue,
          reason: '★ 位图是 base64 PNG');
    });

    test('★★★ [5] 宿主必须订阅 + 去重', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('kernel.cuesStream.listen'), isTrue,
          reason: '★★★ 订了才有数据；不订则整条链路到此为止');
      expect(p.contains('_fingerprintOf'), isTrue,
          reason: '★★ PGS 逐帧发 cue，连续帧常相同 ——\n'
              '    不去重会每帧 setState 整页（控制层/面板全重算）');
    });

    test('★★★ [6][7] 层必须传进 slots 且真的叠进 Stack', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('subtitleLayer:'), isTrue,
          reason: '★★★ 传了宿主才画得出来');
      final ui = code('lib/player/presentation/player_ui_page.dart');
      expect(ui.contains('widget.slots.subtitleLayer'), isTrue,
          reason: '★★★ **slots 里定义了但没渲染 = 等于没做**\n'
              '    （本项目反复踩过"定义了不接线"的坑）');
    });

    test('★★★ [7b] 字幕必须在弹幕**之下**（次序）', () {
      final ui = code('lib/player/presentation/player_ui_page.dart');
      final iSub = ui.indexOf('widget.slots.subtitleLayer');
      final iDm = ui.indexOf('widget.slots.danmakuLayer');
      expect(iSub, greaterThanOrEqualTo(0));
      expect(iDm, greaterThanOrEqualTo(0));
      expect(iSub, lessThan(iDm),
          reason: '★★ Stack 中**后者在上** ⇒ 字幕必须先出现。\n'
              '    弹幕压字幕符合 B 站观感（且弹幕层已按 safeArea 避让字幕行）');
    });

    test('★★★ [8] 字幕层必须限制在**画面矩形**内', () {
      final s = code('lib/player/presentation/subtitle_overlay.dart');
      expect(s.contains('LayoutBuilder'), isTrue,
          reason: '★★★ 若铺满整屏，竖屏看 16:9 时字幕会飘在**上下黑边**上\n'
              '    （与弹幕层踩过的同一个坑）');
      expect(s.contains('IgnorePointer'), isTrue,
          reason: '★ 字幕层不能吃手势（否则挡掉控制层点击）');
    });

    test('★★★ [8b] 图形字幕必须按"构图平面→画面"映射（不能拉伸）', () {
      final s = code('lib/player/presentation/subtitle_overlay.dart');
      // PGS 位图是整幅构图平面（1920×1080，含大量透明区）
      expect(s.contains('vr.width / img.width'), isTrue,
          reason: '★★★ 必须按**视频区宽度**算缩放，并保持**位图自身**宽高比。\n'
              '    直接铺满（BoxFit.fill 到视频区）会在 2.39:1 宽银幕上\n'
              '    **竖直压扁字形** —— 正是 Media3 官方 SubtitleView 的已知缺陷');
    });

    test('★★★ [9] mpv 内核**不能**走这条路（否则画两遍）', () {
      final n = code('lib/player/native/native_kernel.dart');
      expect(n.contains('Stream<List<SubtitleCue>> get cuesStream'), isTrue);
      // mpv 的 cuesStream 必须是空流
      final i = n.indexOf('cuesStream');
      final seg = n.substring(i, (i + 200).clamp(0, n.length));
      expect(seg.contains('Stream.empty'), isTrue,
          reason: '★★★ mpv 把字幕画进**视频帧**（vo=gpu 的 OSD）⇒\n'
              '    纹理像素里已含字幕。再叠一层会**画两遍**（且有重影）');
    });
  });

  group('★ 中立模型 SubtitleCue', () {
    test('★ isEmpty 的语义（既无文本也无位图）', () {
      expect(const SubtitleCue().isEmpty, isTrue);
      expect(const SubtitleCue(text: '你好').isEmpty, isFalse);
      expect(const SubtitleCue(text: '').isEmpty, isTrue,
          reason: '★ 空串等于没内容（解析侧会过滤）');
    });
  });
}
