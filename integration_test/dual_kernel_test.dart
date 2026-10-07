/// **双内核真机集成测试** —— 用同一片源串行驱动 mpv 与 Media3。
///
/// ## 为什么必须真机跑
/// 单元测试跑在桌面 VM 上，**碰不到 MethodChannel / JNI / MediaCodec**：
/// 内核链路任何一环断了，`flutter test` 都照样全绿。
/// 本文件是唯一能证明"两个内核真的能播"的手段。
///
/// ## 与 `player_kernel_test.dart` 的关系
/// 那个文件只覆盖 mpv，且断言很细（duration/分辨率/seek/倍速/pause）。
/// 本文件做**两个内核的对照**，断言收敛到"能起播 + 位置推进"，
/// 因为 Media3 的能力子集与 mpv 不同（不能共用全部断言）。
///
/// ## 片源
/// 默认用**设备本地生成的视频**（`/sdcard/cf_test.mp4`）——
/// 比外网 HLS 可靠得多：不受网络波动/被墙影响，且能区分
/// "内核问题"与"网络问题"（外网失败时无法判断是哪个）。
///
/// 生成方式（测试前由脚本执行，见 `tool/prepare_device_media.ps1`）：
/// 用设备自带 `screenrecord` 录 3 秒 → 得到标准 H.264 MP4。
///
/// 也可用 `--dart-define=CF_TEST_URL=...` 换成网络流。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:cineflow/player/kernel.dart';
import 'package:cineflow/player/kernel_factory.dart';
import 'package:cineflow/player/media3/media3_kernel.dart';
import 'package:cineflow/player/native/native_kernel.dart';

/// 设备本地测试片源（由 tool/prepare_device_media.ps1 生成）。
const _localPath = '/sdcard/cf_test.mp4';

