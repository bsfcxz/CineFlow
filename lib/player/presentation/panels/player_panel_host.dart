/// 面板宿主（规格 §10）—— 抽屉容器 + 遮罩 + 进出动画。
///
/// ## 设计要点
/// 1. **一个宿主管三类抽屉**：左（播放列表）/ 右（设置、弹幕）。
///    不必每个面板各写一套动画与遮罩。
/// 2. **遮罩点击关闭**（规格 §10.5）：遮罩必须在抽屉**下层**，
///    否则点抽屉空白处也会关掉面板。
/// 3. **互斥由状态保证**：`PanelState.open` 是单一枚举，
///    本宿主只按它决定"哪个抽屉可见"，不做互斥判断（避免两处逻辑）。
library;

import 'package:flutter/material.dart';

import '../../domain/models/panel_state.dart';
import '../../../keys.dart';
import '../player_ui_tokens.dart';

/// 面板宿主。
class PlayerPanelHost extends StatelessWidget {
  const PlayerPanelHost({
    super.key,
    required this.state,
    required this.onClose,
    required this.playlist,
    required this.settings,
    required this.danmaku,
    this.availableWidth,
  });

  final PanelState state;
  final VoidCallback onClose;

  /// 三类抽屉内容（由 PlayerPage 组装，避免宿主依赖各 Controller）。
  final Widget playlist;
  final Widget settings;
  final Widget danmaku;

  /// 可用宽度（默认取 `MediaQuery`）。
  ///
  /// ⚠️ 用**可用宽**而不是屏幕宽：分屏/小窗下屏幕宽会把抽屉算得过大，
  /// 超出可用区域（本项目 U6 的抽屉已踩过这个坑）。
  final double? availableWidth;

  @override
  Widget build(BuildContext context) {
    final width = availableWidth ?? MediaQuery.sizeOf(context).width;
    return Stack(
      children: [
        // 遮罩（在抽屉下层）
        if (state.open != PanelType.none)
          Positioned.fill(
            child: GestureDetector(
              key: keys.player.panelMask,
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: const ColoredBox(color: PlayerUi.panelMask),
            ),
          ),

        // 左抽屉：播放列表
        _Drawer(
          visible: state.open == PanelType.playlist,
          fromLeft: true,
          width: PlayerUi.playlistWidth(width),
          child: playlist,
        ),

        // 右抽屉：设置
        _Drawer(
          visible: state.open == PanelType.settings,
          fromLeft: false,
          width: PlayerUi.settingsWidth(width),
          child: settings,
        ),

        // 右抽屉：弹幕（与设置互斥，位置相同）
        _Drawer(
          visible: state.open == PanelType.danmaku,
          fromLeft: false,
          width: PlayerUi.settingsWidth(width),
          child: danmaku,
        ),
      ],
    );
  }
}

/// 单个抽屉（滑入动画 + 尺寸）。
class _Drawer extends StatelessWidget {
  const _Drawer({
    required this.visible,
    required this.fromLeft,
    required this.width,
    required this.child,
  });

  final bool visible;
  final bool fromLeft;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      // 全部从"屏幕外侧"滑入：左抽屉 -1、右抽屉 +1
      offset: visible ? Offset.zero : Offset(fromLeft ? -1 : 1, 0),
      duration: PlayerPanelsDrawer.duration,
      curve: Curves.easeOutCubic,
      child: Align(
        alignment: fromLeft ? Alignment.centerLeft : Alignment.centerRight,
        child: IgnorePointer(
          // 收起时必须忽略指针 —— 否则隐藏的抽屉会**吃掉整屏手势**
          // （在屏幕外但尺寸仍在，能挡住底层的手势层）。
          ignoring: !visible,
          child: SizedBox(
            width: width,
            height: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: PlayerUi.panelBg,
                border: Border(
                  left: fromLeft
                      ? BorderSide.none
                      : const BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
                  right: fromLeft
                      ? const BorderSide(color: Color(0x1AFFFFFF), width: 0.5)
                      : BorderSide.none,
                ),
              ),
              child: SafeArea(
                left: fromLeft,
                right: !fromLeft,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 抽屉与 Tab 的动画时长（避免宿主机依赖 `player_constants`，
/// 那会让 presentation 层多一个 domain 依赖）。
///
/// 值取自规格 §10.6：抽屉 350ms、Tab 切换 200ms。
abstract final class PlayerPanelsDrawer {
  static const Duration duration = Duration(milliseconds: 350);
  static const Duration tabDuration = Duration(milliseconds: 200);
}

/// 面板头部（标题 + 关闭按钮）—— 三类抽屉共用。
class PanelHeader extends StatelessWidget {
  const PanelHeader({
    super.key,
    required this.title,
    required this.onClose,
    this.trailing,
  });

  final String title;
  final VoidCallback onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: PlayerUi.panelHeaderHeight,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?trailing,
          IconButton(
            key: keys.player.panelClose,
            onPressed: onClose,
            icon: const Icon(Icons.close),
            color: Colors.white70,
            iconSize: 20,
            tooltip: '关闭',
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// 面板 Tab 栏（规格 §7.6：四个 Tab，选中态蓝底蓝字）。
class PanelTabs<T> extends StatelessWidget {
  const PanelTabs({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
    required this.labelOf,
  });

  final List<T> tabs;
  final T value;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        children: [
          for (final t in tabs) ...[
            Expanded(
              child: _Tab(
                text: labelOf(t),
                active: t == value,
                onTap: () => onChanged(t),
              ),
            ),
            if (t != tabs.last) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.text, required this.active, required this.onTap});

  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PlayerUi.tabRadius),
        child: Container(
          height: PlayerUi.tabHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? PlayerUi.tabActiveBg : Colors.transparent,
            borderRadius: BorderRadius.circular(PlayerUi.tabRadius),
          ),
          child: Text(
            text,
            style: TextStyle(
              color:
                  active ? PlayerUi.tabActiveText : PlayerUi.tabInactiveText,
              fontSize: PlayerUi.valueSize,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
