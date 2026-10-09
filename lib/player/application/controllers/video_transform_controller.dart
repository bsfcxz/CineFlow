/// 视频变换（双指缩放 + 平移）—— 用户 2026-10-09 要求第 5 条。
///
/// ## 设计
/// · **状态**：`scale`（1.0 = 原始）+ `offset`（平移量，逻辑像素）。
///   不可变、可单测（与 [GestureState] 同风格）。
/// · **钳制**：缩放 1.0–4.0（超范围回弹无意义，直接钳死；
///   <1.0 会出现"画面四周露黑还比 contain 小"的怪态）；
///   平移量随 scale 钳制，保证**画面永不脱离视口**（见 [_maxOffset]）。
/// · **复位**：双击复位？不 —— 双击已是"播放/暂停"。松手回到
///   scale==1 时自动归零 offset；提供 [reset] 给"换集/退出"调用。
///
/// ## 与单指手势的互斥（关键）
/// 双指进行中**必须**抑制单指手势（seek/亮度/音量/长按/单击），
/// 否则缩放时第二根手指会触发"音量狂飙"或"误判单击"。
/// 由 [GestureController.onTransformStart] 的调用方保证：
/// 进入 pinch 后单指手势层直接短路（UI 层读 `isPinching`）。
library;

import 'dart:ui' show Offset, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 缩放/平移限位（纯常量，便于测试引用）。
abstract final class VideoZoomLimits {
  /// 最小 = 原始（不允许缩小到比 contain 还小）。
  static const double minScale = 1.0;

  /// 最大 4 倍：再大像素糊且没有操作价值。
  static const double maxScale = 4.0;
}

/// 视频变换状态（不可变）。
class VideoTransformState {
  const VideoTransformState({
    this.scale = 1.0,
    this.offset = Offset.zero,
    this.isPinching = false,
  });

  /// 缩放倍数（1.0 = 原始）。
  final double scale;

  /// 平移偏移（逻辑像素；`scale == 1` 时恒为 zero）。
  final Offset offset;

  /// 双指是否按下（进行中）—— UI 层据此抑制单指手势与控制层自动隐藏。
  final bool isPinching;

  bool get isIdle => scale == 1.0 && offset == Offset.zero && !isPinching;

  /// 平移边界：scale 倍后画面超出视口的尺寸的一半。
  ///
  /// 平移量钳在 ±maxOffset 内 ⇒ 画面边缘**永不进入视口内部**
  ///（不会出现"缩放后画面跑到屏幕外看不见"）。
  static double maxOffset({required double scale, required double viewport}) {
    if (scale <= 1.0) return 0;
    return (viewport * scale - viewport) / 2;
  }

  VideoTransformState copyWith({
    double? scale,
    Offset? offset,
    bool? isPinching,
  }) =>
      VideoTransformState(
        scale: scale ?? this.scale,
        offset: offset ?? this.offset,
        isPinching: isPinching ?? this.isPinching,
      );

  /// 松手时的收尾：scale 回到 1 ⇒ 平移必须归零（否则"轻缩放后画面跑偏"）。
  VideoTransformState settle() =>
      scale <= 1.0 ? const VideoTransformState() : this;

  /// 完全复位（换集 / 退出播放页 / 双击重置场景）。
  VideoTransformState reset() => const VideoTransformState();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoTransformState &&
          other.scale == scale &&
          other.offset == offset &&
          other.isPinching == isPinching;

  @override
  int get hashCode => Object.hash(scale, offset, isPinching);
}

/// 纯函数：由双指事件算出下一状态（**不碰 widget**，全部可单测）。
abstract final class VideoTransformMath {
  /// 双指开始。
  static VideoTransformState start(VideoTransformState s) =>
      s.copyWith(isPinching: true);

  /// 缩放更新：`startScale × (currentSpan / startSpan)`，钳制后重算平移边界。
  static VideoTransformState update({
    required VideoTransformState s,
    required double scaleRatio,
    required Offset panDelta,
    required Size viewport,
  }) {
    final newScale =
        (s.scale * scaleRatio).clamp(VideoZoomLimits.minScale, VideoZoomLimits.maxScale);
    final mx = VideoTransformState.maxOffset(scale: newScale, viewport: viewport.width);
    final my = VideoTransformState.maxOffset(scale: newScale, viewport: viewport.height);
    final ox = (s.offset.dx + panDelta.dx).clamp(-mx, mx);
    final oy = (s.offset.dy + panDelta.dy).clamp(-my, my);
    return s.copyWith(
      scale: newScale,
      offset: Offset(ox, oy),
      isPinching: true,
    );
  }

  /// 双指结束：若回到 1.0 则完全归位。
  static VideoTransformState end(VideoTransformState s) =>
      s.copyWith(isPinching: false).settle();
}

/// Provider（宿主读、手势层写）。
final videoTransformProvider =
    NotifierProvider<VideoTransformController, VideoTransformState>(
        VideoTransformController.new);

class VideoTransformController extends Notifier<VideoTransformState> {
  @override
  VideoTransformState build() => const VideoTransformState();

  void pinchStart() => state = VideoTransformMath.start(state);

  void pinchUpdate({
    required double scaleRatio,
    required Offset panDelta,
    required Size viewport,
  }) =>
      state = VideoTransformMath.update(
        s: state,
        scaleRatio: scaleRatio,
        panDelta: panDelta,
        viewport: viewport,
      );

  void pinchEnd() => state = VideoTransformMath.end(state);

  /// 换集 / 退出播放页时复位（由宿主调用）。
  void reset() => state = state.reset();
}
