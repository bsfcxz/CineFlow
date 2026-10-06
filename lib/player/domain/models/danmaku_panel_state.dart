/// 弹幕面板状态（规格 §7.7）。
///
/// ## ⚠️ 为什么是"桥接"而不是"重写"
///
/// 本仓库已有完整弹幕栈（`lib/danmaku/`，10 个文件）：
/// 协议签名、双认证形态、异步轮询、轨道分配、渲染、持久化。
/// 规格 §11 描述的是**另一套**模型（`DanmakuArea` 单值 +
/// `speedLevel` 1–10 + `fontSize` 三档枚举）。
///
/// 两者**单位不同**：
///
/// | 项 | 规格 §11 | 现有 `DanmakuConfig` |
/// |---|---|---|
/// | 透明度 | `0–100` | `opacity` 0.2–1.0 |
/// | 字号 | 枚举 small/medium/large | `fontScale` 0.6–1.8 |
/// | 速度 | `speedLevel` 1–10 | `speed` 0.5–2.0 |
/// | 区域 | 单值 `DanmakuArea` | `modes` 三个 bool |
///
/// **重写成规格那套会丢掉整个协议层**（sign/async/match 都是实测踩出来的），
/// 那是本仓库最贵的资产之一。故这里做**双向换算**：
/// 面板按规格的"人话单位"（0–100%、1–10 档）呈现，
/// 落到 `DanmakuConfig` 时换算成它既有的单位。
///
/// 换算函数全部是纯函数并单独测试 —— 单位换算是**最容易悄悄错**的地方
/// （0–100 与 0–1 混用不会报错，只会显示成"透明度 80 倍"）。
library;

/// 弹幕字号档（规格 §11：小/中/大）。
enum DanmakuFontSize {
  small('小'),
  medium('中'),
  large('大');

  const DanmakuFontSize(this.label);
  final String label;
}

/// 弹幕显示区域（规格 §7.7：滚动/顶部/底部）。
///
/// ⚠️ 规格是**单值选择**，而现有 `DanmakuDisplayModes` 是**三个独立开关**。
/// 面板按规格做单值（用户更易懂），换算时把其余两项关掉。
/// 注意这会**覆盖**用户在旧设置页做的精细组合 —— 属于预期行为：
/// 两套 UI 表达同一份配置，后改的生效。
enum DanmakuArea {
  scroll('滚动'),
  top('顶部'),
  bottom('底部');

  const DanmakuArea(this.label);
  final String label;
}

/// 弹幕面板状态。
class DanmakuPanelState {
  const DanmakuPanelState({
    this.enabled = true,
    this.opacity = 80,
    this.fontSize = DanmakuFontSize.medium,
    this.speedLevel = 5,
    this.area = DanmakuArea.scroll,
    this.activeCount = 0,
  });

  /// 弹幕开关。
  final bool enabled;

  /// 透明度 0–100（规格滑块 `min=0 max=100 value=80`）。
  final double opacity;

  final DanmakuFontSize fontSize;

  /// 速度档 1–10（规格滑块 `min=1 max=10 value=5`）。
  final int speedLevel;

  final DanmakuArea area;

  /// 当前屏上弹幕数（用于「>100 条降采样」的性能提示）。
  final int activeCount;

