/// **媒体会话状态同步**测试（K3 / CF-P3-KERNEL-004）。
///
/// ## 为什么这些断言重要
/// 通知栏最容易出的两类问题**静态分析都抓不到**：
/// 1. **推送太频繁** —— 进度是 250ms 推一次的，不去重会让原生侧
///    每秒重建 4 次通知（CPU 白耗 + 通知栏闪烁）。
///    这类缺陷在真机上表现为"通知栏闪"，很难归因到"少了一个去重判断"。
/// 2. **推送时机漏了** —— 只在播放/暂停按钮里推，会漏掉手势 seek、
///    自动连播、内核内部状态跃迁。故状态同步挂在 `stateStream` 上。
///
/// 本文件用**可注入的假桥**断言"推了什么、推了几次"，
/// 不依赖 MethodChannel（`flutter test` 跑在桌面 VM，碰不到原生）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/infrastructure/session/session_bridge.dart';
import 'package:cineflow/player/kernel.dart';

/// 记录每次推送的假桥（替代真实的 MethodChannel）。
class _FakeBridge extends SessionBridge {
  _FakeBridge() : super.forTest();

  final List<Map<String, Object?>> calls = [];

  @override
  Future<void> updateState({
    String? title,
    String? subtitle,
    String? artworkUrl,
    Duration? duration,
    Duration? position,
    bool? isPlaying,
    bool? isBuffering,
    bool? hasMedia,
    double? speed,
  }) async {
    calls.add({
      'title': title,
      'subtitle': subtitle,
      'isPlaying': isPlaying,
      'isBuffering': isBuffering,
      'durationMs': duration?.inMilliseconds,
      'positionMs': position?.inMilliseconds,
    });
  }

  @override
  Future<void> clearState() async {
    calls.add({'cleared': true});
  }
}

KernelState _state({
  Duration position = Duration.zero,
  Duration duration = const Duration(minutes: 42),
  bool playing = true,
  bool buffering = false,
  double rate = 1.0,
}) =>
    KernelState(
      position: position,
      duration: duration,
      buffer: Duration.zero,
      playing: playing,
      buffering: buffering,
      rate: rate,
      volume: 100,
    );

void main() {
  group('★ 会话状态同步：去重（防通知栏闪烁）', () {
    test('同一秒内的进度变化**只推一次**', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);

      // 250ms 一次的位置推送 —— 4 次都在同一秒内
      sync.sync(_state(position: Duration.zero));
      sync.sync(_state(position: const Duration(milliseconds: 250)));
      sync.sync(_state(position: const Duration(milliseconds: 500)));
      sync.sync(_state(position: const Duration(milliseconds: 750)));

      expect(b.calls.length, 1,
          reason: '★ 同一秒内推进度必须去重 —— 否则原生侧每秒重建 4 次通知，\n'
              '    表现为"通知栏闪烁"，且很难归因到缺少去重判断。');
    });

    test('跨秒后**会**推（进度条要动）', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);

      sync.sync(_state(position: Duration.zero));
      sync.sync(_state(position: const Duration(seconds: 1)));
      sync.sync(_state(position: const Duration(seconds: 2)));

      expect(b.calls.length, 3,
          reason: '每秒推一次是预期节奏（通知栏进度条要看得见地走）');
    });

    test('★ 播放/暂停变化**立即推**（不能因去重而漏）', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);

      // 位置完全没变，只改 playing
      sync.sync(_state(playing: true));
      sync.sync(_state(playing: false));
      sync.sync(_state(playing: true));

      expect(b.calls.length, 3,
          reason: '★ 去重只能针对"进度"，播放状态变化必须每次都推 ——\n'
              '    否则通知栏按钮会停在错误状态（显示暂停实际在播）。');
      expect(b.calls[1]['isPlaying'], isFalse);
      expect(b.calls[2]['isPlaying'], isTrue);
    });

    test('缓冲状态变化也会推', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);

      sync.sync(_state(buffering: false));
      sync.sync(_state(buffering: true));

      expect(b.calls.length, 2);
      expect(b.calls[1]['isBuffering'], isTrue);
    });

    test('时长变化会推（服务端可能后给时长）', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);

      sync.sync(_state(duration: Duration.zero));
      sync.sync(_state(duration: const Duration(minutes: 42)));

      expect(b.calls.length, 2);
      expect(b.calls[1]['durationMs'], 42 * 60 * 1000);
    });

    test('完全相同的状态**不推**', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);

      sync.sync(_state());
      sync.sync(_state());

      expect(b.calls.length, 1);
    });
  });

  group('★ 会话状态同步：媒体信息', () {
    test('标题进通知栏（起播时设置）', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);
      sync.setMediaInfo(
        title: '第 3 集 · 秦明以身入局',
        subtitle: '法医秦明之龙番往事',
      );

      sync.sync(_state());

      expect(b.calls.single['title'], '第 3 集 · 秦明以身入局');
      expect(b.calls.single['subtitle'], '法医秦明之龙番往事');
    });

    test('换集后标题跟着变（自动连播场景）', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);

      sync.setMediaInfo(title: '第 3 集');
      sync.sync(_state());
      // 自动连播 → 换集 → 重新设标题
      sync.setMediaInfo(title: '第 4 集');
      sync.sync(_state(playing: false)); // 状态变化以触发推送

      expect(b.calls[1]['title'], '第 4 集',
          reason: '自动连播换集后通知栏必须更新，否则会一直显示上一集');
    });
  });

  group('★ 清理（退出播放器）', () {
    test('clear 会通知原生清空', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);
      sync.setMediaInfo(title: '第 3 集');
      sync.sync(_state());

      sync.clear();

      expect(b.calls.last['cleared'], isTrue,
          reason: '★ 不清的话退出播放器后通知栏还挂着"正在播放某剧"，\n'
              '    点它会把命令发给一个已销毁的内核。');
    });

    test('clear 后再 sync 会重新推（新一集）', () {
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);
      sync.sync(_state());
      sync.clear();
      final before = b.calls.length;
      sync.sync(_state()); // clear 已重置 _last

      expect(b.calls.length, before + 1,
          reason: 'clear 必须重置去重缓存，否则下次起播的第一次状态会被误判为"没变化"');
    });

    test('★ clear 必须清掉**媒体信息**（否则下一集会显示上一集的标题）', () {
      // ## 这条断言是**反向注入发现的缺口**
      // 原来只断言了"通知了原生 clear"，但没验证 `_title` 等内部字段是否复位。
      // 注入"注释掉 _title = '' 那几行"后，测试**仍然全绿** ⇒ 说明有盲区。
      //
      // 真实后果：退出播放器 → 进另一部剧 → 通知栏先显示**上一部**的标题
      //（直到第一次 sync 把新标题推上去）。观感是"通知栏串台"。
      final b = _FakeBridge();
      final sync = SessionStateSync(bridge: b);
      sync.setMediaInfo(title: '第 3 集', subtitle: '上一部剧');
      sync.sync(_state());

      sync.clear();
      // clear 之后**不**重新 setMediaInfo，直接 sync ——
      // 模拟"新一集还没走完 setMediaInfo 就被 sync 到"的时序
      sync.sync(_state(playing: false));

      final last = b.calls.last;
      expect(last['title'], isNot('第 3 集'),
          reason: '★ clear 后不得残留上一集的标题 —— 否则通知栏会短暂"串台"，\n'
              '    显示上一部剧的名字。');
      expect(last['subtitle'], isNot('上一部剧'),
          reason: '副标题同理');
    });
  });
}
