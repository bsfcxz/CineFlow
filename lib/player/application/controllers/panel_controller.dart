/// 面板控制器 —— 负责"哪个抽屉开着"这一件事。
///
/// ## 互斥（规格 §10.4）
/// 同时只能开一个面板。实现方式：单一枚举字段 [PanelState.open]，
/// **结构上就不可能同时开两个** —— 比"两个 bool 加互斥判断"可靠
/// （后者总有忘记关另一个的路径）。
///
/// ## 为什么面板状态要独立于 UI 显隐
/// 面板打开会**阻止 UI 自动隐藏**（规格 §8.2）。若两者混在一个状态里，
/// "面板开着但计时器已排"这种不一致状态就可能出现。
/// 拆开后 [UiVisibilityController] 通过 `hasOpenPanel` 回调读取本状态，
/// 单向依赖、无循环。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/panel_state.dart';

class PanelController extends Notifier<PanelState> {
  @override
  PanelState build() => const PanelState();

  /// 面板打开时的回调（UI 层注入：取消隐藏计时器、强制显示控制层）。
  void Function()? onOpened;

  /// 面板关闭时的回调（UI 层注入：重新安排隐藏）。
  void Function()? onClosed;

  bool get hasOpen => state.open != PanelType.none;

  /// 打开指定面板。已开同一个则**关闭**（再次点按钮 = 收起，符合直觉）。
  void open(PanelType type) {
    if (state.open == type) {
      closeAll();
      return;
    }
    state = state.copyWith(open: type);
    onOpened?.call();
  }

  /// 关闭所有面板。
  void closeAll() {
    if (state.open == PanelType.none) return;
    state = state.copyWith(open: PanelType.none);
    onClosed?.call();
  }

  /// 切换设置面板内的 Tab。
  ///
  /// Tab 切换**不影响**面板开关状态 —— 所以放在同一个 state 里但
  /// 用独立方法改，语义清楚。
  void switchSettingsTab(SettingsTab tab) {
    if (state.settingsTab == tab) return;
    state = state.copyWith(settingsTab: tab);
  }
}
