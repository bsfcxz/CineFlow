/// 底栏操作按钮行（规格 §7.4 第二行）。
///
/// 左侧：上一项 / 下一项 / 列表 / 倍速；右侧：弹幕开关 / 弹幕设置 / 设置 / 全屏。
///
/// ## 为什么单独一个文件
/// 这一行有 8 个按钮、涉及 6 个 Controller。塞进 `player_bars.dart`
/// 会让那个文件同时管"顶栏/中部/底栏/进度条"四件事。
/// 独立后：`player_bars.dart` 只管道具形状，本文件只管"按钮怎么排、点了调谁"。
library;

import 'package:flutter/material.dart';

import '../player_ui_tokens.dart';

/// 底栏按钮行。
class PlayerActionBar extends StatelessWidget {
  const PlayerActionBar({
    super.key,
    required this.speedLabel,
    required this.onPrevious,
    required this.onNext,
    required this.onCycleSpeed,
    required this.onOpenPlaylist,
    required this.onToggleDanmaku,
    required this.onOpenDanmakuSettings,
    required this.onOpenSettings,
    required this.onToggleFullscreen,
    required this.hasPrevious,
    required this.hasNext,
    required this.danmakuEnabled,
    required this.fullscreen,
    this.keys = const {},
  });

  final String speedLabel;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onCycleSpeed;
  final VoidCallback onOpenPlaylist;
  final VoidCallback onToggleDanmaku;
  final VoidCallback onOpenDanmakuSettings;
  final VoidCallback onOpenSettings;
  final VoidCallback onToggleFullscreen;

  /// 上一项/下一项是否可用（到头时置灰而不是隐藏 —— 隐藏会让按钮位置跳动）。
  final bool hasPrevious;
  final bool hasNext;
  final bool danmakuEnabled;
  final bool fullscreen;

  /// 测试键（`PlayerKeys` 里的项）。
  final Map<String, Key> keys;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          _IconBtn(
            key: keys['prev'],
            icon: Icons.skip_previous,
            onTap: hasPrevious ? onPrevious : null,
            tooltip: '上一项',
          ),
          _IconBtn(
            key: keys['next'],
            icon: Icons.skip_next,
            onTap: hasNext ? onNext : null,
            tooltip: '下一项',
          ),
          _TextBtn(
            key: keys['playlist'],
            text: '列表',
            onTap: onOpenPlaylist,
          ),
          _TextBtn(
            key: keys['speed'],
            text: speedLabel,
            onTap: onCycleSpeed,
            // 倍速是"当前值即按钮文案"，用高亮表示它被改过（≠1.0x）
            active: speedLabel != '1.0x',
          ),
          const Spacer(),
          _TextBtn(
            key: keys['danmakuToggle'],
            text: '弹',
            onTap: onToggleDanmaku,
            active: danmakuEnabled,
          ),
          _IconBtn(
            key: keys['danmakuSettings'],
            icon: Icons.subtitles_outlined,
            onTap: onOpenDanmakuSettings,
            tooltip: '弹幕设置',
          ),
          _IconBtn(
            key: keys['settings'],
            icon: Icons.settings_outlined,
            onTap: onOpenSettings,
            tooltip: '设置',
          ),
          _IconBtn(
            key: keys['fullscreen'],
            icon: fullscreen
                ? Icons.fullscreen_exit
                : Icons.fullscreen,
            onTap: onToggleFullscreen,
            tooltip: fullscreen ? '退出全屏' : '全屏',
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon),
      iconSize: 22,
      color: Colors.white,
      disabledColor: Colors.white24,
      splashRadius: 22,
      tooltip: tooltip,
      // 命中区 44×44：底栏密集排布下 48 会显得疏，44 仍高于可点基线
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.zero,
    );
  }
}

class _TextBtn extends StatelessWidget {
  const _TextBtn({
    super.key,
    required this.text,
    required this.onTap,
    this.active = false,
  });

  final String text;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PlayerUi.tabRadius),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: Text(
            text,
            style: TextStyle(
              color: active ? PlayerUi.progressFilled : Colors.white,
              fontSize: PlayerUi.valueSize,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
