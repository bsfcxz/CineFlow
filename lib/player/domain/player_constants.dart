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
  /// ★ 2026-10-10 统一为 **280dp 基准**（用户要求）
  ///
  /// ## 为什么改成统一 280dp
  /// 用户指出"网上说 280dp 这个宽度不错"。核实后认同：
  /// · **280dp 是通行做法** —— Material 的 `NavigationDrawer` 规范宽度
  ///   就是 **280dp**（`NavigationDrawer` 默认 `width: 360`，
  ///   但 modal 抽屉的经典值是 280；Android/Web 的侧栏普遍 240–320）。
  /// · **280dp 在竖屏 393dp 上占 71%** —— 是"侧栏"而不是"全屏页"，
  ///   左侧留出 ~113dp 能看到画面（此前 0.9 比例 = 354dp，占 90%，
  ///   几乎盖满，看不出是抽屉）。
  /// · **280dp 在横屏 873dp 上占 32%** —— 正好落在主流播放器
  ///   （MX Player / VLC / nPlayer 约 28–35%）的区间内。
  ///
  /// ⇒ **一个基准值同时满足两种方向**，不再需要"竖屏/横屏两套比例"。
  ///    这比原实现更简单，也更可预期（用户不必问"为什么横竖不一样宽"）。
  ///
  /// ## 窄屏安全钳制（不能只有 280）
  /// 小屏（如 320dp 宽的旧机）上 280dp 占 **88%** —— 又变回"盖满"。
  /// ⇒ 保留比例上限：**最宽不超过屏宽 85%**。
  /// 320dp 屏 ⇒ 272dp；393dp 屏 ⇒ 280dp；横屏 873dp ⇒ 280dp。
  static const double panelBaseWidth = 280;

  /// 面板宽度占屏上限（窄屏兜底，见 [panelBaseWidth] 的说明）。
  static const double panelMaxScreenRatio = 0.85;

  /// 面板宽度的**唯一**计算入口（竖屏/横屏同款）。
  ///
  /// ⚠️ 这是"一个数学写多处"的高风险点 —— 所以只在这里定义，
  /// 由 `PlayerUi.settingsWidth` / `playlistWidth` 转调（两个类各司其职：
  /// `PlayerPanels`=常量与算法，`PlayerUi`=对外便捷函数）。
  static double panelWidth(double screenWidth) {
    if (screenWidth <= 0) return panelBaseWidth;
    return panelBaseWidth.clamp(0.0, screenWidth * panelMaxScreenRatio);
  }

  /// 拖动设置面板的宽度（保留旧名以免调用点大改）。
  static double settingsWidth(double screenWidth) => panelWidth(screenWidth);

  /// 播放列表面板宽度（与设置面板**同宽** —— 统一后更整齐）。
  ///
  /// 原来播放列表更窄（340 max / 0.8）：本意是"列表内容简单"，
  /// 但实测 173 集的长剧名在窄面板里被截断，反而更难读。
  static double playlistWidth(double screenWidth) => panelWidth(screenWidth);
}

/// 画面比例模式（规格 §7.6 视频 Tab）。
///
/// ## ★ 2026-10-10 精简为两档（用户明确要求）
/// > "删除底栏设置按钮侧边抽屉栏中的 16:9 4:3 9:16，拉伸和裁剪，
/// >  只留下自动和适应"
///
/// ### 为什么删得掉（不是妥协，而是**这些档位已没必要**）
/// · **固定比例档（16:9/4:3/9:16）** 的原始用途是"片源比例信息有误时纠错"
///   —— mpv 的 `--video-aspect-override` 也是这个定位。
///   但 `auto` 现在**已经忠于片源**（第 11 轮修复：2.388 宽银幕不再被
///   拉伸 34%）⇒ 自动在绝大多数场景就是对的，手动纠错需求极低。
/// · **拉伸（fill）** 会变形 —— 属于"故意看变形画面"，正常观看不会用。
/// · **裁剪（cover）** 会切掉画面边缘（字幕/构图可能被切）——
///   想看"满屏"的用户用「适应」即可，而裁掉内容的代价用户往往没预期。
///
/// ### 保留两档的语义
/// | 档 | 行为 |
/// |---|---|
/// | **自动** | 忠于片源比例（`resolveAuto` ⇒ contain）|
/// | **适应** | 显式 contain（与 auto **当前**行为一致；保留它是让用户能
///   "锁死"行为，不受未来 auto 策略变化影响）|
///
/// ⚠️ 删成员会让**旧持久化值失效**（如存过 `'ratio16x9'`）——
///    读取处已用 `orElse` 回退到 `auto`（见 `player_flow_page` 的恢复逻辑），
///    不会崩、也不会静默错档。
enum AspectMode {
  auto('自动'),
  contain('适应');

  const AspectMode(this.label);
  final String label;

  /// 目标宽高比；两档都是 `null`（由片源/引擎决定）。
  ///
  /// 保留该 getter 是因为渲染层 `AspectVideo` 与 `pictureSize`
  /// （弹幕区域计算）都按它分支。
  double? get ratio => null;

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
  /// ## 2026-10-10 随档位精简而简化
  /// 原 `fill`（铺满视口）与 `cover`（铺满视口）两个"画面=整个视口"的
  /// 分支已随档位一并删除（用户要求只留自动/适应）⇒ 本函数现在
  /// **只有一种行为：按片源比例内接**。
  ///
  /// ⚠️ 保留 `mode` 参数（而非删掉）是为了**调用方语义清晰**
  ///    （`pictureSize(mode: effMode, ...)` 读起来就是"这个档下的画面"），
  ///    且将来若再加"满屏/裁剪"档位时不必改调用点。
  ///
  /// [viewportW]/[viewportH] 是播放页可用区域（`LayoutBuilder` 的 max）。
  /// [videoRatio] 片源显示比例（未知时按 16:9，与 [AspectVideo] 的兜底一致）。
  static ({double width, double height}) pictureSize({
    required AspectMode mode,
    required double viewportW,
    required double viewportH,
    required double videoRatio,
  }) {
    // 按片源比例内接（自动/适应两档同款 —— 两者语义都是"不改变片源比例"）
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
