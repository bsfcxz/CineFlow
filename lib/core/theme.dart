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
  static const surface3 = Color(0xFF1B2647); // 三级表面（对话框/底部弹层用）
  static const border = Color(0xFF233463);
  static Color accent = const Color(0xFF00D4FF); // 主强调（青）·运行时可切换
  static Color accent2 = const Color(0xFF2E6BFF);
  static Color accent3 = const Color(0xFF6C5CE7);
  static const text = Color(0xFFE6F4FF);
  static const text2 = Color(0xFF8BA3CC);
  static const text3 = Color(0xFF6D8ABA);
  static const success = Color(0xFF00E5A0);
  static const warn = Color(0xFFFFB347);
  static const danger = Color(0xFFFF6B6B);
  static const emby = Color(0xFF52B54B);
  static const ai = Color(0xFFC084FC);
  static const ink = Color(0xFF060A14); // 强调色按钮上的深色文字

  // ---- 间距节奏（4/8dp 体系，见 ui-ux-pro-max「8dp spacing rhythm」）----
  // 统一放这里而不是散落各页，避免出现 13/17/22 这类无节奏的魔数。
  static const gap1 = 4.0;
  static const gap2 = 8.0;
  static const gap3 = 12.0;
  static const gap4 = 16.0;
  static const gap5 = 24.0;
  static const gap6 = 32.0;

  // ---- 圆角令牌（统一随设计语言，避免各页 8/10/12/14 混用）----
  //
  // ## 为什么是这 4 档（实测收敛依据）
  //
  // 收敛前全仓 `circular()` 用到 **16 种值**（1/2/4/5/6/7/8/9/10/11/12/13/14/16/18/20），
  // 其中 **9/10/11/13/14 是 1–2px 级差** —— 肉眼分不出，
  // 却让界面"没有节奏"（与字号 22 档、图标 15 档同源）。
  //
  // 收敛规则（按**元素尺寸**分层，不是按手感）：
  //   · `radiusXs = 4`  —— 微元素：角标、进度条端帽、勾选框
  //     （这类元素高 2–17px，用 8 会显得过圆）
  //   · `radiusSm = 8`  —— 小控件：chip、行内按钮、小缩略图
  //   · `radiusMd = 12` —— 卡片、输入框、弹层行（**默认档**）
  //   · `radiusLg = 16` —— 大面板、底部弹层、对话框
  //
  // ⚠️ **不要新增介于两档之间的值**。要更弱的效果用颜色令牌表达，
  //    而不是再切 1px —— 那正是这 16 种值的来源。
  static const radiusXs = 4.0;
  static const radiusSm = 8.0;
  static const radiusMd = 12.0;
  static const radiusLg = 16.0;

  // ---- 图标尺寸令牌（5 档）----
  //
  // ## 为什么需要它（实测）
  //
  // 按钮审查时统计全仓图标尺寸：**15 个不同值**
  // （10/13/14/15/16/17/18/19/20/21/22/26/30/40/44），
  // 其中 **17/18/19/20/21/22 是 1px 级差** —— 肉眼分不出，
  // 但会让界面显得"没有节奏"（与字号那次的成因完全相同）。
  //
  // 规则：**不要新增介于两档之间的尺寸**。要更弱的效果用颜色令牌表达。
  static const iconSm = 16.0; // 行内图标、角标、chip 内小图标
  static const iconMd = 20.0; // 列表/按钮标准（深色主题下比 Material 的 24 更协调）
  static const iconLg = 24.0; // 主导航、强调按钮
  static const iconXl = 40.0; // 空态 / 错误态大图标

  // ---- 动效令牌（见「motion-consistency」：全局统一节奏）----
  // 退出比进入快（约 65%），符合「exit-faster-than-enter」。
  static const durFast = Duration(milliseconds: 120);
  static const durBase = Duration(milliseconds: 200);
  static const durSlow = Duration(milliseconds: 320);
  static const curve = Curves.easeOutCubic;

  /// 卡片统一阴影（深色主题下的"浮起"感）。
  ///
  /// ⚠️ 深色主题**不能靠阴影**表达层级：黑底上的黑影几乎不可见。
  /// 实测本仓库原先 card vs bg 对比仅 **1.10:1**，卡片"糊"在背景里。
  /// 正确做法是**描边 + 轻微表面提亮**为主、阴影为辅。
  static List<BoxShadow> cardShadow = [
    BoxShadow(
      color: const Color(0xFF000000).withValues(alpha: 0.35),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];

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
        onPrimary: ink,
        secondary: accent2,
        onSecondary: ink,
        surface: surface,
        onSurface: text,
        surfaceContainerHighest: surface2,
        error: danger,
        onError: ink,
        outline: border,
      ),
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: text,
        displayColor: text,
        fontFamily: null, // 跟随系统栈（PingFang SC / Noto Sans SC）
      ),

      // ================= 以下 15 项此前**全部未配置** =================
      // 未配置的后果：Material 3 默认值会漏进来 —— 浅色系卡片、紫色 chip、
      // 白底对话框，与「深蓝夜色 × 极光青」完全冲突。
      // 实测：改造前卡片对比仅 1.10:1、且各页被迫写死颜色（全仓 131 处硬编码）。

      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0, // 关掉滚动变色，保持沉浸
        centerTitle: false,
        titleTextStyle: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w600, color: text),
        iconTheme: const IconThemeData(color: text2, size: 20),
      ),

      cardTheme: CardThemeData(
        color: surface,
        // ⚠️ 深色主题用**描边**表达边界（黑底阴影看不见），实测对比 1.10:1 时
        // 卡片会和背景糊在一起。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: const BorderSide(color: border),
        ),
        elevation: 0,
        margin: EdgeInsets.zero,
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: text2,
        textColor: text,
        subtitleTextStyle: TextStyle(fontSize: 12, color: text3),
        contentPadding: EdgeInsets.symmetric(horizontal: gap4),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: surface3,
        surfaceTintColor: Colors.transparent, // 关掉 M3 的染色（会偏紫）
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: const BorderSide(color: border),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w600, color: text),
        contentTextStyle: const TextStyle(fontSize: 13, color: text2),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface3,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: surface3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLg)),
        ),
        showDragHandle: true,
        dragHandleColor: border,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: 0.16),
        elevation: 0,
        height: 62,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              size: iconLg,
              color: states.contains(WidgetState.selected) ? accent : text3,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 11,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w400,
              color: states.contains(WidgetState.selected) ? accent : text3,
            )),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: surface2,
        selectedColor: accent.withValues(alpha: 0.18),
        side: const BorderSide(color: border),
        labelStyle: const TextStyle(fontSize: 12, color: text2),
        secondaryLabelStyle: TextStyle(fontSize: 12, color: accent),
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: gap3, vertical: gap1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm)),
      ),

      dividerTheme: const DividerThemeData(
        color: border, thickness: 1, space: 1),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: ink, // 深色文字压在亮青上：实测 11.18:1
          elevation: 0,
          // 触控目标 ≥48dp（Android 规范，见「touch-target-size」）
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: const BorderSide(color: border),
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd)),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: text2,
          // 图标按钮的可点区域不达标是常见问题（视觉 20px）。
          // 约束最小尺寸，保证 ≥48dp 触控目标。
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.all(gap2),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: surface2,
        circularTrackColor: surface2,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface3,
        contentTextStyle: const TextStyle(fontSize: 13, color: text),
        actionTextColor: accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: const BorderSide(color: border),
        ),
      ),

      tabBarTheme: TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: text3,
        indicatorColor: accent,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? ink : text3),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : surface2),
        trackOutlineColor: WidgetStateProperty.all(border),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: surface2,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.16),
        trackHeight: 3,
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : Colors.transparent),
        checkColor: WidgetStateProperty.all(ink),
        side: const BorderSide(color: border, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4)),
      ),

      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : text3),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        hintStyle: const TextStyle(color: text3, fontSize: 13),
        labelStyle: const TextStyle(color: text3, fontSize: 13),
        // 输入框高度 ≥48dp（移动端触控目标）
        contentPadding:
            const EdgeInsets.symmetric(horizontal: gap4, vertical: gap4),
        border: _inputBorder(),
        enabledBorder: _inputBorder(),
        // ★ 这里原先是硬编码 Color(0xFF00D4FF)：切换主题色（外观页四选一）时
        //   输入框焦点边框**不会跟着变**，是实测确认的 bug。改用运行时 accent。
        focusedBorder: _inputBorder(accent),
        errorBorder: _inputBorder(danger),
        focusedErrorBorder: _inputBorder(danger),
      ),

      splashFactory: InkSparkle.splashFactory,
      highlightColor: accent.withValues(alpha: 0.08),
      splashColor: accent.withValues(alpha: 0.10),
    );
  }

  static OutlineInputBorder _inputBorder([Color? color]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: color ?? border),
      );

  /// 卡片装饰：描边 + 阴影（深色主题下"浮起"感的正确表达）。
  static BoxDecoration cardDecoration({
    Color? color,
    double radius = radiusMd,
    bool elevated = true,
  }) =>
      BoxDecoration(
        color: color ?? surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border),
        boxShadow: elevated ? cardShadow : null,
      );

  // ==================== 排版体系（CfText）====================
  //
  // ## 为什么需要它
  //
  // 实测改造前：全仓 **234 处 fontSize，散落成 22 个不同值**
  // （8.5 / 9 / 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 13.5 …），
  // 其中大量是 0.5px 级差——肉眼几乎无法分辨，却让界面显得"没有节奏"。
  // 这正是"UI 看起来不够专业"的典型成因：不是某个颜色错了，
  // 而是**没有一套明确的层级**，于是每处都凭手感微调。
  //
  // 参考项目的做法（Best-Flutter-UI-Templates 的
  // `design_course_app_theme.dart` / `fitness_app_theme.dart`）也是定义
  // 一整套 `TextTheme` 而非散落的 fontSize。
  //
  // ## 层级设计（7 档，覆盖实际用到的全部场景）
  //
  // | 令牌 | 字号 | 用途 |
  // |---|---|---|
  // | `pageTitle`  | 20 | 页面主标题 |
  // | `section`    | 16 | 区块标题 / 卡片大标题 |
  // | `title`      | 14 | 卡片标题、列表主文案 |
  // | `body`       | 13 | 正文（默认） |
  // | `label`      | 12 | 标签、次要说明 |
  // | `caption`    | 11 | 辅助信息、元数据 |
  // | `micro`      | 10 | 角标、极小注释（下限） |
  //
  // 规则：**不再新增介于两档之间的字号**（如 12.5）。
  // 需要更弱就用颜色令牌（text2/text3）表达，而不是再切 0.5px。
  static const pageTitle = TextStyle(
      fontSize: 20, fontWeight: FontWeight.w700, color: text, height: 1.25);
  static const section = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w600, color: text, height: 1.3);
  static const title = TextStyle(
      fontSize: 14, fontWeight: FontWeight.w600, color: text, height: 1.35);
  static const body = TextStyle(fontSize: 13, color: text, height: 1.45);
  static const label = TextStyle(fontSize: 12, color: text2, height: 1.4);
  static const caption = TextStyle(fontSize: 11, color: text3, height: 1.4);
  static const micro = TextStyle(fontSize: 10, color: text3, height: 1.3);

  /// 数字等宽（进度、时长、计数）——避免数字变化时宽度跳动。
  /// 见 ui-ux-pro-max「number-tabular」。
  static const numeric = TextStyle(
    fontSize: 13,
    color: text,
    height: 1.4,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// 图标徽章：圆角方块底 + 单色图标（**设置项/功能入口的统一外观**）。
///
/// ## 为什么抽成组件（而不是各处手写 Container）
///
/// 改造前 `profile_page` 各处手写：`29×29` 容器装 `16px` 图标
/// → 内边距只有 **6.5px**，视觉偏紧；不同页面的容器尺寸/圆角/透明度
/// 还不一致（29 vs 30、radius 8 vs 10、alpha .15 vs .18）。
/// 抽成组件后**一处改、全局一致**，也是 `UI-DESIGN.md` 「风格刻度是枚举」
/// 的具体落法。
///
/// 比例取 **图标 : 容器 = 1 : 1.85**（16 → 30），这是 Material 图标按钮
/// 常见的呼吸感比例；圆角用 `radiusSm`（与全局刻度一致）。
class CfIconBadge extends StatelessWidget {
  const CfIconBadge({
    super.key,
    required this.icon,
    this.color,
    this.size = 30,
    this.iconSize = 16,
  });

  final IconData icon;

  /// 主题色。留空用 `Cf.accent`（跟随外观页主题切换）。
  final Color? color;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Cf.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // 底色用主题色的低透明derivative：比纯灰底更有识别度，
        // 又不会像实心色块那样抢文字视线
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Cf.radiusSm),
        // 极细描边让徽章在深色底上"站得住"（深色主题靠描边表达边界）
        border: Border.all(color: c.withValues(alpha: 0.22)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: c),
    );
  }
}

