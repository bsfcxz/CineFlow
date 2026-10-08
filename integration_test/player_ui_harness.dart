/// **新播放 UI × 真内核 真机测试的公共装配层** —— 被
/// `player_ui_kernel_test.dart`（mpv）与 `player_ui_media3_test.dart`
/// 两个测试文件导入。
///
/// ## 为什么拆成两个测试文件（重要，别合并回去）
/// 同一个 testWidgets 里跑第二个内核会撞 "Guarded function conflict"
/// （TestAsyncUtils 守卫与真内核/Media3 事件投递的竞态，实测时好时坏）；
/// 即便拆成同一文件里的两个 testWidgets 也仍会偶发。**拆成两个文件、
/// 两次独立的 `flutter test` 进程**是唯一稳定的编排 —— 各自守卫状态干净，
/// CI 上哪个挂了单独重跑哪个。
///
/// ## 与既有测试的分工
/// · `integration_test/player_kernel_test.dart`   —— 只测 mpv 内核，不碰 UI
/// · `integration_test/dual_kernel_test.dart`     —— 双内核对照，不碰 UI
/// · `test/player_ui_interaction_test.dart`       —— 只测 UI 状态机，不碰内核
/// · **本 harness + 两个测试文件**：UI 按钮 → 回调 → 真内核 → 状态回流
///   UI 的全链路，并按播放ui.html 原型逐 Tab 核对设置面板。
///
/// ## 片源
/// 默认设备本地 `/sdcard/cf_test.mp4`（tool/prepare_device_media.ps1 生成）；
/// **推荐** `--dart-define=CF_TEST_URL=http://127.0.0.1:8765/cf_test.mp4`
/// （宿主机 `python -m http.server 8765` + `adb reverse tcp:8765 tcp:8765`）。
/// manifest 无存储权限，本地路径会被 scoped storage 拒。
library;

import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/keys.dart';
import 'package:cineflow/player/application/providers/player_providers.dart';
import 'package:cineflow/player/kernel.dart';
import 'package:cineflow/player/kernel_factory.dart';
import 'package:cineflow/player/media3/media3_kernel.dart';
import 'package:cineflow/player/native/native_kernel.dart';
import 'package:cineflow/player/presentation/player_ui_page.dart';

/// 设备本地测试片源。
const testMediaPath = '/sdcard/cf_test.mp4';

/// 可用 `--dart-define=CF_TEST_URL=...` 覆盖（推荐，绕开存储权限）。
const overrideUrl = String.fromEnvironment('CF_TEST_URL', defaultValue: '');

/// 片源 URL（测试用例里取这个）。
String get mediaUrl =>
    overrideUrl.isNotEmpty ? overrideUrl : testMediaPath;

/// 本地片源存在性检查（overrideUrl 模式下跳过）。
void ensureMediaAvailable() {
  if (overrideUrl.isNotEmpty) return;
  if (!File(testMediaPath).existsSync()) {
    fail('设备上没有 $testMediaPath —— 先跑 tool/prepare_device_media.ps1，'
        '或用 --dart-define=CF_TEST_URL=... 指定网络流');
  }
}

/// 各内核的流订阅（pumpRealPlayer 登记，exercise 的 finally 统一取消）。
///
/// 两个测试文件各自独立进程，顶层可变列表无共享问题。
final kernelSubs = <StreamSubscription<dynamic>>[];

/// 轮询等待内核条件成立（真机起播是异步的）。
Future<bool> waitFor(
  WidgetTester tester,
  bool Function() ok, {
  int tries = 60,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (var i = 0; i < tries; i++) {
    await tester.pump(step);
    if (ok()) return true;
  }
  return false;
}

/// 控制层可能已被自动隐藏（播放中 3s 隐藏）：点视频区把它切回来。
Future<void> ensureControlsVisible(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    final visible = find
        .byKey(keys.player.speedButton)
        .hitTestable()
        .evaluate()
        .isNotEmpty;
    if (visible) return;
    await tester.tap(find.byKey(keys.player.videoGestureArea),
        warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 450));
  }
}

