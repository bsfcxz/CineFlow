/// 视频变换（双指缩放/平移）的单元测试 —— 用户 2026-10-09 第 5 条。
///
/// ## 为什么纯函数必须全测
/// `VideoTransformMath` 是**唯一**做钳制的地方：
/// 边界（scale 上下限、平移越界）错了，画面会跑到视口外
/// 或"缩小到比 contain 还小"—— UI 层完全看不出（Transform 不报错）。
library;

import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/application/controllers/video_transform_controller.dart';

void main() {
  group('VideoZoomLimits', () {
    test('范围 1.0–4.0', () {
      expect(VideoZoomLimits.minScale, 1.0);
      expect(VideoZoomLimits.maxScale, 4.0);
    });
  });

  group('maxOffset（平移边界）', () {
    test('scale=1 时为 0（不许平移）', () {
      expect(VideoTransformState.maxOffset(scale: 1.0, viewport: 1000), 0);
    });

    test('scale=2、viewport=1000 ⇒ 500（超出部分的一半）', () {
      expect(VideoTransformState.maxOffset(scale: 2.0, viewport: 1000), 500);
    });

    test('scale=4、viewport=800 ⇒ 1200', () {
      expect(VideoTransformState.maxOffset(scale: 4.0, viewport: 800), 1200);
    });
  });

  group('VideoTransformMath.update', () {
    const vp = Size(1000, 500);

    test('两指张开 2 倍 ⇒ scale=2', () {
      final s = VideoTransformMath.update(
        s: const VideoTransformState(),
        scaleRatio: 2.0,
        panDelta: Offset.zero,
        viewport: vp,
      );
      expect(s.scale, closeTo(2.0, 0.0001));
      expect(s.isPinching, isTrue);
    });

    test('★ 超上限钳到 4.0（连乘也如此）', () {
      var s = const VideoTransformState();
      for (var i = 0; i < 10; i++) {
        s = VideoTransformMath.update(
            s: s, scaleRatio: 2.0, panDelta: Offset.zero, viewport: vp);
      }
      expect(s.scale, VideoZoomLimits.maxScale,
          reason: '★ 连续放大必须钳在上限 —— 否则画面缩到看不见');
    });

    test('★ 缩小钳到 1.0（不出现比 contain 更小的怪态）', () {
      final s = VideoTransformMath.update(
        s: const VideoTransformState(),
        scaleRatio: 0.5,
        panDelta: Offset.zero,
        viewport: vp,
      );
      expect(s.scale, VideoZoomLimits.minScale,
          reason: '★ 缩到 1 以下会出现"四周露黑还比原始小"的怪态');
    });

    test('★ 平移按新 scale 钳制（不会把画面推出视口）', () {
      var s = const VideoTransformState();
      s = VideoTransformMath.update(
          s: s, scaleRatio: 2.0, panDelta: Offset.zero, viewport: vp);
      // scale=2 ⇒ 边界 ±500（宽）
      s = VideoTransformMath.update(
          s: s, scaleRatio: 1.0, panDelta: const Offset(9999, 0), viewport: vp);
      expect(s.offset.dx, 500,
          reason: '★ 平移必须钳在 maxOffset 内 —— 否则画面跑出屏幕');
    });

    test('scale 回到 1 时平移必须归零', () {
      var s = const VideoTransformState();
      s = VideoTransformMath.update(
          s: s, scaleRatio: 2.0, panDelta: const Offset(100, 50), viewport: vp);
      s = VideoTransformMath.update(
          s: s, scaleRatio: 0.5, panDelta: Offset.zero, viewport: vp);
      expect(s.scale, 1.0);
      expect(s.offset, Offset.zero,
          reason: '★ scale==1 而 offset≠0 ⇒ 画面"悬空偏移"，必须归零');
    });
  });

  group('生命周期', () {
    const vp = Size(1000, 500);

    test('end：scale>1 保留缩放，isPinching=false', () {
      var s = VideoTransformMath.update(
          s: const VideoTransformState(),
          scaleRatio: 2.0,
          panDelta: Offset.zero,
          viewport: vp);
      s = VideoTransformMath.end(s);
      expect(s.scale, closeTo(2.0, 0.0001));
      expect(s.isPinching, isFalse);
    });

    test('end：scale 回 1 ⇒ 完全归位（settle）', () {
      var s = VideoTransformMath.update(
          s: const VideoTransformState(),
          scaleRatio: 1.5,
          panDelta: const Offset(120, 60),
          viewport: vp);
      s = VideoTransformMath.update(
          s: s, scaleRatio: 2 / 3, panDelta: Offset.zero, viewport: vp);
      s = VideoTransformMath.end(s);
      expect(s, const VideoTransformState(),
          reason: '★ 松手回 1.0 必须全归位 —— 否则"轻捏后画面永久偏移"');
    });

    test('reset：任何状态复位到初始', () {
      var s = VideoTransformMath.update(
          s: const VideoTransformState(),
          scaleRatio: 3.0,
          panDelta: const Offset(200, 100),
          viewport: vp);
      s = s.reset();
      expect(s, const VideoTransformState());
    });
  });
}