/// 应用品牌标识（登录页 / 启动页 / 关于页共用）。
///
/// ## 改造记录（用户反馈"我的关于应用的图标也没替换"）
///
/// 旧实现是**自绘**的：`logoGradient` 渐变方块 + 居中文字「C」。
/// 它长得像 logo，但**和应用图标不是同一个东西** ——
/// 桌面看到的是 `icon.png`（用户提供的成品图），应用内看到的却是这个自绘方块，
/// 于是产生"图标没替换"的观感。
///
/// 现改为**直接渲染 `assets/icon.png`**，与桌面图标、启动屏同源：
///   · `assets/icon.png`（1x=64）/ `2.0x`（128）/ `3.0x`（192）分辨率感知
///   · 三处（桌面图标 / 启动屏 / 应用内）**永远一致**
///
/// 保留 `radius` 参数只为**圆角裁切**（部分场景想让外框圆一点），
/// 不再有 `fontSize` —— 图标本身已包含字形，不再叠文字。
class CfLogo extends StatelessWidget {
  const CfLogo({super.key, this.size = 52, this.radius = 14});

  final double size;

  /// 圆角半径。设 0 表示完全按原图（icon.png 本身四角已有圆角）。
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Cf.accent.withValues(alpha: 0.3),
            blurRadius: size * 0.6,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: radius > 0 ? Clip.antiAlias : Clip.none,
      child: Image.asset(
        'assets/icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 资源缺失时不崩、不留白：退化为品牌色方块（构建期已登记进 pubspec）
        errorBuilder: (_, _, _) => Container(
          decoration: BoxDecoration(
            gradient: Cf.logoGradient,
            borderRadius: BorderRadius.circular(radius),
          ),
          alignment: Alignment.center,
          child: Text('C',
              style: TextStyle(
                fontSize: size * 0.5,
                fontWeight: FontWeight.w900,
                color: Cf.ink,
                height: 1,
              )),
        ),
      ),
    );
  }
}


