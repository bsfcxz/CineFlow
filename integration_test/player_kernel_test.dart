/// 原生 mpv 内核的真机集成测试（K1/K2 的验收依据）。
///
/// ## 为什么必须有这个文件
///
/// 单元测试跑在桌面 VM 上，**碰不到 MethodChannel 与 JNI**：
/// 内核链路（Dart → MethodChannel → Kotlin → JNI → libmpv）里任何一环断了，
/// `flutter test` 都照样全绿。这个文件的唯一价值就是在**真机上**把这条链路
/// 走通并断言结果，而不是靠"应该没问题"。
///
/// ## 覆盖的验收点
///   1. `createTexture` 返回有效 textureId（Flutter 纹理建起来了）
///   2. `initialize` 成功 → 说明 attachSurface 先于 mpv_initialize，
///      wid 在 initialize 前设好了（顺序错了这里就会失败或画面全黑）
///   3. 加载媒体后 mpv 真的解析出 duration / 分辨率
///   4. 属性观察（EventChannel）能收到 time-pos，且时间在推进
///   5. seek / setRate 生效
///   6. `dispose` 后进程仍存活（退出不崩的回归线，AGENTS.md §6.2）
///
/// 跑法：
/// ```
/// flutter test integration_test/player_kernel_test.dart -d <device-id>
/// ```
/// 需要一个可直连的媒体 URL。默认用 mpv 官方测试片（公开 HLS）；
/// 也可用 `--dart-define=CF_TEST_URL=...` 换成内网 Emby 直链。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:cineflow/player/native/native_kernel.dart';

/// mpv 官方仓库里的测试视频（公开、稳定、小体积 HLS）
const _defaultTestUrl =
    'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

const _testUrl = String.fromEnvironment('CF_TEST_URL', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final url = _testUrl.isNotEmpty ? _testUrl : _defaultTestUrl;

  testWidgets('原生 mpv 内核：建纹理 → initialize → 起播 → 属性事件 → 退出存活',
      (tester) async {
    final kernel = NativeKernel();
    addTearDown(() async {
      // 即便断言失败也要把原生资源收干净，避免污染后续用例
      try {
        await kernel.dispose();
      } catch (_) {}
    });

    // ---- 1. 建纹理 ----
    await kernel.ensureTexture(width: 1280, height: 720);
    expect(
      kernel.textureId,
      isNotNull,
      reason: 'createTexture 未返回 textureId —— Flutter 纹理没建起来',
    );
    // ⚠️ 不要断言 `> 0`：Flutter 纹理 id 从 0 开始分配，
    // 第一个纹理合法地拿到 0。断言 > 0 是凭直觉写的错误假设（实测踩过）。
    debugPrint('[CF-IT] textureId=${kernel.textureId}');

    // 真正有意义的是"这个 id 能被 Flutter 合成"：
    // 渲染一个 Texture 组件，若 id 未注册，框架会抛错。
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 180,
          child: Texture(textureId: kernel.textureId!),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.takeException(),
      isNull,
      reason: 'Texture(textureId=${kernel.textureId}) 无法合成 —— id 未注册',
    );

    // ---- 2. initialize（内部会 attachSurface → mpv_initialize）----
    await kernel.ensureInitialized();

    // ---- 3. 起播 ----
    final errors = <String>[];
    final completed = <bool>[];
    final positions = <Duration>[];

    final subs = <StreamSubscription>[
      kernel.errorStream.listen(errors.add),
      kernel.completedStream.listen(completed.add),
      kernel.stateStream.listen((s) => positions.add(s.position)),
    ];

    await kernel.open(url, play: true);

    // 等 mpv 解析出时长（网络取流 + 解封装需要时间，最多等 30s）
    Duration dur = Duration.zero;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      dur = kernel.state.duration;
      if (dur > Duration.zero) break;
    }
    expect(
      dur,
      greaterThan(Duration.zero),
      reason: '30 秒内没拿到 duration —— 内核没真正开始解封装。错误：$errors',
    );

    // ---- 4. 分辨率（width/height 属性观察）----
    // 给一帧时间让 width/height 事件到达
    for (var i = 0; i < 10 && kernel.aspectRatio == null; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(
      kernel.aspectRatio,
      isNotNull,
      reason: '没收到 width/height —— 属性观察链路（EventChannel）可能断了',
    );

    // ---- 5. time-pos 真的在推进 ----
    final before = kernel.state.position;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (kernel.state.position > before) break;
    }
    expect(
      kernel.state.position,
      greaterThan(before),
      reason: 'position 不推进 —— 播放没真的跑起来。错误：$errors',
    );
    expect(positions, isNotEmpty, reason: 'stateStream 一条都没发');

    // ---- 6. seek 生效 ----
    final target = Duration(seconds: (dur.inSeconds ~/ 2).clamp(1, 600));
    await kernel.seek(target);
    var reached = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      // 允许 ±8s 误差：seek 后要重新缓冲，位置不会精确等于目标
      if ((kernel.state.position - target).abs() < const Duration(seconds: 8)) {
        reached = true;
        break;
      }
    }
    expect(reached, isTrue,
        reason: 'seek 到 $target 后位置没跟上，实际 ${kernel.state.position}');

    // ---- 7. 倍速 ----
    await kernel.setRate(2.0);
    var rateOk = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if ((kernel.state.rate - 2.0).abs() < 0.01) {
        rateOk = true;
        break;
      }
    }
    expect(rateOk, isTrue, reason: 'setRate(2.0) 未被回传，实际 ${kernel.state.rate}');

    // ---- 8. 播放/暂停 ----
    await kernel.pause();
    var paused = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!kernel.state.playing) {
        paused = true;
        break;
      }
    }
    expect(paused, isTrue, reason: 'pause 后 playing 仍为 true');

    await kernel.play();
    var resumed = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (kernel.state.playing) {
        resumed = true;
        break;
      }
    }
    expect(resumed, isTrue, reason: 'play 后 playing 仍为 false');

    for (final s in subs) {
      await s.cancel();
    }

    // ---- 9. 退出：dispose 之后不应有异常 ----
    await kernel.dispose();
    // dispose 是"拆 mpv + 释放纹理"的完整路径。
    // 真机上这一句若崩，整个测试进程会直接消失（而不是断言失败）——
    // 所以能走到这里本身就是"退出不崩"的证据。
  });
}
