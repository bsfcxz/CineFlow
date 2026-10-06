/// 弹幕面板控制器（规格 §7.7 / §11）。
///
/// ## 职责
/// 持有**面板呈现单位**的状态（0–100%、1–10 档），并在变更时
/// 通过回调把换算后的值落回既有 `DanmakuConfig`。
///
/// ## 为什么不让本控制器直接依赖 DanmakuConfigNotifier
/// 那会让播放器面板依赖 `lib/danmaku/` 的具体 provider，
/// 单测必须启动完整 ProviderScope + 伪造 secure_storage。
/// 现在控制器是纯状态机，换算后的值经 `onPersist` 回调交给 UI 层，
/// UI 层再调既有 provider —— **依赖方向是单向的**，且测试廉价。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/danmaku_panel_state.dart';

class DanmakuPanelController extends Notifier<DanmakuPanelState> {
  @override
  DanmakuPanelState build() => const DanmakuPanelState();

  /// 换算后的配置落盘回调（UI 层注入）。
  ///
  /// 参数是**既有 `DanmakuConfig` 的单位**（opacity 0.2–1.0 / fontScale /
  /// speed / modes）。换算在 [DanmakuPanelState] 里完成，那里有单测。
  void Function({
    bool? enabled,
    double? opacity,
    double? fontScale,
    double? speed,
    DanmakuArea? area,
  })? onPersist;

  void _emit() => onPersist?.call(
        enabled: state.enabled,
        opacity: DanmakuPanelState.opacityToConfig(state.opacity),
        fontScale: DanmakuPanelState.fontSizeToConfig(state.fontSize),
        speed: DanmakuPanelState.speedToConfig(state.speedLevel),
        area: state.area,
      );

  /// 从既有配置同步（打开面板时调用，保证显示的是当前真实值）。
  void syncFromConfig({
    required bool enabled,
    required double opacity,
    required double fontScale,
    required double speed,
  }) {
    state = state.copyWith(
      enabled: enabled,
      opacity: DanmakuPanelState.opacityFromConfig(opacity),
      fontSize: DanmakuPanelState.fontSizeFromConfig(fontScale),
      speedLevel: DanmakuPanelState.speedFromConfig(speed),
    );
  }

  /// 切换开关。关闭时**不清空已加载的弹幕数据** ——
  /// 数据留着，再次打开立即恢复；清空只影响渲染层（见 §11.3）。
  void toggle() {
    state = state.copyWith(enabled: !state.enabled);
    _emit();
  }

  void setEnabled(bool value) {
    if (state.enabled == value) return;
    state = state.copyWith(enabled: value);
    _emit();
  }

  /// 透明度 0–100。
  void setOpacity(double percent) {
    final v = percent.clamp(0.0, 100.0);
    if (state.opacity == v) return;
    state = state.copyWith(opacity: v);
    _emit();
  }

  void setFontSize(DanmakuFontSize size) {
    if (state.fontSize == size) return;
    state = state.copyWith(fontSize: size);
    _emit();
  }

  /// 速度档 1–10。
  void setSpeedLevel(int level) {
    final v = level.clamp(1, 10);
    if (state.speedLevel == v) return;
    state = state.copyWith(speedLevel: v);
    _emit();
  }

  void setArea(DanmakuArea area) {
    if (state.area == area) return;
    state = state.copyWith(area: area);
    _emit();
  }

  /// 当前屏上弹幕数（供性能降采样判断，规格 §11.5）。
  void setActiveCount(int n) {
    if (state.activeCount == n) return;
    state = state.copyWith(activeCount: n);
  }

  /// 是否需要降采样（规格 §11.5：> 100 条）。
  bool get needsDownsampling => state.activeCount > 100;
}
