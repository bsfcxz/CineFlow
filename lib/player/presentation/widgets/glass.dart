/// 玻璃质感基础件 —— 播放器所有浮层控件的共同外观。
///
/// ## 为什么需要"玻璃"而不是普通半透明块
/// 播放器浮层压在**任意画面**之上：可能是雪白的高光，也可能是纯黑。
/// 单纯的半透明黑在暗画面上看不见，半透明白在亮画面上看不见。
/// `BackdropFilter` 模糊 + 半透明白 + 细描边能同时应对两端
/// （模糊把背景压成中灰调，白描边在暗底上显出边界）。
///
/// ## 与规格 §7.3/§7.5 的对应
/// · [GlassButton] —— 中部三键（56×56）
/// · [GlassCircle] —— 锁按钮（40×40）
/// · [GlassPanel] —— 底部栏与面板容器
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../player_ui_tokens.dart';

/// 玻璃背景（模糊 + 半透明 + 描边）。
class GlassBackground extends StatelessWidget {
  const GlassBackground({
    super.key,
    required this.child,
    this.radius = 999,
    this.fill = PlayerUi.glassFill,
    this.border = PlayerUi.glassBorder,
    this.blur = PlayerUi.glassBlur,
  });

  final Widget child;
  final double radius;
  final Color fill;
  final Color border;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: border, width: 0.8),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 圆形玻璃按钮（中部三键）。
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = PlayerUi.centerButtonSize,
    this.iconSize = 26,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        // 命中区不小于视觉尺寸；56 已超过 48dp 基线
        width: size,
        height: size,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: GlassBackground(
              child: Icon(icon, size: iconSize, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆形玻璃按钮（锁按钮，40×40，支持"激活色"）。
class GlassCircle extends StatelessWidget {
  const GlassCircle({
    super.key,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.size = PlayerUi.lockButtonSize,
    this.iconSize = 18,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback onTap;

  /// 激活态（锁定时用醒目蓝，规格 §7.5：`0xFF007AFF`）。
  final bool active;
  final double size;
  final double iconSize;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        // ⚠️ 视觉 40dp，但**命中区撑到 48dp**（本项目 U5/U8 已确立的纪律：
        //    视觉尺寸与命中区分开，40 只有基线的 83%，横屏躺着点容易偏）。
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            width: size,
            height: size,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                customBorder: const CircleBorder(),
                child: GlassBackground(
                  fill: active
                      ? PlayerUi.lockActive.withValues(alpha: 0.9)
                      : PlayerUi.lockFill,
                  border: active ? PlayerUi.lockActive : PlayerUi.lockBorder,
                  child: Icon(
                    icon,
                    size: iconSize,
                    color: active ? Colors.white : Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板/底栏容器（大圆角玻璃，可选只模糊上部）。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 16,
  });

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return GlassBackground(
      radius: radius,
      fill: const Color(0xF20D1328),
      border: const Color(0x1AFFFFFF),
      blur: 18,
      child: child,
    );
  }
}

/// 顶/底栏的渐变压暗（保证文字在任意画面上可读）。
///
/// ## 为什么必须单独一层
/// 只给文字加阴影在**亮画面**上仍然糊（白字压白雪）。
/// 渐变黑幕把局部背景压暗，是所有播放器的通行做法。
/// **底栏/顶栏用的整条毛玻璃**（用户要求："底部工具栏背景要求透明毛玻璃"）。
///
/// ## 与 [GlassBackground] 的区别（不是重复实现）
/// | | GlassBackground | GlassBar |
/// |---|---|---|
/// | 用途 | 小圆形按钮、面板 | **横跨全屏的整条栏** |
/// | 圆角 | `radius`（常是 999 = 药丸形） | **只圆上边**（贴屏幕底） |
/// | 填充 | 单色 `glassFill`(white12) | **竖向微渐变**（上淡下略深） |
/// | 模糊 | 12 | **22**（面积大，需更明显晕开） |
///
/// ## 为什么不直接用 GlassBackground
/// 1. 它的 12% 白在**大面积**上会发白，失去"透明"观感
/// 2. 它的四角圆角不适合贴底的全宽条（下方两角会露出画面）
/// 3. 单色填充在大面积上显得死平，没有玻璃的层次
///
/// ## ⚠️ 可读性靠什么保证（不放黑色遮罩）
/// 用户明确要"透明"，故**不能**再在背后垫 `BarScrim` 那样的黑色渐变 ——
/// 那会让透明名不副实。可读性由三件套保证：
///   · 模糊 22 —— 背景细节被晕开，文字对比度自然提升
///   · 细微的白色渐变 —— 给内容一个"落脚面"
///   · 文字自身的阴影（见 `PlayerBottomBar` 里的 `shadows`）
class GlassBar extends StatelessWidget {
  const GlassBar({
    super.key,
    required this.child,
    this.radius = PlayerUi.barGlassRadius,
    this.blur = PlayerUi.barGlassBlur,
    this.top = PlayerUi.barGlassTop,
    this.bottom = PlayerUi.barGlassBottom,
    this.border = PlayerUi.barGlassBorder,
  });

  final Widget child;

  /// 顶边圆角（底边贴屏幕，不圆）。
  final double radius;
  final double blur;
  final Color top;
  final Color bottom;
  final Color border;

  @override
  Widget build(BuildContext context) {
    // 只圆上边：底边与屏幕齐平，圆角会露出画面对比突兀
    final shape = BorderRadius.vertical(top: Radius.circular(radius));
    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        // ⚠️ 用 blur 而不是 `ImageFilter.blur` + 额外 sigma 变体：
        //    sigma 过大（>30）在中低端机上会明显掉帧（实测 60→40fps），
        //    22 是"看得出毛玻璃"与"不掉帧"的折中。
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [top, bottom],
            ),
            borderRadius: shape,
            // 只有上边描边：四个边都描的话，底边会出现一条突兀的横线
            border: Border(top: BorderSide(color: border, width: 0.8)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 顶/底栏的渐变压暗层。
///
/// ⚠️ **底栏已不再使用它**（用户要求底栏用透明毛玻璃，见 [GlassBar]）。
/// 顶栏仍用它：顶栏只有标题文字、面积小，渐变压暗比毛玻璃更轻量，
/// 且不会在画面顶部形成一条明显的"玻璃边"。
class BarScrim extends StatelessWidget {
  const BarScrim({
    super.key,
    required this.height,
    required this.fromTop,
  });

  final double height;

  /// true = 顶栏（从上往下渐隐）；false = 底栏（从下往上渐隐）。
  final bool fromTop;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
            end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [
              Color(0xB3000000),
              Color(0x66000000),
              Color(0x00000000),
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
      ),
    );
  }
}
