/// 画面参数控制器（视频 Tab）。
///
/// ## 边界
/// 只管"画面怎么显示"：比例、解码方式、亮度/对比度/饱和度/色相。
/// **不管**轨道选择（那是音频/字幕控制器的事）。
///
/// ## ⚠️ 亮度有两套，别混
/// 1. **系统亮度**（手势上下滑，`screen_brightness` 插件）—— 改的是背光
/// 2. **画面参数亮度**（本控制器，`-100…+100`）—— 改的是**像素值**
///
/// 两者都叫"亮度"但完全不同：前者在暗环境下降背光更省电；
/// 后者不影响背光，是滤镜。原型把它们放在不同 state 字段
/// （`display.brightness` vs `settings.videoBrightness`），本实现沿用。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/media_state.dart';
import '../../domain/player_constants.dart';

class VideoController extends Notifier<VideoState> {
  @override
  VideoState build() => const VideoState();

  /// 引擎回调（UI 层注入：把参数变化应用到内核）。
  ///
  /// 用回调而不是直接持有引擎引用 —— 便于单测（无引擎即可断言状态变化）。
  void Function(VideoState state)? onChanged;

  void _emit() => onChanged?.call(state);

  void setAspectMode(AspectMode mode) {
    if (state.aspectMode == mode) return;
    state = state.copyWith(aspectMode: mode);
    _emit();
  }

  /// 循环切换画面比例（底部/顶栏的快捷按钮用）。
  void cycleAspectMode() {
    const order = AspectMode.values;
    final i = order.indexOf(state.aspectMode);
    setAspectMode(order[(i + 1) % order.length]);
  }

  void setDecodeMode(DecodeMode mode) {
    if (state.decodeMode == mode) return;
    state = state.copyWith(decodeMode: mode);
    _emit();
  }

  void setBrightness(double v) => _set(brightness: v.clamp(-100.0, 100.0));
  void setContrast(double v) => _set(contrast: v.clamp(-100.0, 100.0));
  void setSaturation(double v) => _set(saturation: v.clamp(-100.0, 100.0));
  void setHue(double v) => _set(hue: v.clamp(-180.0, 180.0));

  void _set({
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
  }) {
    final next = state.copyWith(
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      hue: hue,
    );
    if (next == state) return;
    state = next;
    _emit();
  }

  /// 画面参数复位（保留比例与解码方式 —— 那两个是"选择"不是"微调"）。
  void resetFilters() {
    if (state.isNeutral) return;
    state = state.reset();
    _emit();
  }
}