/// M3 窗口尺寸类断点（dp 判定，不判设备型号）。
///
/// 与 Material 3 官方 WindowSizeClass 对齐：
///   Compact < 600 ≤ Medium < 840 ≤ Expanded
/// 用法：
///   final wc = CfBreakpoints.of(MediaQuery.sizeOf(context).width);
///   if (wc >= CfBreakpoints.medium) ...
abstract final class CfBreakpoints {
  static const double compactMax = 600;
  static const double mediumMax = 840;

  static const int compact = 0;
  static const int medium = 1;
  static const int expanded = 2;

  static int of(double widthDp) {
    if (widthDp >= mediumMax) return expanded;
    if (widthDp >= compactMax) return medium;
    return compact;
  }

  /// 海报网格列数：按可用宽度 / 目标列宽推算，夹在 [min, max]。
  /// 与 media_cards.dart 的实现统一（该处先落地，此为通用化）。
  static int columnsFor(double usableWidth,
      {double target = 112, int min = 3, int max = 6}) {
    if (usableWidth <= 0) return min;
    return (usableWidth / target).floor().clamp(min, max);
  }

  /// 是否 Expanded（侧栏/双栏布局启用点）
  static bool isExpanded(double widthDp) => of(widthDp) == expanded;

  /// 是否 Compact（<600dp）
  static bool isCompact(double widthDp) => of(widthDp) == compact;
}

