// "关闭字幕重复" + "选中了 PGS 却永远不显示" 的守卫测试。
//
// ## 两个真机报障
// > "字幕没有在播放画面中，字幕轨道的关闭字幕关闭字幕有两个都可以删除了。"
//
// ### ① 面板里两条「关闭字幕」
// `player_settings_panel.dart` 的字幕 Tab **自己渲染**一条
// `SubtitleTrack.off`；而 `player_flow_page.dart` 的 `setTracks([...])`
// **又插了一条** ⇒ 列表里两条。
//
// ### ② 选中了字幕却永远不显示（比"没选中"更难查）
// 真机取证：
// ```
// srv.sub idx=2 «Chinese Simplified (默认 PGSSUB)»
// [PlayerFlow] 字幕：自动选中 «简体中文» id=1     ← 选中的是 PGS
// [mpv/sub] Could not find subtitle decoder for format 'hdmv_pgs_subtitle'.
// ```
// 我们的 libmpv.so 缺 `ff_pgssub_decoder`，而**蓝光字幕 100% 是 PGS**
// ⇒ UI 显示"已勾选"但画面什么都没有。
// 根因：`autoPickSubtitle` 只按"中文优先"，**没先按可播性过滤**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/track_aligner.dart';

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
  // ① 关闭字幕不能重复
  // ══════════════════════════════════════════════════════════
  group('★★「关闭字幕」只能出现一条（真机报障：出现了两条）', () {
    test('★★ 宿主 setTracks 不得再插 "关闭字幕"', () {
      final p = code('lib/player/player_flow_page.dart');
      // 面板自己会渲染 SubtitleTrack.off ⇒ 宿主不能再插
      expect(p.contains("const SubtitleTrack(id: 'no', name: '关闭字幕')"),
          isFalse,
          reason: '★★ 面板的字幕 Tab 里**已经有一条**固定的\n'
              '    `SubtitleTrack.off`（`id: "no"`, `name: "关闭字幕"`）\n'
              '    ⇒ 宿主再插一条 ⇒ 面板里两条（真机截图取证）');
    });

    test('★★ 面板必须自己提供「关闭字幕」那一项', () {
      final p = code('lib/player/presentation/panels/player_settings_panel.dart');
      expect(p.contains('SubtitleTrack.off'), isTrue,
          reason: '★★ 删掉宿主那条之后，面板这条是**唯一**的关闭入口 ——\n'
              '    它必须存在，且 onTap 要传 null（→ 内核 `sid=no`）');
      final i = p.indexOf('SubtitleTrack.off');
      final seg = p.substring(i, (i + 400).clamp(0, p.length));
      expect(seg.contains('onSubtitleTrack(null)'), isTrue,
          reason: '★ `null` 经 `subtitle_controller` 转成 `off.id`(`no`)');
    });

    test('★★ 数据层只放真实轨道（职责分离）', () {
      final p = code('lib/player/player_flow_page.dart');
      final i = p.indexOf('subtitleStateProvider.notifier).setTracks');
      expect(i, greaterThanOrEqualTo(0));
      final seg = p.substring(i, (i + 500).clamp(0, p.length));
      expect(seg.contains('for (final s in alignedSub)'), isTrue,
          reason: '★ 「关闭字幕」不是数据（不是服务端/内核上报的轨道），\n'
              '    而是 UI 的一个动作 ⇒ 归面板拥有');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ② 选中前必须先按"可播性"过滤
  // ══════════════════════════════════════════════════════════
  group('★★ 自动选字幕：先可播、再中文（防"勾了却不显示"）', () {
    setUp(() => TrackAligner.runtimeUnsupportedSubtitleCodecs.clear());
    tearDown(() => TrackAligner.runtimeUnsupportedSubtitleCodecs.clear());

    test('★★ 运行时标记 PGS 不可用后，必须跳过它选文本字幕', () {
      // ## 语义（用户两次指正 "mpv 也能解码 PGS" 之后改的）
      // **不硬编码** PGS 不可播 —— mpv 上游与 Media3 都支持它。
      // 只有**运行时**（真机日志）证实解不了，才记入黑名单并跳过。
      //
      // 真机场景：8 条全 PGS ⇒ mpv 报 `Could not find subtitle decoder`
      // ⇒ 记入黑名单 ⇒ 本次会话后续应跳过 PGS、选文本字幕
      TrackAligner.markSubtitleCodecUnsupported('pgssub');
      final aligned = [
        const AlignedTrack(
            kernelId: '1', label: '简体中字', codec: 'pgssub'),
        const AlignedTrack(
            kernelId: '2', label: '简体中字', codec: 'subrip'),
      ];
      final pick = TrackAligner.autoPickSubtitle(
          aligned, codecOf: (t) => t.codec);
      expect(pick?.kernelId, '2',
          reason: '★★ 两条都叫"简体中字"，但第 1 条是 PGS（**已标记不可用**）\n'
              '    ⇒ 必须选第 2 条文本字幕。');
    });

    test('★★ 未标记时**放行** PGS（不硬编码 —— 上游支持）', () {
      final aligned = [
        const AlignedTrack(kernelId: '1', label: '简体中字', codec: 'pgssub'),
        const AlignedTrack(kernelId: '2', label: '英字', codec: 'subrip'),
      ];
      final pick = TrackAligner.autoPickSubtitle(
          aligned, codecOf: (t) => t.codec);
      expect(pick?.kernelId, '1',
          reason: '★★★ 没报过错 ⇒ PGS 应视为**可用**（中文优先）——\n'
              '    用户指正："mpv 也能解码哇"、"mpv 可以解码并显示 PGS"。\n'
              '    Media3 也有 `PgsParser` ⇒ 硬编码会让能用的片子被禁用');
    });

    test('★★ 全部已标记不可用 ⇒ 返回 null（不选，避免"勾了不显示"）', () {
      TrackAligner.markSubtitleCodecUnsupported('pgssub');
      final aligned = [
        const AlignedTrack(kernelId: '1', label: '简体中字', codec: 'pgssub'),
        const AlignedTrack(kernelId: '2', label: '繁体中文', codec: 'pgs'),
      ];
      final pick = TrackAligner.autoPickSubtitle(
          aligned, codecOf: (t) => t.codec);
      expect(pick, isNull,
          reason: '★★ 勾一条**已证实**显示不出来的轨，比不勾更让用户困惑');
    });

    test('★ 可播时仍优先中文（能力过滤后偏好才生效）', () {
      final aligned = [
        const AlignedTrack(kernelId: '1', label: 'English', codec: 'subrip'),
        const AlignedTrack(kernelId: '2', label: '简体中字', codec: 'ass'),
      ];
      final pick = TrackAligner.autoPickSubtitle(
          aligned, codecOf: (t) => t.codec);
      expect(pick?.kernelId, '2', reason: '★ 两条都可播 ⇒ 中文优先');
    });

    test('★ 不传 codecOf 时退化用轨道自带 codec（标记后才过滤）', () {
      // ★ 新语义：默认放行；**标记不可用后**才过滤
      TrackAligner.markSubtitleCodecUnsupported('pgssub');
      final aligned = [
        const AlignedTrack(kernelId: '1', label: '简体中字', codec: 'pgssub'),
        const AlignedTrack(kernelId: '2', label: '英字', codec: 'srt'),
      ];
      final pick = TrackAligner.autoPickSubtitle(aligned);
      expect(pick?.kernelId, '2',
          reason: '★ 不传 codecOf 也要能过滤（用 AlignedTrack.codec）');
    });

    test('★ codec 为 null 时保守允许（不误杀）', () {
      final aligned = [
        const AlignedTrack(kernelId: '1', label: '简体中字'), // codec 未知
      ];
      expect(TrackAligner.autoPickSubtitle(aligned)?.kernelId, '1',
          reason: '★ 不确定是否可播时应当允许（宁可让内核试）');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ③ 对齐必须带 codec（否则"可播性判断"永远失效）
  // ══════════════════════════════════════════════════════════
  group('★★ 字幕对齐必须带 codec（否则判断永远返回"可播"）', () {
    test('★★ alignSubtitle 必须传 serverCodecAt', () {
      final t = code('lib/player/track_aligner.dart');
      final i = t.indexOf('static List<AlignedTrack> alignSubtitle');
      expect(i, greaterThanOrEqualTo(0));
      final end = t.indexOf('/// **服务端没给默认字幕时', i);
      final seg = t.substring(i, end > i ? end : (i + 2000).clamp(0, t.length));
      expect(seg.contains('serverCodecAt'), isTrue,
          reason: '★★ `AlignedTrack.codec` **只由 serverCodecAt 填充**。\n'
              '    不传 ⇒ 字幕的 codec 恒为 null ⇒ `isSubtitleCodecLikelyPlayable`\n'
              '    永远返回 true ⇒ 仍然选中 PGS（真机二次报障）');
      expect(seg.contains('serverLanguageAt'), isTrue,
          reason: '★ 同语言回退也需要 language');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ④ 服务端默认字幕也要校验可播性
  // ══════════════════════════════════════════════════════════
  group('★★ 服务端指定的默认字幕也要校验可播性', () {
    test('★★ 不可播时要退到可播轨，而不是照单全收', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('wantPlayable'), isTrue,
          reason: '★★ 原来只写 `wantSub != null ? 用它 : autoPick`（没校验），\n'
              '    ⇒ 服务端指向 PGS 时就会**忠实选一条显示不出来的**');
      // 必须真的按可播性分支
      final i = p.indexOf('final wantPlayable');
      expect(i, greaterThanOrEqualTo(0));
      final seg = p.substring(i, (i + 500).clamp(0, p.length));
      expect(seg.contains('isSubtitleCodecLikelyPlayable'), isTrue);
    });

    test('★★ 全不可播必须告诉用户（不能静默）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('全部不可播'), isTrue,
          reason: '★★ 用户报"字幕没有在播放画面中"时**什么提示都没有** ——\n'
              '    必须明确说"这个片源的字幕格式内核解不了"');
      expect(p.contains('_surfaceMessage'), isTrue,
          reason: '★ 要有可见通路（不能只 debugPrint）');
    });

    test('★ 反查 codec 的兜底存在（旧对齐结果/启发式匹配）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('_serverCodecFor'), isTrue,
          reason: '★ `AlignedTrack.codec` 可能没填（走了启发式匹配）\n'
              '    ⇒ 按 serverIndex 反查一次');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ⑤ 预判：同类"勾了却不生效"的风险
  // ══════════════════════════════════════════════════════════
  group('★ 预判：能力过滤要覆盖"两条通路"', () {
    test('★★ 音频与字幕都必须有能力过滤（否则只修一半）', () {
      final p = code('lib/player/player_flow_page.dart');
      // 音频：pickPlayableAudio
      expect(p.contains('pickPlayableAudio'), isTrue,
          reason: '★ 音频要过滤（TRUEHD 无声就是这么修的）');
      // 字幕：wantPlayable + autoPickSubtitle
      expect(p.contains('wantPlayable'), isTrue,
          reason: '★ 字幕也要过滤 —— 否则"勾了不显示"（本轮报障）');
    });

    test('★ 提示通路必须共用（不要各处 showSnackBar）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('Future<void> _surfaceMessage'), isTrue,
          reason: '★ 复用同一条可见通路（内核错误流 + SnackBar）——\n'
              '    避免各调用点各写一份（且可能在 widget 未挂载时崩）');
      expect(p.contains('if (!mounted) return;'), isTrue);
    });
  });
}
