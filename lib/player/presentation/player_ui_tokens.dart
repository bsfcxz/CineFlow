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

  // ---- 底栏（用户要求：**完全透明**）----
  //
  // ## 迭代过程（两次用户反馈）
  // 1. 最初：背后垫 `BarScrim`（200dp 黑色渐变）→ 用户说"要透明毛玻璃"
  // 2. 改为毛玻璃：白色 8%→12% + blur 22 + 上边描边
  //    → 用户再说"**改成透明的**" ⇒ 那点白色叠加依然可见（亮画面上发白）
  // 3. 现在：**填充全透明**，只保留模糊
  //
  // ## 为什么"全透明"仍需要 BackdropFilter.blur
  // 模糊不是"上色"，它**不改变透出的颜色**，只是把背后的画面细节晕开。
  // 效果是"看得见视频、但文字不会被高频细节淹没" —— 这才是真正的
  // "透明毛玻璃"：**透明**（不叠色）与**可读**（晕开背景）同时成立。
  //
  // ⚠️ 若把 blur 也去掉（真·全无），白字压在亮画面上会完全看不清。
  //    用户要的是"透明"，不是"读不到"。

  /// 底栏填充：**完全透明**（不叠任何颜色）。
  ///
  /// 保留这组常量（而不是直接删掉背景）是为了让"想调回一点点的白"
  /// 只需改这一处 —— 历史上这个值反复调过两次。
  static const Color barGlassTop = Color(0x00000000);
  static const Color barGlassBottom = Color(0x00000000);

  /// 底栏模糊强度。
  ///
  /// 比小按钮（12）强：整条横跨全屏、面积大，弱模糊在 1080p 上几乎看不出，
  /// 文字可读性不够；22 是"看得出晕开"与"中低端机不掉帧"的折中。
  static const double barGlassBlur = 22;

  /// 底栏描边：**不要**（用户要透明，一条白线会暴露"这里有个容器"）。
  static const Color barGlassBorder = Color(0x00000000);

  /// 底栏圆角：填充透明后圆角已无视觉意义（留 0 避免 clip 产生锯齿边）。
  static const double barGlassRadius = 0;

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

  // ---- 长按快进提示（用户要求：透明 + 小 + 不遮挡画面）----
  //
  // 与 seek/亮度/音量**分开**（那两个仍用 `feedbackBg` 黑色半透明）：
  // 长按是**持续状态**（松手才消失），遮挡时间最长，
  // 而且它显示时用户正在看视频内容 —— 最不该挡视线的就是它。
  //
  // 用"淡白"而不是"更淡的黑"：视频可能是亮画面或暗画面，
  // 纯黑在暗画面上等于没提示；淡白 + 深色文字阴影在两种极端下都读得到。
  static const Color longPressBg = Color(0x33FFFFFF); // 20% 白
  static const Color longPressText = Colors.white;

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