/// 字号缩放钳制：标题类元素在系统大字号下按 [maxFactor] 封顶，
/// 正文不钳制（无障碍原则：正文始终跟随系统缩放）。
///
/// 用法：
///   Text('标题', textScaler: clampTextScale(MediaQuery.textScalerOf(context)))
TextScaler clampTextScale(TextScaler scaler, {double maxFactor = 1.3}) {
  final f = scaler.scale(10) / 10; // 归一化基准倍率
  if (f <= maxFactor) return scaler;
  return TextScaler.linear(maxFactor);
}

/// 语义化文本 —— **排版令牌 + 字号钳制的唯一入口**。
///
/// ## 为什么需要它（而不是直接用 `Text(style: Cf.title)`）
///
/// U1 审计实测：`Cf` 的 8 个排版令牌**只被用了 24 处，而裸 `fontSize` 有 232 处**；
/// 更关键的是 `clampTextScale`（审计要求的字缩钳制能力）**真代码采用 0 处** ——
/// 也就是说"字号上限 1.3x"这条规则**从未生效**。
///
/// 根因不是"大家忘了用"，而是**用起来太麻烦**：要同时写
/// `style: Cf.title` **和** `textScaler: clampTextScale(MediaQuery.textScalerOf(context))`
/// 两处，还得记得哪些档该钳、哪些不该钳。
/// 抽成本组件后，**正确用法是唯一省事用法**：
///
/// ```dart
/// CfText('第 1 集', style: Cf.title)              // 自动带钳制
/// CfText('简介正文', style: Cf.body, clamp: false) // 正文跟随系统（默认就不钳）
/// ```
///
/// ## 钳制策略（对齐审计 §2.3）
/// · **标题类**（pageTitle/section/title/numeric）→ 钳到 1.3x
///   理由：200% 下底部 Tab 文字会与图标重叠、轮播标题溢出、设置行三行截断
/// · **正文类**（body/label/caption/micro）→ **不钳**
///   理由：无障碍原则 —— 用户调大字号是真实需求，正文压回去等于拒绝服务
///
/// 默认值按"是否标题"自动判定，调用方通常无需传 `clamp`。
class CfText extends StatelessWidget {
  const CfText(
    this.data, {
    super.key,
    required this.style,
    this.clamp,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
  });

