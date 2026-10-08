/// **双内核自动适配：HDR / 杜比视界规则**的回归防线。
///
/// ## 来源
/// 参考 `zzzwannasleep/LinPlayer` 的架构思路（该仓库 **LICENSE 34,525 字节
/// = AGPL-3.0**，**只提取思路、未抄任何代码** —— 见 AGENTS §6.8/§10.6）。
///
/// 其能力表原文：
/// ```
/// | mpv 播放内核       | 全格式；HDR / 杜比视界自动切软解；PGS/SUP 图形字幕 |
/// | ExoPlayer 第二内核  | 安卓专有，可在设置里切换                          |
/// ```
///
/// ## 借鉴的**原理**（不是照搬结论）
/// **杜比视界在安卓硬解路径上普遍失败或降级**：
/// · MediaCodec 的 DV 支持**依设备/厂商而异** —— 多数机器只解出"基础层"
///   （画面发灰/偏暗），少数直接解不了
/// · mpv 在 `hwdec=no` 时有**软件回退 + tone-mapping**
/// ⇒ **画面正确 > 性能**（与本仓既有的"冷门格式优先 mpv"同一条原则）
///
/// ## 修之前的状态（真实缺口）
/// · `MediaStream.videoRange`（`SDR`/`HDR10`/`DOVI`）**数据层早就解析了**
///   （`models.dart:538`）
/// · 但 `traitsFromLaunch` **从没读它** ⇒ HDR 信息**从未进入内核决策**
/// · `MediaTraits` 也没有 hdr/dv 字段
/// ⇒ 这是个"数据有、接线断"的缺口（与本仓 `episodeLabel` 那次同源）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/kernel_auto_select.dart';
import 'package:cineflow/player/kernel_factory.dart';

/// 造一个"普通 4K HDR 片源"。
MediaTraits _traits({
  String? videoRange,
  int? height = 2160,
  String? container = 'mkv',
  String? videoCodec = 'hevc',
  bool isHls = false,
  bool isTranscoding = false,
}) =>
    MediaTraits(
      path: '/media/movie.mkv',
      container: container,
      videoCodec: videoCodec,
      width: 3840,
      height: height,
      isHls: isHls,
      isTranscoding: isTranscoding,
      videoRange: videoRange,
    );

void main() {
  group('★ HDR / 杜比视界 → 走 mpv（借鉴 LinPlayer 思路）', () {
    // ---- 字段与判定的正确性 ----
    test('DOVI / DolbyVision 应被识别为杜比视界', () {
      expect(_traits(videoRange: 'DOVI').isDolbyVision, isTrue);
      expect(_traits(videoRange: 'DolbyVision').isDolbyVision, isTrue);
      expect(_traits(videoRange: 'dovi').isDolbyVision, isTrue,
          reason: '大小写不敏感（服务端字段大小写不保证）');
      expect(_traits(videoRange: 'SDR').isDolbyVision, isFalse);
    });

    test('HDR10 / HLG 应被识别为 HDR（非 DV）', () {
      expect(_traits(videoRange: 'HDR10').isHdr, isTrue);
      expect(_traits(videoRange: 'HDR10').isDolbyVision, isFalse);
      expect(_traits(videoRange: 'HLG').isHdr, isTrue);
      expect(_traits(videoRange: 'SDR').isHdr, isFalse);
    });

    test('DV 必然也是 HDR（子集关系）', () {
      expect(_traits(videoRange: 'DOVI').isHdr, isTrue,
          reason: '杜比视界是 HDR 的一种 —— isHdr 应包含 DV');
    });

    test('videoRange 缺失时不误判', () {
      final t = _traits(videoRange: null);
      expect(t.isHdr, isFalse);
      expect(t.isDolbyVision, isFalse,
          reason: '元数据缺失不能当成 HDR（否则会把普通片源全判成 mpv）');
    });

    // ---- 决策行为（★ 核心）----
    test('★ 杜比视界片源 → mpv（即使它也是 4K）', () {
      // 4K 本来命中"规则 3 → Media3"，但规则 0（HDR）优先级更高
      final d = KernelAutoSelect.select(_traits(videoRange: 'DOVI'));
      expect(d.kernel, KernelType.mpv,
          reason: '★ DV 走硬解（Media3）在多数机型上会得到错误画面\n'
              '    （只解基础层 → 发灰偏暗，或直接解不了）。\n'
              '    mpv 有软件回退 + tone-mapping ⇒ 宁可软解。');
      expect(d.reason, contains('杜比视界'));
    });

    test('★ HDR10 片源 → mpv（色调映射交给 mpv）', () {
      final d = KernelAutoSelect.select(_traits(videoRange: 'HDR10'));
      expect(d.kernel, KernelType.mpv);
      expect(d.reason, contains('HDR'));
    });

    test('★ HDR 规则优先于 HLS 规则', () {
      // HLS 本来命中"规则 1 → Media3"，但 HDR 优先级更高
      final d = KernelAutoSelect.select(
          _traits(videoRange: 'DOVI', isHls: true));
      expect(d.kernel, KernelType.mpv,
          reason: '★ DV 片源即使走 HLS 也应优先 mpv ——\n'
              '    **画面正确 > 传输方式的体验优化**。');
    });

    test('SDR 片源不受影响（仍按原规则走）', () {
      // SDR 4K → 规则 3 → Media3（原行为不变）
      expect(KernelAutoSelect.select(_traits(videoRange: 'SDR')).kernel,
          KernelType.media3);
      // SDR HLS → 规则 1 → Media3（原行为不变）
      expect(
          KernelAutoSelect.select(
              _traits(videoRange: 'SDR', isHls: true, height: 1080)).kernel,
          KernelType.media3);
    });

    test('无 videoRange 的 4K 片源仍走 Media3（不误伤）', () {
      final d = KernelAutoSelect.select(_traits(videoRange: null));
      expect(d.kernel, KernelType.media3,
          reason: '元数据缺失 ≠ HDR。缺字段时不能把所有 4K 都推给 mpv。');
    });

    test('用户显式指定内核时，HDR 规则不得覆盖', () {
      final d = KernelAutoSelect.select(
        _traits(videoRange: 'DOVI'),
        preference: KernelPreference.media3,
      );
      expect(d.kernel, KernelType.media3,
          reason: '用户显式选了 Media3 就该听用户的 ——\n'
              '自动规则不能"聪明"地覆盖显式选择。');
    });
  });
}
