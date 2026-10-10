// 弹幕平滑渲染的守卫测试。
//
// ## 用户报障
// "弹幕播放看起来很卡顿不自然"
//
// ## 根因（代码取证）
// 弹幕位置完全由 `widget.position` 决定，而它来自内核 `stateStream` ——
// 那条流被**故意限流到 250ms**（`player_flow_page` 的 `_posFlushTimer`，
// 目的是"消除每帧重建整页"）。
// ⇒ 弹幕**每秒只移动 4 步**（4 FPS），视觉上是明显跳变。
//
// ## 修法
// 渲染层加**本地插值时钟**（`Ticker` vsync 驱动）：
//   平滑位置 = 内核位置（权威基准）+ 本地流逝时间 × 倍速
// 每次内核推送重置基准 ⇒ **不累积漂移**。
//
// ## 为什么这些断言必要
// 平滑逻辑是"看不见的"：删掉它编译通过、单测全绿、画面"也能看"，
// 只是**又变卡**。这类性能回归只能靠结构断言 + 真机观察守住。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
  group('★★ 弹幕平滑时钟（防"又变卡"回归）', () {
    late String o;

    setUpAll(() {
      o = code('lib/danmaku/danmaku_overlay.dart');
    });

    test('★★ 必须有 Ticker 驱动的插值时钟', () {
      expect(o.contains('createTicker(_onTick)'), isTrue,
          reason: '★★ 没有 vsync 时钟 ⇒ 弹幕只能跟着 250ms 的 position\n'
              '    跳变（4 FPS）—— 用户报障"卡顿不自然"的根因。');
      expect(o.contains('SingleTickerProviderStateMixin'), isTrue,
          reason: '★ Ticker 需要 TickerProvider');
    });

    test('★★ 外推必须有基准位置 + 基准时刻（不累积漂移）', () {
      expect(o.contains('_basePos = widget.position'), isTrue,
          reason: '★★ 每次内核推送都要**重置基准** ——\n'
              '    基准必须来自内核（权威），不能纯本地累加，\n'
              '    否则长时间播放会漂移到与视频不同步。');
      expect(o.contains('_baseAt = _lastTick'), isTrue,
          reason: '★ 基准落地时刻必须记录，否则算不出流逝量');
      expect(o.contains('final next = _basePos + capped * widget.speed'),
          isTrue,
          reason: '★ 外推公式：基准 + 流逝 × 倍速');
    });

    test('★★ 暂停时必须停止外推', () {
      // 否则：画面停住、弹幕还在飞 —— 明显错误
      final i = o.indexOf('void _onTick(');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 _onTick');
      final end = o.indexOf('void didUpdateWidget', i);
      expect(end, greaterThan(i), reason: '找不到 _onTick 边界');
      final seg = o.substring(i, end);
      expect(seg.contains('if (!widget.playing)'), isTrue,
          reason: '★★ 暂停时不得外推 —— 否则画面停住弹幕还在飞');
    });

    test('★ 外推必须有上限（内核卡住时不能无限飞）', () {
      expect(o.contains('const Duration(milliseconds: 400)'), isTrue,
          reason: '★ 若内核长时间不给新位置（卡住/断流），\n'
              '    无上限外推会让弹幕飞到时间轴之外');
    });

    test('★ seek 回跳必须直接跳（不能"倒着飞"）', () {
      expect(o.contains('if (widget.position < _smoothPos)'), isTrue,
          reason: '★ 回跳时若还做平滑，会看到弹幕倒着飞');
    });

    test('★ paint 用的是插值位置，不是原始 position', () {
      final i = o.indexOf('painter: _DanmakuPainter(');
      expect(i, greaterThanOrEqualTo(0));
      final seg = o.substring(i, (i + 220).clamp(0, o.length));
      expect(seg.contains('position: _smoothPos'), isTrue,
          reason: '★ 必须把**插值后**的位置交给 painter ——\n'
              '    交 widget.position 就等于没做平滑。');
    });

    test('★ Ticker 必须 dispose（否则内存/回调泄漏）', () {
      expect(o.contains('_ticker?.dispose()'), isTrue);
    });
  });

  group('★ 宿主必须把 playing 传进来', () {
    test('★ DanmakuOverlay 有 playing 参数且宿主已接线', () {
      final ov = code('lib/danmaku/danmaku_overlay.dart');
      expect(ov.contains('this.playing = true'), isTrue,
          reason: '★ 默认 true 保持向后兼容（旧调用点不传也能用）');

      final host = code('lib/player/player_flow_page.dart');
      expect(host.contains('playing: playing'), isTrue,
          reason: '★ 宿主必须传真实播放状态 —— 否则暂停判断永远为 true');
      expect(host.contains('s.isPlaying'), isTrue,
          reason: '★ 字段名是 `isPlaying`（PlaybackState 的定义），不是 `playing`');
    });
  });
}
