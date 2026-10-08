/// **K3 媒体会话接线**守卫测试（CF-P3-KERNEL-004）。
///
/// ## 为什么用"读源码断言"而不是单测运行
/// 这些是**原生侧接线**（Kotlin/Manifest），`flutter test` 跑在桌面 VM，
/// 碰不到 Android 平台。但它们的**缺失方式**恰恰是"静默失效"——
/// 不报错、不影响播放，只是通知栏/媒体键没有。
///
/// 本项目已有同类做法的先例（`player_exit_freeze_guard_test.dart`
/// 读 `player_flow_page.dart` 断言方向逻辑）。
///
/// ## ⚠️ 断言前必须剥注释
/// 本仓库踩过：`contains('s.videoRange')` 命中了**注释**里的同名文本，
/// 导致删掉真代码后测试仍全绿（假绿）。
/// 故本文件统一用 [readCode]（先剥注释）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去掉注释后的源码（**断言必须用它**）。
///
/// 不剥注释的话，注释里出现的标识符会让断言"永远为真"——
/// 那是最难发现的一类假绿。
String readCode(String path) {
  final s = File(path).readAsStringSync();
  // 去块注释
  var out = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  // 去行注释（不处理字符串里的 // —— 本项目源码里没有这类干扰）
  out = out.replaceAll(RegExp(r'//[^\n]*'), '');
  return out;
}

