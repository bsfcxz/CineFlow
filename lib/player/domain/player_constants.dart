/// 播放器交互常量 —— **全部取自 HTML 原型的实际 JS 值**。
///
/// ## 为什么集中一个文件
/// 这些数字（10px 阈值、250ms 双击、500ms 长按、3s 自动隐藏…）
/// 原本散在各文件里，改一处忘一处会导致"单击和双击打架"这类难查的 bug
/// （本项目实测踩过：`kDoubleTapTimeout` 决定 onTap 延迟，若和手势层
/// 自己的 250ms 不一致，就会出现"点了没反应"或"双击先触发单击"）。
///
/// ## ⚠️ 规格文档与原型冲突处以**原型为准**
/// 文档 §9.2 写"左侧 40% → 亮度，右侧 60% → 音量，中间 20% → dead"，
/// 三者合计 **120%**，自相矛盾。原型 JS 实际是：
/// ```js
/// else if (relX < rect.width * 0.4) gesture.mode = 'brightness';
/// else if (relX > rect.width * 0.6) gesture.mode = 'volume';
/// else gesture.mode = 'dead';
/// ```
/// 即 **左 40% / 中 20% 死区 / 右 40%**，合计 100%。
/// 以能跑的原型为准（见 [brightnessZoneRight] / [volumeZoneLeft]）。
library;

/// 手势与交互的时间/距离阈值。
abstract final class PlayerGestures {
  // ---- 原型 `const` 逐条对应 ----

  /// 双击判定窗口（原型 `TAP_DELAY = 250`）。
  ///
  /// ⚠️ 必须与 Flutter 的 `kDoubleTapTimeout`（300ms）协调：
  /// 我们用 `GestureDetector` 的 onTap/onDoubleTap，Flutter 内部按
  /// `kDoubleTapTimeout` 延迟派发 onTap。故**本常量只用于自绘手势判定**，
  /// 不用于 GestureDetector 的配置（那不可配）。
  static const Duration tapDelay = Duration(milliseconds: 250);

  /// 长按进入 3.0x 快进的阈值（原型 `LONG_PRESS_DELAY = 500`）。
  static const Duration longPressDelay = Duration(milliseconds: 500);

  /// UI 自动隐藏延迟（原型 `UI_HIDE_DELAY = 3000`）。
  static const Duration uiHideDelay = Duration(seconds: 3);

  /// "移动过"的距离阈值（原型 `Math.abs(dx) > 10`）。
  ///
  /// 作用：超过它就**取消长按计时器** —— 否则"按住拖动"会同时
  /// 触发长按快进和拖动 seek，两者互相覆盖。
  static const double moveSlop = 10;

  /// 手势方向判定阈值（原型 `if (adx < 15 && ady < 15) return`）。
  ///
  /// 比 [moveSlop] 大：先"认定移动"（10px），再多挪一点才"判定方向"（15px）。
  /// 两段式是为了避免手指刚一动就被判成某个方向、之后又反悔。
  static const double directionSlop = 15;

  // ---- 分区（原型实际值，见文件头说明）----

  /// 亮度区右边界（屏宽比例）：`x < 0.4` 为亮度区。
  static const double brightnessZoneRight = 0.4;

  /// 音量区左边界（屏宽比例）：`x > 0.6` 为音量区。
  static const double volumeZoneLeft = 0.6;

  // ---- 映射系数（原型实测值）----

  /// 上下滑动满屏对应的亮度/音量变化量（原型 `* 120`）。
  ///
  /// 含义：从屏幕底滑到顶 ≈ 改变 120 个亮度单位
  /// （亮度范围 0–100，故略有余量 —— 一滑到底通常能到头）。
  static const double verticalSensitivity = 120;

  /// 横向滑动满屏对应的 seek 秒数（原型 `(dx / rect.width) * 180`）。
  static const double horizontalSeekSeconds = 180;

  /// 快退/快进的固定步长（原型按钮 `seekBy(±10)`）。
  static const Duration step = Duration(seconds: 10);
}

