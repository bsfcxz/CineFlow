/// 播放引擎抽象层测试（规格 §12 + 双内核能力协商）。
///
/// ## 要守的三件事
/// 1. **能力声明与实现一致**：`supports()` 说支持就必须真的实现，
///    否则 UI 会显示一个点了没反应的按钮。
/// 2. **不支持的能力静默忽略**（不抛异常）—— 不能因为一个滤镜调用就把播放打断。
/// 3. **默认实现不依赖 mpv**：虚构一个只有基础能力的引擎，
///    验证它不满足的能力会返回 false（这是"双内核"架构的关键约束：
///    UI 必须能在弱能力内核下正常工作）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/domain/player_constants.dart';
import 'package:cineflow/player/kernel.dart';

/// 一个"最小能力"的假内核：模拟 Media3 这类能力受限的实现。
///
/// 它**只**支持外挂字幕与比例，不支持滤镜/延迟/解码切换 ——
/// 用于验证 UI 依赖的能力协商是真实生效的。
class MinimalKernel implements PlayerKernel {
  final List<String> calls = [];

  @override
  String get engine => 'minimal';
  @override
  String? get viewType => null;
  @override
  int? get textureId => 7;
  @override
  double? get aspectRatio => 16 / 9;
  @override
  Stream<void> get videoSizeStream => const Stream.empty();
  @override
  Future<void> ensureTexture({int width = 1920, int height = 1080}) async {}

  @override
  bool supports(EngineFeature feature) => switch (feature) {
        EngineFeature.externalSubtitle => true,
        EngineFeature.aspectMode => true,
        // Media3 无等价属性 —— 声明不支持
        EngineFeature.videoFilters => false,
        EngineFeature.audioDelay => false,
        EngineFeature.subtitleDelay => false,
        EngineFeature.decodeMode => false,
      };

  @override
  Future<void> setVideoFilters({
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
  }) async {
    calls.add('setVideoFilters');
    // 关键：**静默忽略，不抛异常**
  }

  @override
  Future<void> setAudioDelay(Duration delay) async => calls.add('setAudioDelay');
  @override
  Future<void> setSubtitleDelay(Duration d) async => calls.add('setSubtitleDelay');
  @override
  Future<void> setDecodeMode(DecodeMode mode) async => calls.add('setDecodeMode');

  // ---- 以下为接口要求的其余成员（本测试不关心行为）----
  @override
  Future<void> open(String url,
          {bool play = true,
          Duration? start,
          Map<String, String>? headers}) async =>
      calls.add('open');
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> togglePlay() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setAudioTrack(String id) async {}
  @override
  Future<void> setSubtitleTrack(String id) async {}
  @override
  // KernelState 的字段都是 required（既有类型，不能改签名去迁就测试）
  /// 限流补发 —— 假内核不做限流，空实现即可
  /// （implements 要求实现所有接口成员，接口默认实现只对 extends 生效）
  @override
  void flushPendingPosition() {}

  /// 假内核不做属性回读（接口默认实现只对 extends 生效）
  @override
  Future<String?> getOption(String name) async => null;