/// 把真内核装进 PlayerUiPage：状态回流 providers、回调直连内核。
///
/// 返回回调调用记录（未接内核的回调仅记录，供断言"面板点了有反应"）。
List<String> pumpRealPlayer(
  WidgetTester tester,
  ProviderContainer container,
  PlayerKernel kernel,
  int textureId,
) {
  final calls = <String>[];

  // ---- 内核状态 → providers（正式接线层还没写，这里是它的第一版）----
  kernelSubs.add(kernel.stateStream.listen((s) {
    final p = container.read(playbackStateProvider.notifier);
    p.setPlaying(s.playing);
    p.setPosition(s.position);
    p.setDuration(s.duration);
    p.setBuffer(s.buffer);
    p.setBuffering(s.buffering);
    p.syncSpeed(s.rate);
  }));
  kernelSubs.add(kernel.errorStream.listen((e) {
    calls.add('KERNEL_ERROR:$e');
  }));

  Future<void> togglePlay() async {
    calls.add('togglePlay');
    // 与正式接线层一致的语义：Controller 已翻转 isPlaying，这里按
    // **内核**状态执行（内核是事实源，避免 UI 状态与内核漂移）。
    if (kernel.state.playing) {
      await kernel.pause();
    } else {
      await kernel.play();
    }
  }

  tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: PlayerUiPage(
          slots: PlayerPageSlots(
            title: 'cf_test.mp4 · ${kernel.engine}',
            video: Texture(textureId: textureId),
          ),
          callbacks: PlayerPageCallbacks(
            onTogglePlay: () => togglePlay(),
            onSeekBy: (d) {
              calls.add('seekBy:${d.inSeconds}');
              kernel.seek(kernel.state.position + d);
            },
            onSeekTo: (d) {
              calls.add('seekTo:${d.inSeconds}');
              kernel.seek(d);
            },
            onSpeedChanged: (v) {
              calls.add('speed:$v');
              kernel.setRate(v);
            },
            // ⚠️ 单位换算：面板回调是 0–1（SliderRow x/100），内核契约是
            //    0–100（Media3Kernel 文档注释明说"传 0–100，Kotlin 除以
            //    100"）。正式接线层必须保留这个换算 —— 已记入台账。
            onVolumeChanged: (v) {
              calls.add('volume:${v.toStringAsFixed(2)}');
              kernel.setVolume(v * 100);
            },
            onBrightnessChanged: (v) =>
                calls.add('brightness:${v.toStringAsFixed(2)}'),
            onAspectModeChanged: (m) => calls.add('aspect:${m.name}'),
            onFullscreenToggled: () => calls.add('fullscreen'),
            onBack: () => calls.add('back'),
            onSelectMedia: (i) => calls.add('selectMedia:$i'),
            onPrevious: () {},
            onNext: () {},
            onSelectAudioTrack: (id) {
              calls.add('audio:$id');
              kernel.setAudioTrack(id);
            },
            onSelectSubtitleTrack: (id) {
              calls.add('subtitle:$id');
              if (id != null) kernel.setSubtitleTrack(id);
            },
            onImportSubtitle: () => calls.add('importSubtitle'),
            onImportDanmaku: () => calls.add('importDanmaku'),
            onMatchDanmaku: () => calls.add('matchDanmaku'),
            onVideoFilterChanged: ({brightness, contrast, saturation, hue}) {
              calls.add('filter');
              kernel.setVideoFilters(
                brightness: brightness,
                contrast: contrast,
                saturation: saturation,
                hue: hue,
              );
            },
            onResetFilters: () {
              calls.add('resetFilters');
              kernel.setVideoFilters(
                  brightness: 0, contrast: 0, saturation: 0, hue: 0);
            },
            onAudioDelayChanged: (d) {
              calls.add('audioDelay:${d.inMilliseconds}');
              kernel.setAudioDelay(d);
            },
            onSubtitleDelayChanged: (d) {
              calls.add('subDelay:${d.inMilliseconds}');
              kernel.setSubtitleDelay(d);
            },
            onSubtitleFontSizeChanged: (s) => calls.add('subFont:${s.name}'),
            onSubtitleEncodingChanged: (e) => calls.add('subEnc:${e.name}'),
          ),
        ),
      ),
    ),
  );
  return calls;
}

/// 对一个内核跑全链路：起播 → 控制条交互（倍速/暂停）→ 设置面板四 Tab
/// 逐项核对（视频/音频/字幕/信息，按播放ui.html 原型）。
///
/// 全程包在 runAsync 里：真内核通道 + Media3 事件投递是真异步，
/// 在 testWidgets 的守卫区里裸跑会撞 "Guarded function conflict"。
Future<Map<String, Object?>> exerciseKernel(
  WidgetTester tester,
  KernelType type,
  String url,
) async {
  final r = await tester.runAsync(
      () => _exerciseKernelInner(tester, type, url));
  return r!;
}

