/// 最小真机内核冒烟 —— **只验证一件事**：内核能不能建纹理并收到状态事件。
///
/// ## 为什么要单独一个最小文件
/// `dual_kernel_test.dart` 一次测太多（两个内核 + 起播 + seek + 倍速 + 暂停）。
/// 当它失败时，**无法区分**是"链路某处断了"还是"片源/网络问题"。
///
/// 本文件把变量降到最少：
///   · 只建纹理（不 open）→ 验证 Dart↔Kotlin 通道通不通
///   · 只 open 一个 URL → 验证取流
///   · 打印**每一步**的时间戳，便于对照 logcat 判断卡在哪一步
///
/// ## 与 logcat 的配合
/// 上一次失败时，测试进程跑了 66 秒却**零条 flutter 日志** —— 说明
/// 连 Dart 侧的 `debugPrint` 都没出来。本文件第一句就打日志，
/// 用于区分"根本没进 Dart"与"进了 Dart 但后续失败"。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:cineflow/player/native/native_kernel.dart';

const _overrideUrl = String.fromEnvironment('CF_TEST_URL', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('最小内核冒烟：建纹理 → open → 收状态', (tester) async {
    // ★ 第一句就打日志：若 logcat 里连这行都没有，说明**根本没进 Dart**
    //   （那是测试编排/安装问题，与内核无关）。
    debugPrint('[CF-SMOKE] 进入测试体 t=0');
    final started = DateTime.now();

    String elapsed() {
      final ms = DateTime.now().difference(started).inMilliseconds;
      return 't=${(ms / 1000).toStringAsFixed(1)}s';
    }

    final url = _overrideUrl.isNotEmpty
        ? _overrideUrl
        : 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
    debugPrint('[CF-SMOKE] ${elapsed()} url=$url');

    final kernel = NativeKernel();
    final errors = <String>[];
    final states = <String>[];
    final subs = <StreamSubscription>[
      kernel.errorStream.listen((e) {
        errors.add(e);
        debugPrint('[CF-SMOKE] ${elapsed()} ERROR: $e');
      }),
      kernel.stateStream.listen((s) {
        states.add('${s.position.inMilliseconds}ms playing=${s.playing} dur=${s.duration.inMilliseconds}ms');
        if (states.length <= 5) {
          debugPrint('[CF-SMOKE] ${elapsed()} state: ${states.last}');
        }
      }),
    ];

    try {
      // ---- 步骤 1：建纹理（不涉及网络/片源）----
      debugPrint('[CF-SMOKE] ${elapsed()} 建纹理...');
      await kernel.ensureTexture(width: 1280, height: 720);
      debugPrint('[CF-SMOKE] ${elapsed()} 纹理 OK id=${kernel.textureId}');

      // 渲染一帧确认纹理可合成
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 180,
          child: Texture(textureId: kernel.textureId!),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      debugPrint('[CF-SMOKE] ${elapsed()} 纹理渲染异常=${tester.takeException()}');

      // ---- 步骤 2：初始化 mpv ----
      debugPrint('[CF-SMOKE] ${elapsed()} ensureInitialized...');
      await kernel.ensureInitialized();
      debugPrint('[CF-SMOKE] ${elapsed()} 初始化 OK');

      // ---- 步骤 3：open ----
      debugPrint('[CF-SMOKE] ${elapsed()} open...');
      await kernel.open(url, play: true);
      debugPrint('[CF-SMOKE] ${elapsed()} open 返回');

      // ---- 步骤 4：等 20 秒看状态 ----
      Duration dur = Duration.zero;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        dur = kernel.state.duration;
        if (dur > Duration.zero) break;
      }
      debugPrint('[CF-SMOKE] ${elapsed()} duration=$dur '
          'states=${states.length} errors=$errors');
      debugPrint('[CF-SMOKE] ${elapsed()} 前 5 条状态: ${states.take(5).toList()}');

      // 本文件**只做诊断**，不断言成败 —— 断言留给上层对照测试。
      // 这样即使失败，也能从输出读出"卡在哪一步"。
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      debugPrint('[CF-SMOKE] ${elapsed()} dispose...');
      await kernel.dispose();
      debugPrint('[CF-SMOKE] ${elapsed()} dispose 完成，进程应仍存活');
    }
  });
}