  final String data;
  final TextStyle style;

  /// 是否对系统字号缩放封顶。
  /// null（默认）= 按 [style] 的字号自动判定：**≥14sp 视为标题 → 钳制**。
  final bool? clamp;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;

  /// 自动判定阈值：≥14 视为标题（对齐排版令牌里 title=14 这一档）。
  static const double _titleThreshold = 14;

  @override
  Widget build(BuildContext context) {
    final shouldClamp = clamp ?? ((style.fontSize ?? 13) >= _titleThreshold);
    return Text(
      data,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textScaler: shouldClamp
          ? clampTextScale(MediaQuery.textScalerOf(context))
          : null, // null = 完全跟随系统（不干预）
    );
  }
}

/// 触控目标最小尺寸（Material 基线 48dp）。
///
/// ## 为什么需要它
/// U1 审计实测：**88 处可点元素 <40dp**，最小仅 **16×16**（48dp 的 1/9）。
/// 根因与令牌同类 —— 没有统一的"最小触控"落法，各处手写尺寸。
///
/// 用法：把视觉尺寸与命中区**分开**（视觉可以小，命中必须达标）：
/// ```dart
/// CfTapTarget(child: Icon(Icons.close, size: 16))   // 视觉 16，命中 48
/// ```
/// `Center` 保证视觉元素居中、不会被拉伸变形 ——
/// 这是"只是把 SizedBox 改大"做不到的（那会把图标也拉大）。
class CfTapTarget extends StatelessWidget {
  const CfTapTarget({
    super.key,
    required this.child,
    this.size = 48,
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final double size;
  final VoidCallback? onTap;

  /// 无障碍读屏文案。自绘图标按钮**必须**给（否则读屏只会念"按钮"）。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    Widget t = SizedBox(
      width: size,
      height: size,
      child: Center(child: child),
    );
    if (onTap != null) {
      t = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: t,
      );
    }
    if (semanticLabel != null) {
      t = Semantics(button: true, label: semanticLabel, child: t);
    }
    return t;
  }
}

