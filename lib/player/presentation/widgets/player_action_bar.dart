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
    // ⚠️ 8 个按钮在窄屏上放不下 —— 实测 360dp 屏溢出 16px（整行可见地坏掉）。
    //
    // 宽度预算（实测计算）：
    //   320dp 屏 → 可用 308 → 每按钮 38.5
    //   360dp 屏 → 可用 348 → 每按钮 43.5
    //   411dp 屏 → 可用 399 → 每按钮 49.9
    //
    // 故取 **38dp 为下限**，并用 `Flexible` 让宽屏上的按钮按比例分到更多空间
    // （固定 38 会让大屏显得稀疏）。
    // 取 38 而不是 40：`40 × 8 = 320 > 308`，会在最小屏（320dp）上溢出。
    // 溢出比触控区小 2dp 严重得多 —— 前者整行坏掉，后者仍可点。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Flexible(
            child: _IconBtn(
              key: keys['prev'],
              icon: Icons.skip_previous,
              onTap: hasPrevious ? onPrevious : null,
              tooltip: '上一项',
            ),
          ),
          Flexible(
            child: _IconBtn(
              key: keys['next'],
              icon: Icons.skip_next,
              onTap: hasNext ? onNext : null,
              tooltip: '下一项',
            ),
          ),
          Flexible(
            child: _TextBtn(
              key: keys['playlist'],
              text: '列表',
              onTap: onOpenPlaylist,
            ),
          ),
          Flexible(
            child: _TextBtn(
              key: keys['speed'],
              text: speedLabel,
              onTap: onCycleSpeed,
              active: speedLabel != '1.0x',
            ),
          ),
          const Spacer(),
          Flexible(
            child: _TextBtn(
              key: keys['danmakuToggle'],
              text: '弹',
              onTap: onToggleDanmaku,
              active: danmakuEnabled,
            ),
          ),
          Flexible(
            child: _IconBtn(
              key: keys['danmakuSettings'],
              icon: Icons.subtitles_outlined,
              onTap: onOpenDanmakuSettings,
              tooltip: '弹幕设置',
            ),
          ),
          Flexible(
            child: _IconBtn(
              key: keys['settings'],
              icon: Icons.settings_outlined,
              onTap: onOpenSettings,
              tooltip: '设置',
            ),
          ),
          Flexible(
            child: _IconBtn(
              key: keys['fullscreen'],
              icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              onTap: onToggleFullscreen,
              tooltip: fullscreen ? '退出全屏' : '全屏',
            ),
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
      // ⚠️ 38×44：宽度受「8 个按钮在 320dp 屏上的预算」约束
      //    （见 PlayerActionBar.build 里的计算）。用 44 会在 320dp 屏上溢出。
      constraints: const BoxConstraints(minWidth: 38, minHeight: 44),
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
          // 宽度同 _IconBtn（38 是 320dp 屏上的预算下限）
          constraints: const BoxConstraints(minHeight: 44, minWidth: 38),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: Text(
            text,
            style: TextStyle(
              color: active ? PlayerUi.progressFilled : Colors.white,
              fontSize: PlayerUi.segmentSize,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
