/// 播放器 UI 的**视觉令牌** —— 玻璃质感、面板尺寸、遮罩色。
///
/// ## 为什么与 `Cf`（应用主题）分开
/// `Cf` 是**应用级**设计语言（深蓝夜色 × 极光青，跟随用户主题切换）。
/// 播放器浮层压在**视频画面**之上，背景不可控（可能是任何颜色/亮度），
/// 因此需要一套**独立的"在任意背景上都可读"**的令牌：
///   · 用半透明白 + 模糊（glass）而不是主题色块 —— 主题色压在亮画面上会糊
///   · 文字用纯白 + 阴影，不用 `Cf.text`（深蓝文字在暗画面上看不见）
///
/// 规格 §7.3/§7.5 给出的具体值就落在这里，**不散在各 widget**。
library;

import 'package:flutter/material.dart';

import '../domain/player_constants.dart';

/// 播放器浮层令牌（取自 HTML 原型的 CSS）。
abstract final class PlayerUi {
  // ---- 玻璃按钮（原型 `.glass-btn`）----
  static const Color glassFill = Colors.white12; // rgba(255,255,255,.12)
  static const Color glassBorder = Color(0x26FFFFFF); // 15%
  static const double glassBlur = 12;
  static const double centerButtonSize = 56;

  /// 中央播放/暂停按钮（规格 §7.3：72×72，比两侧大）。
  static const double playButtonSize = 72;

  // ---- 锁按钮（规格 §7.5）----
  static const double lockButtonSize = 40;
  static const Color lockFill = Color(0x24FFFFFF); // 14%
  static const Color lockBorder = Color(0x2EFFFFFF); // 18%
  static const Color lockActive = Color(0xFF007AFF);

  // ---- 顶/底栏 ----
  /// 顶栏渐变压暗高度（保证标题在任何画面上可读）。
  static const double topBarFade = 120;
  static const double bottomBarFade = 200;

  // ---- 底栏毛玻璃（用户明确要求："底部工具栏背景要求透明毛玻璃"）----
  //
  // ## 为什么与 `glassFill` 分开
  // `glassFill = white12` 适合**小圆形按钮**（面积小，白色叠加不刺眼）。
  // 底栏是**整条**（横跨全屏、高约 130dp），若也用 white12：
  //   · 亮画面上会发白、按钮与背景对比度下降（按钮本身也是白的）
  //   · 面积大时 12% 白叠加已经明显，不再是"透明玻璃"的观感
  // 故底栏用**更低的白色不透明度 + 更强的模糊 + 竖向微渐变**：
  //   · 模糊更强（22 vs 12）→ 背后画面被明显晕开，"毛玻璃"感才成立
  //   · 白色更淡（0x14 ≈ 8%）→ 保持"透明"而不发白
  //   · 底部稍深一点点（0x1F 在下方）→ 让文字与图标有落脚的层次
  //
  // ⚠️ 不再在底栏背后放 `BarScrim` 这类黑色渐变压暗 ——
  //    那会让"透明"名不副实（用户看到的是黑色遮罩而非玻璃）。
  //    可读性改由模糊 + 白色细描边 + 文字阴影保证。

  /// 底栏玻璃的填充色（顶部→底部微渐变，避免整条死平）。
  static const Color barGlassTop = Color(0x14FFFFFF); // ≈8%
  static const Color barGlassBottom = Color(0x1FFFFFFF); // ≈12%

  /// 底栏玻璃的模糊强度（比小按钮强，面积大需要更明显的晕开）。
  static const double barGlassBlur = 22;

  /// 底栏玻璃的描边（细白线，勾勒出玻璃的"边"）。
  static const Color barGlassBorder = Color(0x1FFFFFFF); // 12%

  /// 底栏玻璃的圆角（顶边圆角，与画面形成卡片感）。
  static const double barGlassRadius = 16;

  // ---- 进度条（原型 `.progress-*`）----
  static const double progressTrackHeight = 3;
  static const double progressTrackHeightDragging = 6;
  static const double progressThumbSize = 13;
  static const Color progressTrack = Color(0x33FFFFFF); // 20%
  static const Color progressBuffer = Color(0x4DFFFFFF); // 30%
  static const Color progressFilled = Color(0xFF007AFF);

  /// 命中区高度（视觉 3–6dp，命中要 ≥48 —— 与 U5 的结论一致）。
  static const double progressHitHeight = 48;

  // ---- 面板（原型 `.side-panel`）----
  static const Color panelBg = Color(0xF20D1328);
  static const Color panelMask = Colors.black54;

  /// Tab 选中态（规格 §7.6：`0x2E007AFF` 底 + `0xFF4DA3FF` 字）。
  static const Color tabActiveBg = Color(0x2E007AFF);
  static const Color tabActiveText = Color(0xFF4DA3FF);
  static const Color tabInactiveText = Colors.white54;
  static const double tabRadius = 8;
  static const double tabHeight = 34;

  // ---- 面板内行（原型 `.setting-row`）----
  static const double settingRowMinHeight = 52;
  static const Color divider = Color(0x1AFFFFFF); // 10%
  static const Color labelColor = Colors.white;
  static const Color valueColor = Colors.white70;
  static const Color hintColor = Colors.white38;

  /// 可点行的默认字号（面板内统一，避免各页不一致）。
  ///
  /// ⚠️ 字号**只用整档**。`test/design_tokens_test.dart` 会拦住"新增半档"
  /// （本项目 U1 的纪律：风格刻度是枚举）。
  static const double labelSize = 14;
  static const double valueSize = 13;

  /// 分段选择器（Tab / SegmentedGroup）里的文字。
  ///
  /// 用 12 而不是 12.5：与既有 11/12/13 档位对齐 ——
  /// 半档会让同一屏出现"看起来一样大但实际差半像素"的文字。
  static const double segmentSize = 12;
  static const double hintSize = 11;

  /// 进度条端帽圆角。
  ///
  /// 取 4（`Cf.radiusXs`）而不是 3：轨道高 3dp 时 Flutter 会把半径
  /// **收敛到 高度/2 = 1.5**，渲染等价；而 4 是既有令牌档位，
  /// 能通过 U1 的"圆角只用 4 档"断言。
  static const double progressRadius = 4;

  /// 面板内边距。
  static const EdgeInsets panelPadding = EdgeInsets.symmetric(horizontal: 16);

  /// 面板头部高度。
  static const double panelHeaderHeight = 52;

  // ---- 反馈层（原型 `.seek-feedback` / `.level-indicator`）----
  static const Color feedbackBg = Color(0xCC000000);
  static const Color feedbackText = Colors.white;
  static const double feedbackRadius = 12;

  /// 亮度/音量指示器尺寸（原型：圆形 + 进度环）。
  static const double levelIndicatorSize = 96;

  // ---- 抽屉动画 ----
  /// 面板宽度（规格 §7.6 / §7.8）。**用可用宽而非屏宽**，分屏下才正确。
  static double settingsWidth(double availableWidth) =>
      (availableWidth * PlayerPanels.settingsWidthRatio)
          .clamp(0.0, PlayerPanels.settingsMaxWidth);

  static double playlistWidth(double availableWidth) =>
      (availableWidth * PlayerPanels.playlistWidthRatio)
          .clamp(0.0, PlayerPanels.playlistMaxWidth);
}
