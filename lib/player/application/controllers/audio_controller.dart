/// 音频控制器（音频 Tab）。
///
/// ## 延迟的边界（规格 §7.6：−5s…+5s，步进 0.1s）
/// 钳制在**控制器内**做，UI 层的 `±` 按钮只管调
/// [stepDelay] —— 否则"到边界后按钮还能点"会让用户以为坏了。
///
/// ## 延迟的符号约定（容易搞反）
/// `delay > 0` = 音频**延后**播放（音轨慢于画面）。
/// mpv 的 `audio-delay` 与此**同号**，但 Media3 没有等价属性 ——
/// 走 Media3 时要自行做时间戳偏移（见 Media3Kernel 的说明）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/media_state.dart';

class AudioController extends Notifier<AudioState> {
  /// 延迟上限（规格 §7.6）。
  static const Duration maxDelay = Duration(seconds: 5);
  static const Duration minDelay = Duration(seconds: -5);

  /// 步进（规格 §7.6：0.1s）。
  static const Duration step = Duration(milliseconds: 100);

  @override
  AudioState build() => const AudioState();

  void Function(AudioState state)? onChanged;

  void _emit() => onChanged?.call(state);

  void setTracks(List<AudioTrack> tracks) {
    state = state.copyWith(tracks: tracks);
    _emit();
  }

  void selectTrack(String trackId) {
    if (state.activeTrackId == trackId) return;
    state = state.copyWith(activeTrackId: trackId);
    _emit();
  }

  /// 钳制延迟到 ±5s。
  ///
  /// 用 `Duration.compareTo` 而非直接比较：Duration 支持 `<` / `>`
  /// 但显式比较更清楚，且要处理"超过上限"的两种方向。
  static Duration clampDelay(Duration d) {
    if (d > maxDelay) return maxDelay;
    if (d < minDelay) return minDelay;
    return d;
  }

  void setDelay(Duration delay) {
    final v = clampDelay(delay);
    if (state.delay == v) return;
    state = state.copyWith(delay: v);
    _emit();
  }

  /// ±0.1s（UI 的减/加按钮）。
  void stepDelay(int steps) => setDelay(state.delay + step * steps);

  /// 音量 0.0–1.0（**用户操作**：滑块 / 手势）。
  ///
  /// 会触发 [onChanged] ⇒ 宿主据此**写系统音量**（K3.5 起的单一事实源）。
  void setVolume(double volume) {
    final v = volume.clamp(0.0, 1.0);
    if (state.volume == v) return;
    state = state.copyWith(volume: v);
    _emit();
  }

  /// 从**系统音量变化**同步（用户按了手机侧边键）。
  ///
  /// ## ★ 为什么故意**不**调 `_emit()`
  /// `_emit()` 会触发宿主的 `onVolumeChanged` ⇒ 那会去**写系统音量** ⇒
  /// 系统又发广播回来 ⇒ **"系统→UI→系统"回环**。
  ///
  /// 系统变化本来就是"既成事实"，UI 只需**跟随显示**，不该回写。
  ///
  /// ⚠️ 不 `_emit()` **不影响 UI 刷新** —— riverpod 的 `state` 一变，
  /// 监听它的 widget 就会重建。`_emit()` 只服务于"副作用通道"
  /// （把值应用到内核/系统），两件事是分开的（见本类头注释）。
  void syncFromSystem(double volume) {
    final v = volume.clamp(0.0, 1.0);
    if (state.volume == v) return;
    state = state.copyWith(volume: v);
    // 故意不调 _emit()：见上面的回环说明。**不要"顺手补上"**。
  }

  /// 是否可以再减（延迟已到 −5s）。
  bool get canDecrease => state.delay > minDelay;

  /// 是否可以再加。
  bool get canIncrease => state.delay < maxDelay;
}
