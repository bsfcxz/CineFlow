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

  /// 双击判定窗口（原型 `TAP_DELAY = 250` → **200**，
  /// 用户 2026-10-09 反馈"横屏单击隐藏控制栏响应不够灵敏"）。
  ///
  /// ## 为什么 250 → 200
  /// "不够灵敏"的完整链路：单击 → 等 tapDelay 确认"是单击"
  /// → 若原本隐藏则此刻才 show()。250ms 的确认窗体感就是"迟钝"。
  /// 压到 200ms 仍是可靠的双击窗（普通双击间隔 80–180ms），
  /// 确认延迟缩短 20%。
  ///
  /// ## ⚠️ 只影响"唤出控制层"那条路径
  /// "点击隐藏"本来就是**立即**执行（见 `_handleTap` 的
  /// `_tapStartedVisible` 分支）—— 迟钝的只是"从隐藏唤出"。
  ///
  /// ⚠️ 必须与 Flutter 的 `kDoubleTapTimeout`（300ms）协调：
  /// 我们用 `GestureDetector` 的 onTap/onDoubleTap，Flutter 内部按
  /// `kDoubleTapTimeout` 延迟派发 onTap。故**本常量只用于自绘手势判定**，
  /// 不用于 GestureDetector 的配置（那不可配）。
  static const Duration tapDelay = Duration(milliseconds: 200);

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
  ///
  /// ★ 2026-10-09 横屏宽度拆分（用户反馈"横屏时侧边栏占了半个屏幕"）：
  /// 原来只有一组 `ratio 0.9 / max 400` —— 按竖屏设计（393dp 屏 ⇒ 400dp
  /// 即全宽）。但横屏 873dp 宽时 400dp 仍生效 ⇒ **占屏 46%**，把画面
  /// 挤掉近一半。
  ///
  /// ## 横屏取值的依据（对齐主流播放器）
  /// MX Player / VLC / nPlayer 的横屏侧栏约 **屏宽 28–35%**
  /// （或换算成 240–320dp）：够放 Tab + 行内容，又留出大半画面。
  /// 竖屏维持原规格不动（§7.6 是按竖屏写的）。
  ///
  /// ## 为什么按"宽度 ≥ 高度"判横屏而不是 MediaQuery.orientation
  /// 本页全屏时 `orientation` 在部分设备上返回不准（immersive）；
  /// 宽高比较是事实。
  static const double settingsMaxWidth = 400;
  static const double settingsWidthRatio = 0.9;
  static const double settingsMaxWidthLandscape = 320;
  static const double settingsWidthRatioLandscape = 0.36;

  /// 播放列表面板（规格 §7.8：`min(screenWidth * 0.8, 340)`），左侧。
  static const double playlistMaxWidth = 340;
  static const double playlistWidthRatio = 0.8;
  static const double playlistMaxWidthLandscape = 300;
  static const double playlistWidthRatioLandscape = 0.34;

  /// 拖出的宽度（竖屏口径，规格 §7.6 / §7.8）。
  /// 横屏的取值函数在 `PlayerUi.settingsWidthFor`（**按方向分发**），
  /// 这里只放常量 —— 两个类各司其职（PlayerPanels=常量，PlayerUi=函数）。
  static double settingsWidth(double screenWidth) =>
      (screenWidth * settingsWidthRatio).clamp(0.0, settingsMaxWidth);

  static double playlistWidth(double screenWidth) =>
      (screenWidth * playlistWidthRatio).clamp(0.0, playlistMaxWidth);
}

/// 画面比例模式（规格 §7.6 视频 Tab）。
///
/// ★ 2026-10-09 新增 `auto`（用户要求"播放时自动适配画面：
/// 横屏自适应 16:9，竖屏播放时 9:16"）—— 作为**默认档**：
/// · 横屏窗口 → 强制 16:9（影视剧主场景，满屏不变形）
/// · 竖屏窗口 → 强制 9:16（竖屏短视频/竖拍素材满屏）
/// 用户手动选其它档后即脱离 auto（`VideoController.setAspectMode`）。
enum AspectMode {
  auto('自动'),
  contain('适应'),
  fill('拉伸'),
  cover('裁剪'),
  ratio16x9('16:9'),
  ratio4x3('4:3'),
  ratio9x16('9:16');

  const AspectMode(this.label);
  final String label;

  /// 目标宽高比；`null` = 由引擎/视频原尺寸决定。
  double? get ratio => switch (this) {
        AspectMode.ratio16x9 => 16 / 9,
        AspectMode.ratio4x3 => 4 / 3,
        AspectMode.ratio9x16 => 9 / 16,
        _ => null,
      };

