import 'package:flutter/material.dart';

/// CineFlow 设计系统 —— 色彩令牌对应《CineFlow UI 设计文档》2.1 节
///
/// 主题色四选一（外观页）：accent / accent2 / accent3 与两个渐变是
/// **运行时可变**的（static 非 const），其余中性色保持 const。
/// 改动 Cf 主题色字段后，凡在 const 表达式里引用它们的构造都要去掉 const。
abstract final class Cf {
  static const bg = Color(0xFF0B1020); // 全局背景（深海军蓝）
  static const surface = Color(0xFF111A33); // 卡片
  static const surface2 = Color(0xFF162040); // 输入框等二级表面
  static const border = Color(0xFF1E2D55);
  static Color accent = const Color(0xFF00D4FF); // 主强调（青）·运行时可切换
  static Color accent2 = const Color(0xFF2E6BFF);
  static Color accent3 = const Color(0xFF6C5CE7);
  static const text = Color(0xFFE6F4FF);
  static const text2 = Color(0xFF8BA3CC);
  static const text3 = Color(0xFF5A6F99);
  static const success = Color(0xFF00E5A0);
  static const warn = Color(0xFFFFB347);
  static const danger = Color(0xFFFF6B6B);
  static const emby = Color(0xFF52B54B);
  static const ai = Color(0xFFC084FC);
  static const ink = Color(0xFF060A14); // 强调色按钮上的深色文字

  /// 主题色预设（外观页四选一，index 对应）：名称 / accent / accent2 / accent3
  static const themePresets = <(String, Color, Color, Color)>[
    ('青', Color(0xFF00D4FF), Color(0xFF2E6BFF), Color(0xFF6C5CE7)),
    ('绿', Color(0xFF52B54B), Color(0xFF00E5A0), Color(0xFF2E6BFF)),
    ('紫', Color(0xFF6C5CE7), Color(0xFFC084FC), Color(0xFF2E6BFF)),
    ('橙', Color(0xFFFF6B6B), Color(0xFFFFB347), Color(0xFF9B6BFF)),
  ];

  /// 应用主题预设（外观页保存 / 启动恢复时调用）
  static void applyTheme(int index) {
    final p = themePresets[index.clamp(0, themePresets.length - 1)];
    accent = p.$2;
    accent2 = p.$3;
    accent3 = p.$4;
    logoGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [accent, accent3],
    );
    primaryGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [accent, accent2],
    );
  }

  /// Logo / 主按钮渐变：accent → accent3（135deg）·随主题切换
  static LinearGradient logoGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, accent3],
  );

  /// 主按钮渐变：accent → accent2（135deg）·随主题切换
  static LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, accent2],
  );

  static ThemeData theme() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.dark(
        primary: accent,
        secondary: accent2,
        surface: bg,
        error: danger,
      ),
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: text,
        displayColor: text,
        fontFamily: null, // 跟随系统栈（PingFang SC / Noto Sans SC）
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        hintStyle: TextStyle(color: text3, fontSize: 12.5),
        contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        border: _inputBorder(),
        enabledBorder: _inputBorder(),
        focusedBorder: _inputBorder(const Color(0xFF00D4FF)),
      ),
    );
  }

  static OutlineInputBorder _inputBorder([Color? color]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: color ?? border),
      );
}

/// 渐变 Logo 圆角方块（原型 .logo-mini / .login-mini-logo）
class CfLogo extends StatelessWidget {
  const CfLogo({super.key, this.size = 52, this.radius = 14, this.fontSize = 26});
  final double size;
  final double radius;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: Cf.logoGradient,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Cf.accent.withValues(alpha: 0.3),
            blurRadius: size * 0.6,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text('C',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            color: Cf.ink,
            height: 1,
          )),
    );
  }
}