  DanmakuPanelState copyWith({
    bool? enabled,
    double? opacity,
    DanmakuFontSize? fontSize,
    int? speedLevel,
    DanmakuArea? area,
    int? activeCount,
  }) =>
      DanmakuPanelState(
        enabled: enabled ?? this.enabled,
        opacity: opacity ?? this.opacity,
        fontSize: fontSize ?? this.fontSize,
        speedLevel: speedLevel ?? this.speedLevel,
        area: area ?? this.area,
        activeCount: activeCount ?? this.activeCount,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DanmakuPanelState &&
          other.enabled == enabled &&
          other.opacity == opacity &&
          other.fontSize == fontSize &&
          other.speedLevel == speedLevel &&
          other.area == area &&
          other.activeCount == activeCount;

  @override
  int get hashCode => Object.hash(
      enabled, opacity, fontSize, speedLevel, area, activeCount);

  // ---------------- 单位换算（规格单位 ⇄ 既有 DanmakuConfig 单位）----------------
  //
  // 全部为 static 纯函数，便于逐条断言边界。

  /// 规格 `0–100` → `DanmakuConfig.opacity`（0.2–1.0）。
  ///
  /// 下限取 0.2 而不是 0：完全不透明度的弹幕没有意义，
  /// 而 0 会被设置页的 Slider（min 0.2）判为越界。
  static double opacityToConfig(double percent) =>
      (percent / 100.0).clamp(0.2, 1.0);

  /// `DanmakuConfig.opacity`（0.2–1.0）→ 规格 `0–100`。
  static double opacityFromConfig(double opacity) =>
      (opacity.clamp(0.2, 1.0) * 100).roundToDouble();

  /// 规格字号档 → `DanmakuConfig.fontScale`（0.6–1.8）。
  ///
  /// 取 0.85 / 1.0 / 1.25：与原型 `DANMAKU_FONT_SIZE = {12, 16, 22}`
  /// 的比例（0.75 / 1.0 / 1.375）接近，但收窄到既有 Slider 的可用范围，
  /// 避免"大"档直接顶到 1.8 显得突兀。
  static double fontSizeToConfig(DanmakuFontSize size) => switch (size) {
        DanmakuFontSize.small => 0.85,
        DanmakuFontSize.medium => 1.0,
        DanmakuFontSize.large => 1.25,
      };

  /// `fontScale` → 最接近的字号档（用于反向同步）。
  static DanmakuFontSize fontSizeFromConfig(double fontScale) {
    if (fontScale < 0.925) return DanmakuFontSize.small;
    if (fontScale > 1.125) return DanmakuFontSize.large;
    return DanmakuFontSize.medium;
  }

  /// 规格速度档 1–10 → `DanmakuConfig.speed`（0.5–2.0）。
  ///
  /// 档位越高 = 弹幕飞得越快 = 穿越耗时越短。
  /// 原型 `duration = 13 - speedLevel` 秒（档 1 → 12s，档 10 → 3s）。
  /// 既有 `speed` 是"倍率"语义（越大越快），故**单调递增**映射。
  ///
  /// 10 档均分 [0.5, 2.0] → 步长 `(2.0-0.5)/(10-1) = 1.5/9`。
  static double speedToConfig(int level) {
    final l = level.clamp(1, 10);
    return (0.5 + (l - 1) * (_speedSpan / 9)).clamp(0.5, 2.0);
  }

  /// `speed` → 速度档（反向）。
  ///
  /// ⚠️ **本函数曾写错，被往返测试抓出**：第一版末尾多写了一个 `+1`，
  /// 于是 `speedFromConfig(speedToConfig(2))` 返回 1 —— 10 档里 9 档全错位。
  /// 症状会非常隐蔽：面板显示"第 1 档"而实际速度是第 2 档的值，
  /// 或者用户选了"飞速"再打开面板发现显示"极快"（差一档）。
  ///
  /// 正确推导：`level = round((speed - 0.5) / step) + 1`
  /// （`+1` 只在这里出现一次，因为 `speedToConfig` 已经减过 1 了）。
  static int speedFromConfig(double speed) {
    final s = speed.clamp(0.5, 2.0);
    final idx = ((s - 0.5) / (_speedSpan / 9)).round();
    return (idx + 1).clamp(1, 10);
  }

  /// 速度映射的跨度（0.5 → 2.0）。
  static const double _speedSpan = 1.5;

  /// 速度档 → 中文标签（原型 `DANMAKU_SPEED_LABELS`）。
  static String speedLabel(int level) {
    const labels = ['极慢', '很慢', '慢', '较慢', '中', '较快', '快', '很快', '极快', '飞速'];
    return labels[(level.clamp(1, 10)) - 1];
  }

  /// 速度档 → 滚动耗时（原型 `13 - speedLevel` 秒）。
  ///
  /// ⚠️ 这是**渲染**用的，不是配置单位。1–10 档 → 12s…3s。
  static Duration scrollDuration(int level) =>
      Duration(milliseconds: ((13 - level.clamp(1, 10)) * 1000));
}
