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

/// 弹幕**类型**（滚动/顶部/底部）。
///
/// ## ⚠️ 这不是"显示区域"（标签曾用错）
/// 面板里这一项的标签**原来写的是「显示区域」** —— 但它的取值是
/// 滚动/顶部/底部，那是**弹幕类型**的语义。
/// 「显示区域」在 B站 指的是**弹幕占屏幕的高度比例**（0–100%）。
///
/// ⇒ 2026-10-10 修正：
/// · 本枚举的标签改为「弹幕类型」（名副其实）
/// · 新增 `DanmakuPanelState.showArea`（0–100 滑条）= 真正的「显示区域」
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
    this.fontPercent = 100,
    this.showArea = 100,
    this.speedLevel = 5,
    this.area = DanmakuArea.scroll,
    this.activeCount = 0,
  });

  /// 弹幕开关。
  final bool enabled;

  /// 不透明度 0–100（B站 同款滑条；**0 = 完全隐藏**）。
  final double opacity;

  /// 字号百分比 **60–180**（B站 同款滑条）。
  ///
  /// ## 为什么从三档枚举改成连续滑条（用户明确要求）
  /// > "字体大小也是可以拖动的和透明度一样"
  ///
  /// 三档（小/中/大）对"大一点/小一点"这种细偏好太粗；
  /// B站 的弹幕字号就是滑条。
  /// 范围与 `DanmakuConfig.fontScale`（0.6–1.8）一致，保证两处不打架。
  final double fontPercent;

  /// 显示区域 0–100（B站 同款滑条）= 弹幕**占屏幕的高度比例**。
  ///
  /// · 100 = 铺满画面
  /// · 50  = 只占上半屏（下半屏留给画面/字幕）
  ///
  /// ## 与 `avoidSubtitle`（防挡字幕）的关系
  /// 两者**正交**：`showArea` 决定"弹幕最多铺多高"，
  /// `avoidSubtitle` 决定"是否额外给字幕留一行"。
  /// 最终轨道区高 = `screenHeight × showArea × (avoidSubtitle ? 0.88 : 1.0)`。
  final double showArea;

  /// 速度档 1–10（规格滑块 `min=1 max=10 value=5`）。
  final int speedLevel;

  /// 弹幕类型（滚动/顶部/底部）—— 标签已从"显示区域"改正。
  final DanmakuArea area;

  /// 当前屏上弹幕数（用于「>100 条降采样」的性能提示）。
  final int activeCount;

  DanmakuPanelState copyWith({
    bool? enabled,
    double? opacity,
    double? fontPercent,
    double? showArea,
    int? speedLevel,
    DanmakuArea? area,
    int? activeCount,
  }) =>
      DanmakuPanelState(
        enabled: enabled ?? this.enabled,
        opacity: opacity ?? this.opacity,
        fontPercent: fontPercent ?? this.fontPercent,
        showArea: showArea ?? this.showArea,
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
          other.fontPercent == fontPercent &&
          other.showArea == showArea &&
          other.speedLevel == speedLevel &&
          other.area == area &&
          other.activeCount == activeCount;

  @override
  int get hashCode => Object.hash(enabled, opacity, fontPercent, showArea,
      speedLevel, area, activeCount);

  // ---------------- 单位换算（规格单位 ⇄ 既有 DanmakuConfig 单位）----------------
  //
  // 全部为 static 纯函数，便于逐条断言边界。

  /// 规格 `0–100` → `DanmakuConfig.opacity`（**0.0–1.0**）。
  ///
  /// ## ★ 2026-10-10 改为允许 0（用户要求"参考 B 站"）
  /// 原来下限是 **0.2**，旧注释说"完全不透明度的弹幕没有意义"。
  /// 但用户报障："为 0 时为全黑" —— 那正是**描边没乘 opacity** 的 bug
  /// （已修，见 `_DanmakuPainter._strokePainterFor`）。
  ///
  /// B站 的语义：**不透明度 0% ⇒ 完全看不见**（等价于关闭弹幕显示）。
  /// 这是唯一合理的解释 —— "不透明度 0"就该是"不可见"。
  /// ⇒ 现在滑到 0 就是 0，整层不绘制。
  static double opacityToConfig(double percent) =>
      (percent / 100.0).clamp(0.0, 1.0);

  /// `DanmakuConfig.opacity`（0.0–1.0）→ 规格 `0–100`。
  static double opacityFromConfig(double opacity) =>
      (opacity.clamp(0.0, 1.0) * 100).roundToDouble();

  // ---------------- 连续量：字号 / 显示区域（B 站同款滑条）----------------
  //
  // ## 为什么从"三档枚举"改成"连续滑条"（用户明确要求）
  // > "弹幕的显示区域修改一下，改成b站一样的0-100可以拖动的。
  // >  字体大小也是可以拖动的和透明度一样。"
  //
  // B站的弹幕设置里这两项都是**滑条**（不是固定档），
  // 因为"大一点/小一点"是很细的个人偏好，三档太粗。

  /// 字号百分比（60–180）→ `DanmakuConfig.fontScale`。
  ///
  /// 范围取 **0.6–1.8**：与 `DanmakuConfig.fontScale` 的取值范围一致
  /// （全局设置页的滑条也是这个区间），保证两处不打架。
  static double fontScaleFromPercent(double percent) =>
      (percent / 100.0).clamp(0.6, 1.8);

  /// `DanmakuConfig.fontScale` → 字号百分比（60–180）。
  static double fontPercentFromScale(double scale) =>
      (scale.clamp(0.6, 1.8) * 100).roundToDouble();

  /// 显示区域百分比（20–100）→ `DanmakuConfig.showArea`。
  ///
  /// ## 语义（B站叫"弹幕区域"）
  /// 弹幕**占屏幕的高度比例**：
  /// · 100% = 铺满画面（可能有弹幕压到字幕）
  /// · 50% = 只占上半屏（下半屏留给画面/字幕）
  ///
  /// 下限取 **20%**：再小就只剩一两行轨道，弹幕几乎叠在一起，
  /// 没有实用价值（而 0 等于关闭弹幕 —— 那该用弹幕开关）。
  static double showAreaFromPercent(double percent) =>
      (percent / 100.0).clamp(0.2, 1.0);

  /// `DanmakuConfig.showArea` → 显示区域百分比（20–100）。
  static double showAreaPercentFromValue(double area) =>
      (area.clamp(0.2, 1.0) * 100).roundToDouble();

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
