/// **新播放 UI 接线层（PlayerFlowPage）单测** —— 离线验证 Emby 流程的装配逻辑。
///
/// 覆盖（Fake 内核 + Fake API，不碰通道/网络）：
///   1. 音量单位换算：面板 0–1 → 内核 0–100（面板/内核契约断层，
///      见 player_flow_page.dart 头注释）
///   2. 起播：resolvePlayback 的 url/headers 原样进内核 open，
///      reportPlaybackStart 恰好一次且 itemId 正确
///   3. 交互：UI 暂停按钮 → 内核暂停 → 即时上报 Pause 事件
///      （换集/自动连播的完整链路依赖真内核事件，留给真机集成测试
///      player_ui_kernel_test 覆盖）
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/media_provider.dart';
import 'package:cineflow/data/models.dart';
import 'package:cineflow/data/session_store.dart';
import 'package:cineflow/keys.dart';
import 'package:cineflow/player/domain/player_constants.dart' show DecodeMode;
import 'package:cineflow/player/application/providers/player_providers.dart';
import 'package:cineflow/player/kernel.dart';
import 'package:cineflow/player/kernel_factory.dart';
import 'package:cineflow/player/player_flow_page.dart';
import 'package:cineflow/state/providers.dart';

// ---------------- Fake 内核 ----------------

/// 记录型假内核：open/seek/setRate/setVolume 全记录，状态可手工推演。
class FakeKernel extends PlayerKernel {
  FakeKernel({this.deadStart = false});

  /// true = 模拟"死源"：open 后 playing=true（pause=no 已设）但
  /// 永远拿不到时长/进度 —— 正是 shouldTimeout 判据针对的场景。
  final bool deadStart;

  final List<String> calls = [];
  final _stateController = StreamController<KernelState>.broadcast();
  KernelState _state = const KernelState(
    position: Duration.zero,
    duration: Duration.zero,
    buffer: Duration.zero,
    playing: false,
    buffering: false,
    rate: 1.0,
  );

  /// 测试手工推演状态（速度监测用）。
  void pushState(KernelState s) => _push(s);

  void _push(KernelState s) {
    _state = s;
    _stateController.add(s);
  }

  String get engine => 'fake';

  @override
  String? get viewType => null;
  @override
  int? get textureId => 7;

  @override
  Future<void> open(String url,
      {bool play = true, Duration? start, Map<String, String>? headers}) async {
    calls.add('open:$url');
    _push(_state.copyWith(
        playing: play,
        duration: deadStart ? Duration.zero : const Duration(minutes: 20)));
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _push(_state.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _push(_state.copyWith(playing: false));
  }

  @override
  Future<void> togglePlay() async =>
      _state.playing ? await pause() : await play();

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inSeconds}');
    _push(_state.copyWith(position: position));
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('rate:$rate');
    _push(_state.copyWith(rate: rate));
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('volume:$volume');
  }

  @override
  Future<void> setAudioTrack(String id) async => calls.add('audio:$id');
  @override
  Future<void> setSubtitleTrack(String id) async => calls.add('sub:$id');
  @override
  Future<bool> addExternalSubtitle({
    required String url,
    String? title,
    String? language,
    bool select = false,
  }) async {
    calls.add('addExternalSubtitle:${title ?? '-'}');
    return true;
  }
  @override
  Future<void> removeExternalSubtitles() async =>
      calls.add('removeExternalSubtitles');
  @override
  Future<void> setVideoFilters(
      {double? brightness,
      double? contrast,
      double? saturation,
      double? hue}) async {
    calls.add('filter');
  }

  @override
  Future<void> setAudioDelay(Duration delay) async {}
  @override
  Future<void> setSubtitleDelay(Duration delay) async {}
  @override
  Future<void> setDecodeMode(DecodeMode mode) async {}

  @override
  bool supports(EngineFeature feature) => true;

  @override
  KernelState get state => _state;
  @override
  KernelTracks get tracks => const KernelTracks();
  @override
  KernelSelection get selection =>
      const KernelSelection(audioId: 'auto', subtitleId: 'auto');
  @override
  Stream<KernelState> get stateStream => _stateController.stream;
  @override
  Stream<KernelTracks> get tracksStream => const Stream.empty();
  @override
  Stream<KernelSelection> get selectionStream => const Stream.empty();
  @override
  Stream<String> get errorStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Future<void> dispose() async => _stateController.close();
}

// ---------------- Fake Emby API ----------------

class FakeMediaProvider implements MediaProvider {
  FakeMediaProvider({
    this.transcodingUrl = '',
    this.supportsTranscoding = false,
  });

  /// 非空时 resolvePlayback 返回的 launch 带转码兜底（模拟 Emby
  /// 给出了 TranscodingUrl 的场景）。
  final String transcodingUrl;

