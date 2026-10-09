/// 底栏操作按钮行（规格 §7.4 第二行）。
///
/// 左侧：上一项 / 下一项 / 列表 / 倍速；右侧：弹幕开关 / 弹幕设置 / 设置 / 全屏。
///
/// ## 为什么单独一个文件
/// 这一行有 8 个按钮、涉及 6 个 Controller。塞进 `player_bars.dart`
/// 会让那个文件同时管"顶栏/中部/底栏/进度条"四件事。
/// 独立后：`player_bars.dart` 只管道具形状，本文件只管"按钮怎么排、点了调谁"。
library;

import 'dart:ui' show FontFeature;

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
    this.playlistCount,
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

  /// 选集按钮的进度计数（形如 `3/24`）。
  ///
  /// ## 为 null 的语义（重要）
  /// **不显示计数**。适用两种情形：
  /// · 播放列表只有一项（电影）—— `1/1` 是无信息的噪声
  /// · 列表尚未就绪 —— 宁可少显示，也不要闪一个错的数字
  ///
  /// 由调用方组装成字符串（本组件不碰 `PlaylistState`，
  /// 保持"只依赖 props"的可测性 —— 见文件头说明）。
  final String? playlistCount;

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
            child: _IconBtn(
              key: keys['playlist'],
              // ★ 用户要求：文字「列表」→ **图标 + 进度计数**（如 3/24）
              //
              // ## 为什么用 `_CountBtn` 而不是普通 `_IconBtn`
              // 用户要看到"当前第几集 / 共几集" —— 单看图标不够，
              // 单看文字（列表）也没有进度信息。故图标与计数并排。
              icon: Icons.playlist_play,
              onTap: onOpenPlaylist,
              tooltip: '选集',
              // 计数：`当前位置/总数`。无播放列表（单曲/电影）时为 null ⇒ 只显示图标
              // （"1/1" 是噪声，用户看不出任何信息）。
              badge: playlistCount,
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
    this.badge,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  /// 图标右侧的小字（如 `3/24`）。
  ///
  /// ## 为什么不用 `IconButton` 的 `badge`
  /// Material 3 的 `Badge` 是**右上角浮标**（用于未读数），
  /// 而"第 3/24 集"是**并列信息**，横排更好读（也不遮图标）。
  ///
  /// ## 为什么省略号为 null 时不显示任何文字
  /// 见 `PlayerActionBar.playlistCount` 的注释：`1/1` 是无信息的噪声。
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(
      icon,
      shadows: const [
        // 两层阴影：近距实（保证轮廓）+ 远距虚（保证亮背景上的对比）
        Shadow(blurRadius: 4, color: Colors.black87),
        Shadow(blurRadius: 10, color: Colors.black54),
      ],
    );

    // 无计数时保持原有 `IconButton`（不改动既有布局预算 —— 见文件头
    // 的 8 按钮宽度计算；多一个 Text 会挤到窄屏）。
    if (badge == null || badge!.isEmpty) {
      return IconButton(
        onPressed: onTap,
        icon: iconWidget,
        iconSize: 22,
        color: Colors.white,
        disabledColor: Colors.white24,
        splashRadius: 22,
        tooltip: tooltip,
        constraints: const BoxConstraints(minWidth: 38, minHeight: 44),
        padding: EdgeInsets.zero,
      );
    }

    // 有计数：**角标叠在图标右下**（不是并排）。
    //
    // ## ⚠️ 为什么不能并排（实测崩溃）
    // 第一版写成 `Row([Icon(22), SizedBox(3), Text('3/24', 11px)])`
    // ⇒ 内容宽 ≈ 52dp，而底栏给每个按钮的预算下限是 **38dp**
    //（320dp 屏 / 8 按钮 ⇒ 38.5；见 `PlayerActionBar.build` 的宽度计算）
    // ⇒ 实测 `RenderFlex overflowed by 16 pixels`（被
    //   `player_ui_interaction_test` 抓到，正是那道防线的价值）。
    //
    // ## 叠放后宽度 = 图标宽度
    // 角标画在图标**右下角外侧**，不增加布局宽度 ⇒ 仍满足 38dp 预算。
    // 代价：角标会略微超出图标边界（用 `Positioned` 负偏移），
    // 但按钮本身有 38×44 的约束，实际不会被裁（`IconButton` 不裁剪 child）。
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      splashRadius: 22,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 44),
      padding: EdgeInsets.zero,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          iconWidget,
          Positioned(
            // 右下角：`right: -6` 让它探出图标一点（图标 22 宽，视觉重心仍在按钮内）
            right: -7,
            bottom: -3,
            child: Text(
              badge!,
              // 等宽数字：计数会随切集变化，不加会让整行左右抖动
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                height: 1.0,
                fontFeatures: [FontFeature.tabularFigures()],
                shadows: [
                  Shadow(blurRadius: 3, color: Colors.black87),
                  Shadow(blurRadius: 8, color: Colors.black54),
                ],
              ),
            ),
          ),
        ],
      ),
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
              // 同 _IconBtn：透明底栏下白字压亮画面的可读性保障
              shadows: const [
                Shadow(blurRadius: 4, color: Colors.black87),
                Shadow(blurRadius: 10, color: Colors.black54),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