/// 倍速相关。
abstract final class PlayerSpeeds {
  /// 原型 `SPEED_CYCLE = [1.0, 1.5, 2.0, 2.5, 3.0]`。
  static const List<double> cycle = [1.0, 1.5, 2.0, 2.5, 3.0];

  /// 长按临时倍速（原型 `longPressSpeed: 3.0`）。
  static const double longPress = 3.0;

  /// 循环取下一个倍速。到达末尾回到 1.0。
  ///
  /// 抽成纯函数便于单测：倍速循环是本项目要守的交互之一
  /// （1.0 → 1.5 → 2.0 → 2.5 → 3.0 → 1.0）。
  static double next(double current) {
    final i = cycle.indexOf(current);
    // 找不到（比如用户自定义了 1.25x）→ 归到最接近且不小于它的档
    if (i < 0) {
      for (final s in cycle) {
        if (s > current) return s;
      }
      return cycle.first;
    }
    return cycle[(i + 1) % cycle.length];
  }

  /// 格式化为按钮文案（原型 `toFixed(1) + 'x'`）。
  static String label(double speed) => '${speed.toStringAsFixed(1)}x';
}

/// 弹幕面板常量（原型实测值）。
abstract final class PlayerDanmaku {
  /// 原型 `DANMAKU_FONT_SIZE = { small: 12, medium: 16, large: 22 }`。
  static const Map<String, double> fontSize = {
    'small': 12,
    'medium': 16,
    'large': 22,
  };

  /// 原型 `DANMAKU_SPEED_LABELS`（1–10 档的中文名）。
  static const List<String> speedLabels = [
    '极慢', '很慢', '慢', '较慢', '中', '较快', '快', '很快', '极快', '飞速',
  ];

  /// 原型 `duration = 13 - d.speedLevel` 秒（速度等级越高，飞过越快）。
  static double scrollSeconds(int speedLevel) => (13 - speedLevel).toDouble();

  /// 透明度/速度滑块的默认值（原型 `value=80` / `value=5`）。
  static const double defaultOpacity = 80;
  static const int defaultSpeedLevel = 5;

  /// 静止弹幕（顶部/底部）停留时长。
  static const Duration staticHold = Duration(seconds: 3);
}

/// 面板常量。
abstract final class PlayerPanels {
  /// 抽屉动画时长（规格 §10.6：350ms）。
  static const Duration drawerDuration = Duration(milliseconds: 350);

  /// Tab 切换动画时长（规格 §10.6：200ms）。
  static const Duration tabDuration = Duration(milliseconds: 200);

  /// 设置面板最大宽度（规格 §7.6：`min(screenWidth * 0.9, 400)`）。
  static const double settingsMaxWidth = 400;
  static const double settingsWidthRatio = 0.9;

  /// 播放列表面板（规格 §7.8：`min(screenWidth * 0.8, 340)`），左侧。
  static const double playlistMaxWidth = 340;
  static const double playlistWidthRatio = 0.8;

  /// 拖出的宽度。
  static double settingsWidth(double screenWidth) =>
      (screenWidth * settingsWidthRatio).clamp(0.0, settingsMaxWidth);

  static double playlistWidth(double screenWidth) =>
      (screenWidth * playlistWidthRatio).clamp(0.0, playlistMaxWidth);
}

/// 画面比例模式（规格 §7.6 视频 Tab）。
enum AspectMode {
  contain('适应'),
  fill('拉伸'),
  cover('裁剪'),
  ratio16x9('16:9'),
  ratio4x3('4:3');

  const AspectMode(this.label);
  final String label;

  /// 目标宽高比；`null` = 由引擎/视频原尺寸决定。
  double? get ratio => switch (this) {
        AspectMode.ratio16x9 => 16 / 9,
        AspectMode.ratio4x3 => 4 / 3,
        _ => null,
      };
}

/// 解码方式（规格 §7.6 视频 Tab）。
enum DecodeMode {
  hardware('硬解'),
  software('软解');

  const DecodeMode(this.label);
  final String label;
}