  /// ★ auto 档的解析：**忠于片源比例**（2026-10-10 修正，原为"方向一致就强制"）
  ///
  /// ## ⚠️ 原来的设计是错的（真机实测抓到的变形）
  /// 原实现在"屏幕与片源同向"时**强制固定比例**：
  /// ```dart
  /// if (screenLandscape == videoLandscape) {
  ///   return screenLandscape ? AspectMode.ratio16x9 : AspectMode.ratio9x16;
  /// }
  /// ```
  /// 而 `ratio16x9` 的渲染是 `AspectRatio(16/9, child: texture)` ——
  /// **`Texture` 没有固有尺寸，会被拉伸填满那个框**。
  ///
  /// **真机取证**（用户库里的《伟大的长征》3840×1608 = 2.388:1）：
  /// ```
  /// 横屏视口 2400x1080
  ///   按真实比例应显示  2400 x 1005
  ///   auto 强制 16:9    2400 x 1350
  ///   ⇒ 纵向拉伸 34.3%（人脸明显变胖）
  /// ```
  /// 4:3 老片在横屏下同理会被横向压扁 ~19%。
  /// 只有"恰好 16:9 / 恰好 9:16"才是对的 —— 而**电影绝大多数不是 16:9**。
  ///
  /// ## 主流播放器的一致做法（已核实出处，非印象）
  /// | 播放器 | 默认行为 | 出处 |
  /// |---|---|---|
  /// | **mpv**（我们的一号内核）| `keepaspect` 默认 `yes` ⇒ 保留比例 + 黑边 | `DOCS/man/options.rst` |
  /// | **ExoPlayer/Media3**（二号内核）| `RESIZE_MODE_FIT` = 保持比例补黑边 | 本地 1.4.1 字节码实测枚举 |
  /// | **VLC** | 比例菜单首项是"默认"（= 片源真实比例）| `src/libvlc-module.c` |
  ///
  /// ⇒ **"保留片源比例"才是正确默认**；强制比例是"片源比例信息有误"时的
  ///    **纠错开关** —— mpv 的 `--video-aspect-override` 正是这个定位
  ///    （手册原文："in case aspect information is incorrect or missing"）。
  ///
  /// ## 语义变更（本轮）
  /// · 改前：auto = "方向一致就满屏"（宽银幕电影会纵向拉伸）
  /// · 改后：auto = **始终保留片源比例**（绝不变形，黑边补足）
  ///
  /// 用户要"满屏"时用显式档位（16:9 / 4:3 / 9:16 / 裁剪 / 拉伸）——
  /// 那些档位**语义不变**（本来就是"忽略片源比例"）。
  ///
  /// [videoRatio] 来自内核**显示尺寸**（dwidth/dheight，已含旋转/SAR）。
  /// 未知（null/0）时同样回 [AspectMode.contain]（渲染层按 16:9 兜底）。
  static AspectMode resolveAuto({
    required double width,
    required double height,
    required double? videoRatio,
  }) {
    // ★ 无论屏幕方向如何，都保留片源比例 ⇒ 永不变形。
    //
    // 比原来的"方向一致就强制"更简单也更正确：
    // 画面该多宽多高**只取决于片源**，与屏幕方向无关；
    // 屏幕方向只决定"黑边留在上下还是左右"（`contain` 自动处理）。
    return AspectMode.contain;
  }

  /// 视频画面在视口内的**实际矩形宽度/高度**（用于把弹幕限制在画面内）。
  ///
  /// ## 为什么需要这个（真机实测抓到的缺陷）
  /// 弹幕层原本用 `Positioned.fill` 铺满**整个屏幕**，
  /// 而竖屏看 16:9 内容时视频只是**中间一条**（上下黑边）。
  /// 结果弹幕飘到黑边、甚至压住顶部标题与返回按钮 ——
  /// 真机截图确认：弹幕出现在标题「斗罗大陆Ⅱ绝世唐门」之上。
  ///
  /// ## 语义：必须与 `AspectVideo` 的布局**逐档一致**
  /// 这是"同一条数学写两处"的典型风险，故抽成纯函数并单测：
  /// 若 [AspectVideo] 改了布局而这里没改，弹幕就会偏出画面。
  ///
  /// | 档位 | 画面尺寸 |
  /// |---|---|
  /// | contain / ratio* | 按 [effectiveRatio] 内接（留黑边）|
  /// | fill | 铺满视口（拉伸，无黑边）|
  /// | cover | 铺满视口（裁掉超出部分，可见区域仍是视口）|
  ///
  /// ⚠️ `cover` 与 `fill` 的**可见区域都是整个视口** —— 虽然
  /// `cover` 内部有超出部分被裁掉，但用户看到的仍是满屏，
  /// 故弹幕铺满是对的（与 mpv/B站 一致）。
  ///
  /// [viewportW]/[viewportH] 是播放页可用区域（`LayoutBuilder` 的 max）。
  /// [videoRatio] 片源显示比例（未知时按 16:9，与 [AspectVideo] 的兜底一致）。
  static ({double width, double height}) pictureSize({
    required AspectMode mode,
    required double viewportW,
    required double viewportH,
    required double videoRatio,
  }) {
    // fill / cover：画面铺满视口
    if (mode == AspectMode.fill || mode == AspectMode.cover) {
      return (width: viewportW, height: viewportH);
    }
    // 其余档：按目标比例内接（contain 语义）
    //
    // ⚠️ `auto` 不该走到这里 —— 调用方须先 `resolveAuto` 解析。
    //    真走到了就按 [videoRatio] 内接（与 AspectVideo 的 auto 兜底同款）。
    final ratio = mode.ratio ?? videoRatio;
    if (ratio <= 0 || viewportW <= 0 || viewportH <= 0) {
      return (width: viewportW, height: viewportH);
    }
    // 内接：取"更受限"的那一维
    final byWidth = viewportW / ratio <= viewportH;
    return byWidth
        ? (width: viewportW, height: viewportW / ratio)
        : (width: viewportH * ratio, height: viewportH);
  }
}

/// 解码方式（规格 §7.6 视频 Tab）。
enum DecodeMode {
  hardware('硬解'),
  software('软解');

  const DecodeMode(this.label);
  final String label;
}