void main() {
  group('★ 媒体会话服务（K3）', () {
    late String manifest;
    late String service;

    setUpAll(() {
      manifest = readCode('android/app/src/main/AndroidManifest.xml');
      service = readCode(
          'android/app/src/main/kotlin/com/cineflow/app/player/CineFlowSessionService.kt');
    });

    test('manifest 注册了 MediaSessionService（含前台服务类型）', () {
      expect(manifest.contains('CineFlowSessionService'), isTrue,
          reason: '服务不注册 ⇒ 会话根本起不来');

      // ★ 这三条是 API 33/34+ 的硬要求，缺一个就静默失效或直接崩。
      //
      // ⚠️ **必须断言 `<uses-permission>` 整行**，而不是裸关键字 ——
      //    manifest 的注释里也写着这些名字（解释为什么需要它们），
      //    裸断言会被**注释满足** ⇒ 删掉真权限后测试仍绿（假绿）。
      //    反向注入已证实这一点。
      for (final p in [
        'android.permission.FOREGROUND_SERVICE"',
        'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"',
        'android.permission.POST_NOTIFICATIONS"',
      ]) {
        expect(manifest.contains('uses-permission android:name="$p'),
            isTrue,
            reason: '★ 缺 `<uses-permission android:name="$p`。\n'
                '    · FOREGROUND_SERVICE：API 28+ 前台服务必需\n'
                '    · FOREGROUND_SERVICE_MEDIA_PLAYBACK：API 34+ **必需**，\n'
                '      缺失时 startForeground 直接抛 SecurityException\n'
                '      （本 App targetSdk 36）\n'
                '    · POST_NOTIFICATIONS：API 33+ 必需，缺失则通知栏\n'
                '      完全不显示且**不报错**');
      }
    });

    test('★ 服务必须显式 addSession（通知栏不贴的真实原因）', () {
      // ## 这条断言守的是一个花了整轮才定位的缺陷
      // `MediaSession.Builder(...).build()` **只创建**会话，
      // 不会纳入通知管理 ⇒ 通知永远不贴、`startForegroundCount=0`、
      // `onUpdateNotification` 从不被调用。
      //
      // 而它**完全不影响媒体键**（那走 MediaButton 路径）——
      // 所以现象是"媒体键能用，但通知栏什么都没有"，极易误判为
      // "通知权限问题"。
      expect(service.contains('addSession(session)'), isTrue,
          reason: '★ 必须显式 `addSession(session)`！\n'
              '    `MediaSession.Builder().build()` 只创建会话，\n'
              '    不注册进通知管理器 ⇒ 通知栏永远不出现。\n'
              '    （真机现象：媒体键能用、`dumpsys media_session` 有会话，\n'
              '      但 `startForegroundCount=0`、无 NotificationRecord。）');
      expect(service.contains('removeSession'), isTrue,
          reason: '销毁时要移出通知管理器（否则留下悬挂引用）');
    });

    test('★ 音频焦点必须自研（Media3 不代劳）', () {
      final focus = readCode(
          'android/app/src/main/kotlin/com/cineflow/app/player/AudioFocusManager.kt');
      expect(focus.contains('requestAudioFocus'), isTrue,
          reason: '★ `media3-session` **不替你申请音频焦点**（上游明确）。\n'
              '    不做焦点的后果用户可感知：来电时视频不停、\n'
              '    别的 App 放音乐两边同时响、拔耳机突然外放。');
      // 三种失焦必须分开处理
      expect(focus.contains('AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK'), isTrue,
          reason: '★ 可闪避（通知音）不能当"临时失焦"处理 ——\n'
              '    否则每来一条通知视频都暂停一下');
      expect(focus.contains('AUDIOFOCUS_LOSS_TRANSIENT'), isTrue);
    });

    test('★ 焦点要在"开始出声"时申请（不能只在 onPlaybackResumption）', () {
      // ## 真机踩过
      // 只在 `onPlaybackResumption` 申请 ⇒ 那回调只在"系统要求恢复播放"
      // （蓝牙重连等）时触发，**正常起播根本不走它** ⇒ 焦点从未被申请
      //（`dumpsys audio` 里查不到本 App，被验证脚本抓到）。
      expect(service.contains('isPlaying && !lastPlaying'), isTrue,
          reason: '★ 应在 isPlaying **变为 true** 时申请焦点。\n'
              '    只在 onPlaybackResumption 里申请会导致正常起播永不申请。');
    });
  });

  group('★ 会话命令必须驱动内核（不能只改状态机）', () {
    test('★ 会话命令走 _kernel 直调，与 UI 点击同一路径', () {
      final flow = readCode('lib/player/player_flow_page.dart');

      final fn = flow.indexOf('SessionBridge.instance.onCommand');
      expect(fn, greaterThanOrEqualTo(0), reason: '找不到会话命令注册');
      // 用下一个方法定义作右边界（比拍长度可靠 —— 拍长度会吃到别的方法）
      final stop = flow.indexOf('void dispose()', fn);
      final body = flow.substring(fn, stop > fn ? stop : fn + 5000);

      // ⚠️ 断言必须**逐分支**检查，不能只查全文有没有 `k?.pause()` ——
      //    会话块里 `k?.pause()` 出现多处（pause/stop/pauseByFocusLoss），
      //    只把其中一处改回状态机，全文断言**照样为真**（假绿，注入已证实）。
      //
      // 本测试守的是真机踩过的 bug：第一版调 `pc.pause()`，
      // 而 `PlaybackController.pause()` 是**纯状态机**（不驱动内核）⇒
      // 媒体键命令一路走到 Dart（日志有 `会话命令: pause`）却**画面无变化**。

      /// 取 `case 'xxx':` 到下一个 `case` 之间的代码。
      String caseBody(String name) {
        final i = body.indexOf("case '$name':");
        expect(i, greaterThanOrEqualTo(0), reason: '找不到 case $name');
        final j = body.indexOf('case ', i + 5);
        return body.substring(i, j > i ? j : body.length);
      }

      expect(caseBody('play').contains('k?.play()'), isTrue,
          reason: '★ `case play` 必须调**内核** `k?.play()`');
      expect(caseBody('pause').contains('k?.pause()'), isTrue,
          reason: '★ `case pause` 必须调**内核** `k?.pause()`。\n'
              '    `PlaybackController.pause()` 只翻状态标志 ⇒\n'
              '    媒体键"有日志但画面没反应"。');
      expect(caseBody('playPause').contains('k.state.playing'), isTrue,
          reason: '★ `case playPause` 必须读**内核**当前状态判断，\n'
              '    不能信状态机（会与实际不同步）');

      // 状态机直调是不许出现的（那就是这个 bug 的形态）
      expect(body.contains('playbackStateProvider.notifier).pause()'), isFalse,
          reason: '★ 不得在会话命令里调状态机的 pause()（不驱动内核）');
      expect(body.contains('playbackStateProvider.notifier).play()'), isFalse,
          reason: '★ 同上');
    });

    test('★ SessionStateSync 挂在 stateStream 上（不能只挂按钮）', () {
      final flow = readCode('lib/player/player_flow_page.dart');
      final fn = flow.indexOf('kernel.stateStream.listen');
      expect(fn, greaterThanOrEqualTo(0));
      final body = flow.substring(fn, (fn + 3000).clamp(0, flow.length));
      expect(body.contains('_sessionSync.sync(s)'), isTrue,
          reason: '★ 状态同步必须挂在 `stateStream` 上 ——\n'
              '    挂在播放/暂停按钮里会漏掉手势 seek、自动连播、\n'
              '    内核内部状态跃迁等路径。');
    });

    test('★ updateState 失败不得静默吞掉', () {
      final bridge =
          readCode('lib/player/infrastructure/session/session_bridge.dart');
      final fn = bridge.indexOf('Future<void> updateState(');
      expect(fn, greaterThanOrEqualTo(0));

      // ⚠️ 窗口必须**精准**：用下一个方法名作右边界，而不是拍一个长度。
      //    （第一版用固定长度 1800，结果窗口越过了 updateState、
      //      把 `clearState` 的 catch 也吃进来 ⇒ 断言误报。）
      final next = bridge.indexOf('Future<void> clearState(', fn);
      expect(next, greaterThan(fn), reason: '找不到 clearState（边界锚点）');
      final body = bridge.substring(fn, next);

      expect(body.contains('catch (_) {}'), isFalse,
          reason: '★ `catch (_) {}` 会让"通知不贴"完全无从排查 ——\n'
              '    真机排查时正是它把异常吞了，多花了好几轮。\n'
              '    至少要 debugPrint 出原因。');
      expect(body.contains('debugPrint'), isTrue,
          reason: '失败必须有可见痕迹');
    });
  });
}
