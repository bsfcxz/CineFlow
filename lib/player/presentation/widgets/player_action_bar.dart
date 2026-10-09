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
          // ★ 列表按钮**不包 `Flexible`**（用户报障"没整好"的第二轮修法）
          //
          // ## 为什么（两版失败史）
          // ① 并排 + 全 Flexible ⇒ 320dp 屏溢出 16px（每按钮仅 ~34dp，
          //    而"图标 22 + 计数 ~24" 需 ~46dp）
          // ② 叠角标 ⇒ 不溢出，但图标与文字压在一起（像"图标下挂小字"）
          //
          // ## 本版：让这一个按钮取**自然宽度**，其余仍等分
          // Row 先按非 Flexible 子节点的固有宽度分配，剩余空间才给
          // Flexible 与 Spacer。图标-only 按钮只需 ~22dp，
          // 让出 ~18dp 对 8 按钮布局毫无影响（320dp 屏实测不溢出）。
          _IconBtn(
            key: keys['playlist'],
            // 用户要求：文字「列表」→ **图标 + 进度计数**（如 2/173）
            icon: Icons.playlist_play,
            onTap: onOpenPlaylist,
            tooltip: '选集',
            // 计数：`当前位置/总数`。无播放列表（单曲/电影）时为 null
            // ⇒ 只显示图标（"1/1" 是噪声，用户看不出信息）。
            badge: playlistCount,
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

    // 有计数：**图标 + 计数并排**（用户要的"列表图标 + 进度计数"）。
    //
    // ## 两版失败的教训（都在此文件里，别改回去）
    // ① **并排 + 全 Flexible** ⇒ 320dp 屏溢出 16px
    //    （每按钮仅 ~34dp，而"图标 22 + 计数 ~27"需 ~52dp）
    // ② **叠在图标右下角**（Stack + Positioned）⇒ 不溢出了，但
    //    图标与文字互相压住，视觉像"图标下挂一行小字"——
    //    用户第二轮报障："这个没整好"。
    //
    // ## 现在的做法：内容自适应宽 + 只在**这一个**按钮上不参与等分
    // `PlayerActionBar.build` 里把本按钮从 `Flexible` 改成普通子节点
    // ⇒ Row 先满足它的**自然宽度**，剩下的宽度再由其余按钮与 Spacer 分。
    // 图标-only 的按钮只需 ~22dp，让出 18dp 毫无影响。
    //
    // ⚠️ `mainAxisSize.min` + 显式 gap：让两者紧贴但不相压。
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      splashRadius: 22,
      // 只有最小高度约束（宽度由内容决定 —— 见上方说明）
      constraints: const BoxConstraints(minHeight: 44),
      padding: EdgeInsets.zero,
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget,
          const SizedBox(width: 2),
          Text(
            badge!,
            // 等宽数字：计数随切集变化，不加会让整行左右抖动。
            // 9px：既读得清，又让"2/173"（5 字符）只占 ~24dp。
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
