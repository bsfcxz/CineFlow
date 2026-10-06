/// 字幕控制器（字幕 Tab）。
///
/// ## 与外挂字幕加载的关系
/// 本控制器只持有**状态**（轨道列表、当前轨道、延迟、字号、编码）。
/// 真正的"读文件 + 探测编码 + 解析"交给 `ISubtitleLoader`
/// （infrastructure 层）—— 这样控制器保持纯状态机、可单测，
/// 且换解析实现（subtitle 包 / 自研解析器）不影响状态逻辑。
///
/// ## 编码为什么是"用户可调"而不是全自动
/// 中文字幕文件大量是 GBK/BIG5 却无 BOM，自动探测**无法保证 100% 正确**
/// （纯 ASCII 内容在两种编码下字节相同，无从判别）。
/// 故规格把编码做成可选项：默认 `auto`（先按 BOM，再按启发式），
/// 猜错时用户手动指定。这是"能修"比"猜得准"更重要的典型场景。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/media_state.dart';

class SubtitleController extends Notifier<SubtitleState> {
  static const Duration maxDelay = Duration(seconds: 5);
  static const Duration minDelay = Duration(seconds: -5);
  static const Duration step = Duration(milliseconds: 100);

  @override
  SubtitleState build() => const SubtitleState();

  void Function(SubtitleState state)? onChanged;

  /// 请求加载外挂字幕（由 UI 层注入 → 调 ISubtitleLoader）。
  void Function(SubtitleEncoding encoding)? onLoadExternalRequested;

  void _emit() => onChanged?.call(state);

  void setTracks(List<SubtitleTrack> tracks) {
    state = state.copyWith(tracks: tracks);
    _emit();
  }

  /// 选择字幕轨道；传 null 或 `SubtitleTrack.off.id` = 关闭字幕。
  void selectTrack(String? trackId) {
    final id = (trackId == null || trackId == SubtitleTrack.off.id) ? null : trackId;
    if (state.activeTrackId == id) return;
    state = state.copyWith(activeTrackId: id);
    _emit();
  }

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

  void stepDelay(int steps) => setDelay(state.delay + step * steps);

  void setFontSize(SubtitleFontSize size) {
    if (state.fontSize == size) return;
    state = state.copyWith(fontSize: size);
    _emit();
  }

  /// 切换编码。
  ///
  /// ★ 若当前已挂载外挂字幕，**必须重新解析** ——
  ///   否则改了编码但画面没变，用户会以为设置无效（实测常见困惑）。
  void setEncoding(SubtitleEncoding encoding) {
    if (state.encoding == encoding) return;
    state = state.copyWith(encoding: encoding);
    final hasExternal = state.tracks.any((t) => t.isExternal);
    if (hasExternal) onLoadExternalRequested?.call(encoding);
    _emit();
  }

  void setExternalLoading(bool loading) {
    if (state.isExternalLoading == loading) return;
    state = state.copyWith(isExternalLoading: loading);
    _emit();
  }

  /// 外挂字幕加载完成 → 加入轨道列表并自动选中（用户刚导入，显然想用）。
  void addExternalTrack(SubtitleTrack track) {
    final list = [...state.tracks.where((t) => t.id != track.id), track];
    state = state.copyWith(tracks: list, activeTrackId: track.id);
    _emit();
  }

  bool get canDecrease => state.delay > minDelay;
  bool get canIncrease => state.delay < maxDelay;
}
