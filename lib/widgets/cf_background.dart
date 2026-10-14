import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// **应用背景层**（用户 2026-10-14：六档底色 + 自定义）。
///
/// ## 为什么必须有这一层（而不是只改 `Cf.bg` 颜色）
/// `Cf.bg` 只是 `Color` —— 它**做不到**"模糊"：
/// | 档 | 纯颜色够吗 | 说明 |
/// |---|---|---|
/// | 深色 / 黑色 / 浅白 / 白色 / 自定义 | ✅ | 只改颜色 |
/// | **透明** | ⚠️ | 全透时**下面必须有东西**，否则一片黑 |
/// | **半透明** | ⚠️ | 同上 + 可选模糊 |
/// ⇒ 本组件统一承载"背景"的**视觉实现**；页面只需包一层。
///
/// ## 用法
/// ```dart
/// Scaffold(
///   backgroundColor: Colors.transparent,   // ⚠️ 必须透明（否则盖住本层）
///   body: CfBackground(child: ...),
/// )
/// ```
///
/// ## 关于「毛玻璃」
/// 用户早期提过"毛玻璃"，最终六档没单列 —— 但它与「半透明」**不是一回事**
/// （半透明只透不糊）。⇒ 这里在**透明/半透明档**保留模糊能力：
/// 用户把透明度调低时，模糊让前景文字更清晰（详见 `_blurFor`）。
class CfBackground extends StatelessWidget {
  const CfBackground({super.key, required this.child});

  final Widget child;

  /// 是否给底图加模糊。
  ///
  /// ## 为什么"透明"不模糊、"半透明"模糊
  /// · **全透明**：用户明确要看壁纸 ⇒ 糊了反而怪
  /// · **半透明**：用户想看壁纸但也要能看清内容 ⇒ 模糊提升可读性
  /// ⇒ 这是**有意**的区别，不是漏写。
  bool get _blur => Cf.bgKind == CfBgKind.translucent;

  @override
  Widget build(BuildContext context) {
    switch (Cf.bgKind) {
      case CfBgKind.dark:
      case CfBgKind.black:
      case CfBgKind.dimWhite:
      case CfBgKind.solidWhite:
      case CfBgKind.custom:
        // 纯色档：与改动前一致（无额外层）
        return ColoredBox(color: Cf.bg, child: child);

      case CfBgKind.clear:
      case CfBgKind.translucent:
        // 透出/半透：底图 + （必要时）模糊 + 半透明罩
        return Stack(
          fit: StackFit.expand,
          children: [
            // ① 底图（模糊需要可糊的内容 / 全透需要可见的底）
            const _GradientBackdrop(),
            // ② 模糊（仅半透明档）
            if (_blur)
              BackdropFilter(
                // sigma 24 是实测观感较好的值（太小看不出、太大像马赛克）
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: const SizedBox.expand(),
              ),
            // ③ 半透明罩
            //
            // ⚠️ 全透明档 `Cf.bg` 的 alpha 就是 0 ⇒ 这一层不遮挡
            //    （`ColoredBox` 用 alpha=0 的颜色等于透明）
            ColoredBox(color: Cf.bg),
            child,
          ],
        );
    }
  }
}

/// 透明/半透明档的**底图**：主题色柔和光斑。
///
/// ## 为什么不引背景图
/// · 引图 ⇒ 增大 APK + 用户未必喜欢
/// · 用主题色光斑 ⇒ **自动适配任何主题色**，体积为零
///
/// ## 为什么不用系统壁纸
/// Flutter **读不到**系统壁纸（Android 没有公开 API，且隐私受限）。
/// ⇒ 全透明档实际看到的是"本组件的光斑"，而非桌面壁纸。
///   这是**平台限制**，已在 UI 文案里说明（见外观页的提示）。
class _GradientBackdrop extends StatelessWidget {
  const _GradientBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.6, -0.9),
          radius: 1.5,
          colors: [
            Cf.accent.withValues(alpha: 0.55),
            Cf.bgKind == CfBgKind.clear ? const Color(0xFF0B0D12) : Cf.bg,
          ],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.9, 0.95),
            radius: 1.4,
            colors: [
              Cf.accent3.withValues(alpha: 0.50),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }
}