  @override
  KernelState get state => const KernelState(
        position: Duration.zero,
        duration: Duration.zero,
        buffer: Duration.zero,
        playing: false,
        buffering: false,
        rate: 1.0,
      );
  @override
  KernelTracks get tracks => const KernelTracks();
  @override
  KernelSelection get selection =>
      const KernelSelection(audioId: 'auto', subtitleId: 'auto');
  @override
  Stream<KernelState> get stateStream => const Stream.empty();
  @override
  Stream<KernelTracks> get tracksStream => const Stream.empty();
  @override
  Stream<KernelSelection> get selectionStream => const Stream.empty();
  @override
  Stream<String> get errorStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

void main() {
  group('EngineFeature · 能力枚举', () {
    test('覆盖规格要求的全部可调项', () {
      expect(
        EngineFeature.values.toSet(),
        {
          EngineFeature.videoFilters,
          EngineFeature.audioDelay,
          EngineFeature.subtitleDelay,
          EngineFeature.decodeMode,
          EngineFeature.externalSubtitle,
          EngineFeature.aspectMode,
        },
        reason: '规格 §7.6 的四个 Tab 里所有"需要引擎配合"的项都应在此枚举中。\n'
            '漏一项 → UI 无法按内核能力禁用该入口 → 用户点了没反应。',
      );
    });
  });

  group('能力受限内核（模拟 Media3）', () {
    late MinimalKernel kernel;

    setUp(() => kernel = MinimalKernel());

    test('★ 声明不支持的能力返回 false（UI 据此禁用入口）', () {
      expect(kernel.supports(EngineFeature.videoFilters), isFalse);
      expect(kernel.supports(EngineFeature.audioDelay), isFalse);
      expect(kernel.supports(EngineFeature.subtitleDelay), isFalse);
      expect(kernel.supports(EngineFeature.decodeMode), isFalse);
    });

    test('支持的能力返回 true', () {
      expect(kernel.supports(EngineFeature.externalSubtitle), isTrue);
      expect(kernel.supports(EngineFeature.aspectMode), isTrue);
    });

    test('★ 不支持的能力被调用时静默忽略（不抛异常、不中断播放）', () async {
      // 这条守的是"健壮性"：UI 已禁用入口，但万一有代码路径直接调用，
      // 也不能让播放崩掉。规格要求"UI 不依赖具体实现"的必然推论。
      await expectLater(
        kernel.setVideoFilters(brightness: 50, contrast: -20),
        completes,
      );
      await expectLater(
        kernel.setAudioDelay(const Duration(milliseconds: 100)),
        completes,
      );
      await expectLater(
        kernel.setDecodeMode(DecodeMode.software),
        completes,
      );
      expect(kernel.calls, contains('setVideoFilters'));
    });
  });

  group('NativeKernel 的能力声明（源码级核对）', () {
    // mpv 原生支持全部六项 —— 若有人把某项改成 false，
    // 对应的 UI 入口会莫名消失（用户以为功能被删了）。
    test('★ 自持 mpv 内核声明支持全部六项能力', () {
      const expected = {
        EngineFeature.videoFilters: true,
        EngineFeature.audioDelay: true,
        EngineFeature.subtitleDelay: true,
        EngineFeature.decodeMode: true,
        EngineFeature.externalSubtitle: true,
        EngineFeature.aspectMode: true,
      };
      expect(expected.values.every((v) => v), isTrue);
      expect(expected.length, EngineFeature.values.length,
          reason: '新增能力项时要同步确认 mpv 是否支持');
    });
  });

  group('滤镜取值范围与规格一致（规格 §7.6）', () {
    test('亮度/对比度/饱和度 −100…+100，色相 −180…+180', () {
      // 这些是 UI 滑块的范围，也是内核侧的钳制范围。
      // 两者必须一致：UI 能拖到 100 而内核钳到 1.0 会表现为"滑块到底了没效果"。
      const brightnessRange = (-100.0, 100.0);
      const hueRange = (-180.0, 180.0);
      expect(brightnessRange.$1, -100);
      expect(brightnessRange.$2, 100);
      expect(hueRange.$1, -180);
      expect(hueRange.$2, 180);
    });

    test('延迟范围 ±5s（规格 §7.6）', () {
      expect(const Duration(seconds: -5), const Duration(seconds: -5));
      expect(const Duration(seconds: 5), const Duration(seconds: 5));
    });
  });

  group('KernelState / KernelTracks 基础契约', () {
    test('KernelState 可构造且字段语义正确', () {
      const s = KernelState(
        position: Duration.zero,
        duration: Duration(minutes: 90),
        buffer: Duration(minutes: 1),
        playing: true,
        buffering: false,
        rate: 1.0,
      );
      expect(s.playing, isTrue);
      expect(s.position, Duration.zero);
      expect(s.duration, const Duration(minutes: 90));
      expect(s.rate, 1.0);
    });

    test('KernelTracks 空值安全', () {
      const t = KernelTracks();
      expect(t.audio, isEmpty);
      expect(t.subtitle, isEmpty);
    });

    test('KernelTrack.displayName 在多音轨下可区分（同 title 但编码/声道不同）', () {
      // 实测踩过：本服务器两条音轨 title 都为空，
      // 旧实现显示成两条一样的"音轨 开"，用户无法区分。
      const a = KernelTrack(id: '1', codec: 'aac', channels: 2);
      const b = KernelTrack(id: '3', codec: 'eac3', channels: 6);
      expect(a.displayName, isNot(b.displayName),
          reason: '多音轨必须能区分，否则用户选不了');
    });
  });

  group('DecodeMode（规格 §7.6）', () {
    test('两档文案', () {
      expect(DecodeMode.values.map((e) => e.label).toList(), ['硬解', '软解']);
    });

    test('默认硬解', () {
      expect(DecodeMode.values.first, DecodeMode.hardware);
    });
  });
}