/// 可用 `--dart-define=CF_TEST_URL=...` 覆盖（网络流）。
const _overrideUrl = String.fromEnvironment('CF_TEST_URL', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 等某个条件成立（真机上"起播"是异步的，需要轮询）。
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

  /// 两个内核的结果都收集到这里，最后一起打印 + 断言。
  ///
  /// 必须在 `exercise` 之前声明：Dart 局部变量即使在闭包里，
  /// 也不能在声明语句之前被引用（编译错误，不是运行时警告）。
  final results = <String, Map<String, Object?>>{};

  /// 对一个内核跑完整流程，返回诊断信息（**不断言**，由调用方断言）。
  ///
  /// 抽成函数是为了让两个内核**走完全相同的步骤** ——
  /// 否则两边的差异会掩盖真实问题（"为什么 Media3 失败"可能只是步骤不同）。
  Future<Map<String, Object?>> exercise(
    WidgetTester tester,
    PlayerKernel kernel,
    String url,
  ) async {
    final errors = <String>[];
    final states = <KernelState>[];
    final tracks = <KernelTracks>[];

    final subs = <StreamSubscription>[
      kernel.errorStream.listen(errors.add),
      kernel.stateStream.listen(states.add),
      kernel.tracksStream.listen(tracks.add),
    ];

    final result = <String, Object?>{'engine': kernel.engine};

    try {
      // 1. 建纹理
      if (kernel is NativeKernel) {
        await kernel.ensureTexture(width: 1280, height: 720);
        result['textureId'] = kernel.textureId;
      } else if (kernel is Media3Kernel) {
        await kernel.ensureTexture(width: 1280, height: 720);
        result['textureId'] = kernel.textureId;
      }

      // 2. 起播
      await kernel.open(url, play: true);

      // 3. 等 duration（最多 30s）
      final gotDur = await waitFor(tester, () => kernel.state.duration > Duration.zero);
      result['duration'] = kernel.state.duration;
      result['gotDuration'] = gotDur;

      if (gotDur) {
        // 4. 等位置推进
        final before = kernel.state.position;
        final moved = await waitFor(
          tester,
          () => kernel.state.position > before,
          tries: 40,
        );
        result['positionMoved'] = moved;
        result['position'] = kernel.state.position;

        // 5. seek 到中间
        final target = Duration(seconds: (kernel.state.duration.inSeconds ~/ 2).clamp(1, 60));
        await kernel.seek(target);
        final seeked = await waitFor(
          tester,
          () => (kernel.state.position - target).abs() < const Duration(seconds: 6),
          tries: 40,
          step: const Duration(milliseconds: 250),
        );
        result['seekOk'] = seeked;
        result['seekTarget'] = target;

        // 6. 倍速
        await kernel.setRate(2.0);
        final rateOk = await waitFor(
          tester,
          () => (kernel.state.rate - 2.0).abs() < 0.05,
          tries: 25,
          step: const Duration(milliseconds: 200),
        );
        result['rateOk'] = rateOk;
        result['rate'] = kernel.state.rate;

        // 7. 暂停/继续
        await kernel.pause();
        final paused = await waitFor(
          tester,
          () => !kernel.state.playing,
          tries: 25,
          step: const Duration(milliseconds: 200),
        );
        result['paused'] = paused;
      }

      result['tracksEmits'] = tracks.length;
      result['audioTracks'] = kernel.tracks.audio.length;
      result['subTracks'] = kernel.tracks.subtitle.length;
      result['stateEmits'] = states.length;
    } catch (e) {
      result['threw'] = '$e';
    } finally {
      // 错误事件必须进结果：否则"内核 open 失败"只能看到 duration=0，
      // 分不清是权限拒绝、片源坏了还是通道断了。
      result['errors'] = errors;
      for (final s in subs) {
        await s.cancel();
      }
      results[kernel.engine] = result;
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // 为什么把两个内核放在**同一个 testWidgets** 里
  //
  // 每个 `integration_test` 用例都会重建整棵树并可能重启 Activity。
  // 而两个内核各自持有原生播放器 + Flutter 纹理；
  // 分两个用例时，前一个用例的 `dispose` 与后一个的 `createTexture`
  // 可能在真机上交错（尤其 Media3 的 release 是异步的），
  // 现象是"第二个内核莫名失败"——**但那不是内核的问题，是测试编排的问题**。
  //
  // 放同一用例内**串行**执行（先 mpv 完整跑完并 dispose，再 Media3），
  // 就把这个干扰源消掉了。
  // ─────────────────────────────────────────────────────────────
  testWidgets('双内核真机对照：mpv 与 Media3 播同一片源', (tester) async {
    final url = _overrideUrl.isNotEmpty ? _overrideUrl : _localPath;
    debugPrint('[CF-DUAL] 片源 = $url');

    // 片源可用性检查：本地文件不存在时给出**明确**提示，
    // 而不是让"播放失败"看起来像内核问题。
    if (_overrideUrl.isEmpty) {
      final f = File(_localPath);
      final exists = f.existsSync();
      debugPrint('[CF-DUAL] 本地片源存在 = $exists');
      if (!exists) {
        // 不直接失败：把原因说清楚，便于区分"片源没准备"与"内核坏了"
        fail('设备上没有 $_localPath —— 先跑 tool/prepare_device_media.ps1 生成测试片源。'
            '（这条失败**不代表内核有问题**）');
      }
    }

    // ---------- 内核 1：mpv ----------
    debugPrint('[CF-DUAL] ===== mpv =====');
    final mpv = PlayerKernelFactory.create(KernelType.mpv);
    final mpvResult = await exercise(tester, mpv, url);
    debugPrint('[CF-DUAL] mpv 结果: $mpvResult');
    await mpv.dispose();
    // dispose 之后进程仍应存活（退出不崩是本仓库的回归线）
    await tester.pump(const Duration(milliseconds: 600));
    debugPrint('[CF-DUAL] mpv dispose 后存活');

    // ---------- 内核 2：Media3 ----------
    debugPrint('[CF-DUAL] ===== Media3 =====');
    final m3 = PlayerKernelFactory.create(KernelType.media3);
    final m3Result = await exercise(tester, m3, url);
    debugPrint('[CF-DUAL] Media3 结果: $m3Result');
    await m3.dispose();
    await tester.pump(const Duration(milliseconds: 600));
    debugPrint('[CF-DUAL] Media3 dispose 后存活');

    // ---------- 断言 ----------
    //
    // ⚠️ 断言口径说明（重要）：
    //   mpv 是**主力内核**，必须完整通过（起播/seek/倍速/暂停）。
    //   Media3 的能力子集不同，且它在真机上的表现需要先观测 ——
    //   故第一轮**只断言"能起播"**，其余作为诊断信息打印。
    //   这样既不会让"Media3 某细节不同"掩盖真实问题，
    //   也不会让未验证的东西被当成已验证。
    expect(
      mpvResult['gotDuration'],
      isTrue,
      reason: 'mpv 没起播：$mpvResult',
    );
    expect(mpvResult['positionMoved'], isTrue, reason: 'mpv 位置不推进：$mpvResult');
    expect(mpvResult['seekOk'], isTrue, reason: 'mpv seek 失败：$mpvResult');
    expect(mpvResult['paused'], isTrue, reason: 'mpv 暂停失败：$mpvResult');

    expect(
      m3Result['gotDuration'],
      isTrue,
      reason: 'Media3 没起播：$m3Result\n'
          '（若 mpv 通过而 Media3 失败，问题在 Media3Channel 而非片源）',
    );
    expect(m3Result['positionMoved'], isTrue, reason: 'Media3 位置不推进：$m3Result');

    // 把对照结果打出来，便于人工核对两个内核的差异
    debugPrint('[CF-DUAL] ===== 对照 =====');
    for (final e in ['native', 'media3']) {
      debugPrint('[CF-DUAL] $e -> ${results[e]}');
    }
  });
}