  /// ⚠️ **服务端自报**是否具备转码能力（2026-10-15 新增）。
  ///
  /// ## 为什么测试必须显式给这个值
  /// 播放器**不再只看 `transcodingUrl` 非空**就切转码 ——
  /// 因为那个 URL 是**我们自己无条件拼的**，不代表服务端能转。
  /// 真机结论（用户当轮原话）：
  /// > "不转码，我这个服务端好像不能转"
  ///
  /// 默认 `false`（保守：不盲切）；要测"能转码"的路径需显式传 `true`。
  final bool supportsTranscoding;

  final startCalls = <String>[];
  final progressEvents = <String>[];
  final stopCalls = <String>[];

  @override
  Future<PlaybackLaunch> resolvePlayback(String itemId,
      {String? mediaSourceId}) async {
    return PlaybackLaunch(
      url: 'http://emby.test/stream/$itemId',
      itemId: itemId,
      mediaSourceId: 'ms-$itemId',
      playSessionId: 'ps-1',
      headers: const {'X-Test': '1'},
      transcodingUrl: transcodingUrl,
      supportsTranscoding: supportsTranscoding,
    );
  }

  @override
  void reportPlaybackStart(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks}) {
    startCalls.add(itemId);
  }

  @override
  void reportPlaybackProgress(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks,
      required bool paused,
      double rate = 1,
      String? eventName}) {
    progressEvents.add(eventName ?? '');
  }

  @override
  void reportPlaybackStop(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks}) {
    stopCalls.add(itemId);
  }

  @override
  void reportItemProgress(
      {required String itemId, required int positionTicks, bool? played}) {}

  /// 章节查询 —— 宿主页在 `launch.chapters` 为空时会回退调它
  /// （对齐旧页的"跳过片头 / 章节刻度"能力）。
  ///
  /// 默认返回空：多数测试的 `resolvePlayback` 不带章节，
  /// 走的正是这条回退路径；返回空能让它**安静地什么都不做**，
  /// 不影响既有断言。要测片头逻辑的用例可覆写本方法。
  @override
  Future<List<MediaChapter>> getChapters(String itemId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 内存 KV（走真实 SessionStore 读写路径，符合 SecureKv 的设计初衷）。
class MemoryKv implements SecureKv {
  final map = <String, String>{};
  @override
  Future<String?> read({required String key}) async => map[key];
  @override
  Future<void> write({required String key, required String value}) async =>
      map[key] = value;
  @override
  Future<void> delete({required String key}) async => map.remove(key);
}

// ---------------- 装配 ----------------

Future<ProviderContainer> _pumpFlow(
  WidgetTester tester,
  FakeKernel kernel,
  FakeMediaProvider api,
) async {
  // 与 player_ui_interaction_test 同款表面（400×800）：已知可用的
  // 命中判定配置；默认 800×600 下控制条命中会被截住。
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(overrides: [
    embyApiProvider.overrideWith((ref) => api),
    sessionStoreProvider.overrideWith((ref) => SessionStore(storage: MemoryKv())),
  ]);
  PlayerKernelFactory.debugFactory = () => kernel;
  addTearDown(() => PlayerKernelFactory.debugFactory = null);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: PlayerFlowPage(
          item: MediaItem(id: 'm1', name: '测试电影', type: 'Movie'),
        ),
      ),
    ),
  );
  // _boot 是异步链：ensureTexture → resolvePlayback → open → 上报
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