Future<Map<String, Object?>> _exerciseKernelInner(
  WidgetTester tester,
  KernelType type,
  String url,
) async {
  final result = <String, Object?>{'engine': type.name};
  final kernel = PlayerKernelFactory.create(type);
  try {
    // 建纹理（两个内核各自实现，不在 PlayerKernel 基类上）
    if (kernel is NativeKernel) {
      await kernel.ensureTexture(width: 1280, height: 720);
    } else if (kernel is Media3Kernel) {
      await kernel.ensureTexture(width: 1280, height: 720);
    }
    final tid = kernel is NativeKernel
        ? kernel.textureId
        : kernel is Media3Kernel
            ? kernel.textureId
            : null;
    expect(tid, isNotNull, reason: '纹理未创建');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final calls = pumpRealPlayer(tester, container, kernel, tid!);

    // ---- 1. 起播 + 位置推进（同一片源，两内核同口径）----
    await kernel.open(url, play: true);
    final gotDur =
        await waitFor(tester, () => kernel.state.duration > Duration.zero);
    result['gotDuration'] = gotDur;
    expect(gotDur, isTrue, reason: '$type 没起播：${kernel.state}');

    final before = kernel.state.position;
    final moved =
        await waitFor(tester, () => kernel.state.position > before, tries: 40);
    result['positionMoved'] = moved;
    expect(moved, isTrue, reason: '$type 位置不推进');
    result['playing'] = kernel.state.playing;

    // ---- 2. UI → 内核：倍速按钮循环 1.0 → 1.5 ----
    await ensureControlsVisible(tester);
    await tester.tap(find.byKey(keys.player.speedButton));
    await tester.pump(const Duration(milliseconds: 400));
    final rate15 = await waitFor(
      tester,
      () => (kernel.state.rate - 1.5).abs() < 0.05,
      tries: 20,
      step: const Duration(milliseconds: 250),
    );
    result['uiSpeedApplied'] = rate15;
    expect(rate15, isTrue,
        reason: '$type 倍速按钮未生效：calls=$calls rate=${kernel.state.rate}');

    // ---- 3. UI → 内核：暂停 ----
    // ⚠️ 起播后控制层 3s 自动隐藏；从"等位置推进"到这里已超 3s，
    //    不 ensure 的话这一下会点在手势层上（切 UI 显隐而非暂停）。
    await ensureControlsVisible(tester);
    await tester.tap(find.byKey(keys.player.togglePlayButton));
    await tester.pump(const Duration(milliseconds: 400));
    final paused = await waitFor(
      tester,
      () => !kernel.state.playing,
      tries: 20,
      step: const Duration(milliseconds: 250),
    );
    result['uiPauseApplied'] = paused;
    expect(paused, isTrue, reason: '$type 暂停按钮未生效：calls=$calls');

    // 暂停后控制层不再自动隐藏，面板交互稳定。
    // ---- 4. 设置面板（按播放ui.html 原型逐项核对）----
    await ensureControlsVisible(tester);
    await tester.tap(find.byKey(keys.player.settingsButton));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(keys.player.settingsPanel), findsOneWidget,
        reason: '设置面板未打开');

    // 四个 Tab（原型：视频/音频/字幕/信息）
    for (final t in ['视频', '音频', '字幕', '信息']) {
      expect(find.text(t), findsWidgets, reason: '缺少 $t Tab（原型 §7.6）');
    }

    // 视频 Tab：画面比例五档 + 解码两档 + 四个滤镜滑块
    for (final t in [
      '画面比例', '适应', '拉伸', '裁剪', '16:9', '4:3',
      '解码方式', '硬解', '软解',
      '亮度', '对比度', '饱和度', '色相',
    ]) {
      expect(find.text(t), findsWidgets, reason: '视频 Tab 缺少「$t」');
    }
    debugPrint('[CF-UI-SHOT] ${type.name}_video_tab');
    await tester.pump(const Duration(seconds: 2));

    // 切音频 Tab：音轨 + 音频延迟步进 + 音量
    await tester.tap(find.text('音频').first);
    await tester.pump(const Duration(milliseconds: 400));
    for (final t in ['音轨', '音频延迟', '音量']) {
      expect(find.text(t), findsWidgets, reason: '音频 Tab 缺少「$t」');
    }
    // 音频延迟 +0.1s → 回调 → 内核（mpv 生效；Media3 如实忽略）
    // 步进按钮是 Icons.add/remove 图标（_StepButton），不是文本 +/-。
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, contains('audioDelay:100'), reason: '音频延迟步进未触发回调');
    debugPrint('[CF-UI-SHOT] ${type.name}_audio_tab');
    await tester.pump(const Duration(seconds: 2));

    // 切字幕 Tab：轨道 + 外挂 + 延迟 + 字号 + 编码
    await tester.tap(find.text('字幕').first);
    await tester.pump(const Duration(milliseconds: 400));
    for (final t in [
      '字幕轨道', '字幕延迟', '字幕字号', '字幕编码',
      '小', '中', '大', '超大', '自动', 'UTF-8', 'GBK', 'BIG5',
    ]) {
      expect(find.text(t), findsWidgets, reason: '字幕 Tab 缺少「$t」');
    }
    debugPrint('[CF-UI-SHOT] ${type.name}_subtitle_tab');
    await tester.pump(const Duration(seconds: 2));

    // 切信息 Tab：文件/视频/音频/封装 四节
    await tester.tap(find.text('信息').first);
    await tester.pump(const Duration(milliseconds: 400));
    for (final t in ['文件', '视频', '音频', '封装']) {
      expect(find.text(t), findsWidgets, reason: '信息 Tab 缺少「$t」节');
    }
    debugPrint('[CF-UI-SHOT] ${type.name}_info_tab');
    await tester.pump(const Duration(seconds: 2));

    result['calls'] = calls.length;
  } catch (e) {
    result['threw'] = '$e';
    rethrow;
  } finally {
    for (final s in kernelSubs) {
      await s.cancel();
    }
    kernelSubs.clear();
    await kernel.dispose();
    await tester.pump(const Duration(milliseconds: 600));
    debugPrint('[CF-DUAL-UI] $type 结果: $result');
  }
  return result;
}