/// 卸载页面并做确定性清理：
/// ① unmount（内核延迟销毁的 300ms 定时器在此调度）；
/// ② container.dispose —— **必须在用例体内**做（teardown 晚于
///    "Timer is still pending"不变量检查），它经 ref.onDispose 取消
///    UiVisibility 的 3s 自动隐藏定时器；
/// ③ 泵过 300ms，销毁内核定时器。
Future<void> _unmountAndDrain(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('音量单位换算（面板 0–1 → 内核 0–100）', () {
    test('0.7 → 70', () {
      expect(volumeToKernel(0.7), 70.0);
    });
    test('0 → 0；1 → 100', () {
      expect(volumeToKernel(0), 0.0);
      expect(volumeToKernel(1), 100.0);
    });
    test('越界值被钳制', () {
      expect(volumeToKernel(-0.5), 0.0);
      expect(volumeToKernel(1.7), 100.0);
    });
  });

  group('PlayerFlowPage 接线', () {
    testWidgets('起播：url/headers 原样进内核 open + Start 上报一次', (tester) async {
      final kernel = FakeKernel();
      final api = FakeMediaProvider();
      final container = await _pumpFlow(tester, kernel, api);

      expect(kernel.calls.where((c) => c.startsWith('open:')).single,
          'open:http://emby.test/stream/m1');
      expect(api.startCalls, ['m1']);
      expect(api.stopCalls, isEmpty);
      await _unmountAndDrain(tester, container);
    });

    testWidgets('UI 暂停按钮 → 内核暂停 → 即时上报 Pause', (tester) async {
      final kernel = FakeKernel();
      final api = FakeMediaProvider();
      final container = await _pumpFlow(tester, kernel, api);
      expect(api.progressEvents, isEmpty);

      // 起播后 playing=true（FakeKernel.open 推演）；点暂停
      await tester.tap(find.byKey(keys.player.togglePlayButton),
          warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));

      expect(kernel.calls, contains('pause'));
      expect(api.progressEvents, contains('Pause'));
      await _unmountAndDrain(tester, container);
    });
  });

  group('播放韧性（直连死源 → 转码兜底）', () {
    testWidgets('直连死源 + 服务端**支持**转码：15s 超时自动切转码', (tester) async {
      final kernel = FakeKernel(deadStart: true);
      // ⚠️ 2026-10-15：必须**显式**声明服务端支持转码 ——
      //    播放器不再只看 `transcodingUrl` 非空（见下面那条新用例）
      final api = FakeMediaProvider(
          transcodingUrl: 'http://emby.test/transcode/m1/master.m3u8',
          supportsTranscoding: true);
      final container = await _pumpFlow(tester, kernel, api);
      expect(kernel.calls.where((c) => c.startsWith('open:')), hasLength(1));

      // 布防 15s；泵到超时触发
      await tester.pump(const Duration(seconds: 16));

      expect(kernel.calls.where((c) => c.startsWith('open:')).last,
          'open:http://emby.test/transcode/m1/master.m3u8');
      // 错误态不得出现（已成功兜底）
      expect(container.read(playbackStateProvider).errorMessage, isNull);
      await _unmountAndDrain(tester, container);
    });

    testWidgets('★★★ 直连死源 + 服务端**不支持**转码：不切，直接报源不可用',
        (tester) async {
      // ══════════════════════════════════════════════════════════════
      //  这条锁死的是 2026-10-15 用户报障的真行为
      // ══════════════════════════════════════════════════════════════
      //
      // 用户报障（当轮原话）：
      // > "切换转码后还是内核报错"
      // > "不转码，我这个服务端好像不能转"
      //
      // 旧行为（**错的**）：只要 `transcodingUrl` 非空就自动切转码。
      // 在**不支持转码**的服务器上（Emby 免费版无 Premiere）：
      // ```
      // master.m3u8 → 200（"空转"列表）
      //   → 分段 /hls1/main/NNN.mp4 → **HTTP 400**
      //     （服务端无转码任务 ⇒ 缺 runtimeTicks 等 [Required] 参数）
      //   → mpv `end-file error` → 用户看到"播放失败（内核报错）"
      // ```
      // ⇒ 错误**指向转码**，而真实原因是**源本身不可用**
      //   ⇒ 用户去折腾转码设置，问题却不在那儿。
      final kernel = FakeKernel(deadStart: true);
      final api = FakeMediaProvider(
          transcodingUrl: 'http://emby.test/transcode/m1/master.m3u8',
          // ★ 服务端自报：不支持（真机就是这台）
          supportsTranscoding: false);
      final container = await _pumpFlow(tester, kernel, api);

      await tester.pump(const Duration(seconds: 16));

      // ① **不得**发生第二次 open（即没有切到转码）
      expect(kernel.calls.where((c) => c.startsWith('open:')), hasLength(1),
          reason: '★★★ 服务端不支持转码时**不许**自动切：\n'
              '    切过去必然 400（分段缺 [Required] 参数）\n'
              '    ⇒ 用户看到"内核报错"，会误以为转码配置有问题');
      // ② 必须给出**真实原因**的错误态
      expect(container.read(playbackStateProvider).errorMessage,
          '连接超时，该视频源可能不可用',
          reason: '★ 错误文案必须指向**源不可用**（真实原因），'
              '不能含糊成转码问题');
      await _unmountAndDrain(tester, container);
    });

    testWidgets('死源且无转码流：超时后进入错误态（不再死等）', (tester) async {
      final kernel = FakeKernel(deadStart: true);
      final api = FakeMediaProvider();
      final container = await _pumpFlow(tester, kernel, api);

      await tester.pump(const Duration(seconds: 16));

      expect(container.read(playbackStateProvider).errorMessage,
          '连接超时，该视频源可能不可用');
      // 不得有第二次 open
      expect(kernel.calls.where((c) => c.startsWith('open:')), hasLength(1));
      await _unmountAndDrain(tester, container);
    });

    testWidgets('缓冲持续不足 → 出现切转码提示', (tester) async {
      final kernel = FakeKernel();
      final api = FakeMediaProvider(
          transcodingUrl: 'http://emby.test/transcode/m1/master.m3u8');
      final container = await _pumpFlow(tester, kernel, api);

      // 模拟"播放中但缓冲持续不足"：每 2s 采样，buffer<4s 连续 3 次
      for (var i = 0; i < 4; i++) {
        kernel.pushState(KernelState(
          position: Duration(seconds: 4 + i),
          duration: Duration(minutes: 20),
          buffer: Duration(seconds: 2),
          playing: true,
          buffering: false,
          rate: 1.0,
        ));
        await tester.pump(const Duration(seconds: 2));
      }

      expect(find.byType(SnackBar), findsOneWidget);
      await _unmountAndDrain(tester, container);
    });
  });
}
