/// 弹幕渲染的**布局计算**（纯逻辑，可单测）。
///
/// ## 为什么把布局从 widget 里拆出来
///
/// 弹幕的"对不对"几乎全在数学上：
///   - 滚动弹幕的 x 位置随时间怎么走
///   - 哪些弹幕此刻应该可见
///   - 同一时刻多条弹幕怎么分配"轨道"才不重叠
///
/// 这些放进 `CustomPainter` 后只能靠肉眼看屏幕验证——而弹幕是快速移动的，
/// 肉眼根本判断不了"第 3 秒时是否有一条弹幕本该出现却没出现"。
/// 拆成纯函数后可以按毫秒级断言。
///
/// ## 渲染策略：只算"此刻可见"的，不建 widget
///
/// 一集可能有几千条弹幕，但同时可见的通常不超过 30 条。
/// 用 `CustomPainter` 每帧只画可见的那几条，比"每条弹幕一个 widget"
/// 少几个数量级的开销（AGENTS.md 的性能约定：大列表要虚拟化）。
library;

import 'dart:ui';

import 'danmaku_models.dart';

/// 一条待渲染的弹幕 + 它的轨道。
class LaidOutDanmaku {
  const LaidOutDanmaku({
    required this.danmaku,
    required this.lane,
    required this.x,
    required this.y,
    required this.opacity,
    required this.measuredWidth,
  });

  final Danmaku danmaku;

  /// 轨道序号（0 起）。滚动/顶部/底部分别独立编号。
  final int lane;

  /// 屏幕水平位置（左边缘）。顶部/底部弹幕为居中后的左边缘。
  final double x;

  /// 屏幕垂直位置（顶部边缘）
  final double y;

  final double opacity;

  /// 文本实测宽度（由 painter 传入，用于判断右侧是否已完全进场）
  final double measuredWidth;

  double get right => x + measuredWidth;
}

/// 渲染参数。集中在一处，便于将来接入用户设置（字号缩放/透明度/速度）
///
/// 默认值对齐成熟实现（`canvas_danmaku`，MIT；见 docs/OSS-SOURCES.md）：
/// fontSize 16 / 滚动 10s / 静态 5s / opacity 1.0 / lineHeight 1.6 / area 1.0。
/// 用同一套默认值的好处是用户从别的播放器迁过来时手感一致。
class DanmakuLayoutConfig {
  const DanmakuLayoutConfig({
    this.fontSize = 16,
    this.laneHeight = 26,
    this.topPadding = 6,
    this.screenWidth = 0,
    this.screenHeight = 0,
    /// 滚动弹幕横穿屏幕的时长（秒）
    this.scrollDuration = 10.0,
    /// 顶部/底部弹幕停留时长（秒）
    this.fixedDuration = 5.0,
    /// 全局透明度
    this.opacity = 1.0,
    /// 屏蔽词（用户设置）——命中则整条丢弃
    this.blockedWords = const [],
    /// 底部保留一行给字幕（避免弹幕压在字幕上）
    ///
    /// 成熟实现（canvas_danmaku 的 `safeArea`）默认开启，本项目跟进：
    /// 遮挡字幕比"少一行弹幕"更影响观感。
    this.reserveSubtitleLane = true,
    /// 轨道不够时的策略
    this.overflow = DanmakuOverflow.drop,
  });

  final double fontSize;
  final double laneHeight;
  final double topPadding;
  final double screenWidth;
  final double screenHeight;
  final double scrollDuration;
  final double fixedDuration;
  final double opacity;
  final List<String> blockedWords;
  final bool reserveSubtitleLane;
  final DanmakuOverflow overflow;

  /// 可用轨道数。
  ///
  /// 按高度的 80% 计算（不铺满全屏，避免弹幕盖住画面主体与字幕），
  /// 并可选扣掉 1 行留给字幕。
  int get laneCount {
    var n = ((screenHeight * 0.8) / laneHeight).floor();
    if (reserveSubtitleLane) n -= 1;
    return n.clamp(1, 64);
  }

  DanmakuLayoutConfig copyWith({
    double? screenWidth,
    double? screenHeight,
    double? opacity,
    List<String>? blockedWords,
  }) =>
      DanmakuLayoutConfig(
        fontSize: fontSize,
        laneHeight: laneHeight,
        topPadding: topPadding,
        screenWidth: screenWidth ?? this.screenWidth,
        screenHeight: screenHeight ?? this.screenHeight,
        scrollDuration: scrollDuration,
        fixedDuration: fixedDuration,
        opacity: opacity ?? this.opacity,
        blockedWords: blockedWords ?? this.blockedWords,
        reserveSubtitleLane: reserveSubtitleLane,
        overflow: overflow,
      );
}

/// 轨道不足时的处理策略。
enum DanmakuOverflow {
  /// 丢弃多余弹幕（默认）。
  /// 弹幕池超密时（如热门番的"高能"片段），丢弃比乱叠更耐看。
  drop,

  /// 复用轨道接受重叠（对应成熟实现的 `massiveMode`）。
  /// 用户主动开启才用——重叠虽然乱，但"一条都不少"。
  overlap,
}

/// 预计算的轨道分配结果。
///
/// 在弹幕列表变化时算一次，之后每帧只做"取可见"的轻量计算。
/// 若每帧都重新分配轨道，弹幕会在跳变（同一时刻算出不同轨道）——
/// 表现为"弹幕突然上下横跳"。
class DanmakuTrackPlan {
  DanmakuTrackPlan._({
    required this.source,
    required this.scroll,
    required this.top,
    required this.bottom,
    required this.config,
    required this.dropped,
  });

  /// 轨道规划对应的弹幕列表（与三个轨道数组同序）
  final List<Danmaku> source;

  /// 滚动弹幕：原索引 → 轨道号（-1 表示未分配/被丢弃）
  final List<int> scroll;

  /// 顶部弹幕：原索引 → 轨道号（null 表示被丢弃）
  final List<int?> top;

  /// 底部弹幕：原索引 → 轨道号（null 表示被丢弃）
  final List<int?> bottom;

  /// 规划时使用的配置（可见性计算必须用**同一份**配置，
  /// 否则轨道数与屏幕尺寸不一致会导致弹幕错位）
  final DanmakuLayoutConfig config;

  /// 因轨道不足被丢弃的条数（诊断用）
  final int dropped;

  /// 已分配的条数
  int get placed => scroll.where((l) => l >= 0).length +
      top.where((l) => l != null).length +
      bottom.where((l) => l != null).length;

  /// 为一批弹幕分配轨道。
  ///
  /// [widthOf] 回调用于测量每条弹幕的文本宽度——必须由调用方提供，
  /// 因为精确测量需要 `TextPainter`（依赖 Flutter 渲染层）。
  /// 测试里可以传一个确定性的假测量函数，从而不需要真实渲染环境。
  static DanmakuTrackPlan build({
    required List<Danmaku> items,
    required DanmakuLayoutConfig config,
    required double Function(Danmaku) widthOf,
  }) {
    final lanes = config.laneCount;
    // 每条轨道的"占位者状态"：用于判追尾。
    //
    // 记录的是**上一条弹幕的进屏时刻与宽度**，而不是"何时腾出来"：
    // 只判"腾出来"过于保守（宽弹幕会让轨道空置十几秒），
    // 而弹幕池密集时会因此大量丢弃。
    final laneSince = List<double?>.filled(lanes, null); // 上一条的进屏时刻
    final laneWidth = List<double>.filled(lanes, 0); // 上一条的宽度
    // 顶部/底部仍用"占用到何时"，因为它们是静止停留
    final topFree = List<double>.filled(lanes, 0);
    final bottomFree = List<double>.filled(lanes, 0);

    final scroll = List<int>.filled(items.length, -1);
    final top = List<int?>.filled(items.length, null);
    final bottom = List<int?>.filled(items.length, null);
    var dropped = 0;

    for (var i = 0; i < items.length; i++) {
      final d = items[i];
      final t = d.timeMs / 1000.0;

      switch (d.mode) {
        case DanmakuMode.top:
          final lane = _firstFree(topFree, t);
          if (lane == null) {
            dropped++;
          } else {
            top[i] = lane;
            topFree[lane] = t + config.fixedDuration;
          }
        case DanmakuMode.bottom:
          final lane = _firstFree(bottomFree, t);
          if (lane == null) {
            dropped++;
          } else {
            bottom[i] = lane;
            bottomFree[lane] = t + config.fixedDuration;
          }
        case DanmakuMode.scroll:
          final w = widthOf(d);
          var lane = _firstScrollLane(
            laneSince: laneSince,
            laneWidth: laneWidth,
            now: t,
            width: w,
            config: config,
          );
          if (lane == null && config.overflow == DanmakuOverflow.overlap) {
            // 大规模模式：挑"最不可能立刻撞上"的那条轨道复用它。
            // 选择依据是当前进屏进度——刚进屏的离撞上还有最长时间。
            lane = _leastBusyLane(laneSince, t);
          }
          if (lane == null) {
            dropped++;
          } else {
            scroll[i] = lane;
            laneSince[lane] = t;
            laneWidth[lane] = w;
          }
      }
    }

    return DanmakuTrackPlan._(
      source: items,
      scroll: scroll,
      top: top,
      bottom: bottom,
      config: config,
      dropped: dropped,
    );
  }

  static int? _firstFree(List<double> freeAt, double now) {
    for (var i = 0; i < freeAt.length; i++) {
      if (now >= freeAt[i]) return i;
    }
    return null;
  }

  /// 找一条不会与前一条**追尾**的轨道。
  ///
  /// ## 为什么不能只判"前一条是否已完全离开"
  ///
  /// 滚动弹幕的速度是**按宽度定的**（`(屏宽+文本宽)/时长`）——
  /// 也就是说**宽弹幕比窄弹幕快**。于是会出现这种情况：
  /// 一条窄弹幕刚进屏，后面跟着一条很宽的弹幕；如果只判"窄的还没走完"，
  /// 就永远不会往这条轨道放东西（浪费）；但如果直接放，
  /// 宽弹幕会**慢慢追上并压过**窄弹幕（视觉上是两条叠在一起跑）。
  ///
  /// 正确判据（借鉴 `canvas_danmaku` 的成熟做法）：
  ///   1. 前一条必须**已完全进屏**（否则尾部还在屏幕外，会与新的一条重叠）
  ///   2. 新弹幕的左边缘到达屏幕左侧时，前一条的右边缘必须已经跑在前面——
  ///      即"追尾时刻 > 前一条离开时刻"
  ///
  /// 判据 2 的推导：两条同向移动，新的一条初始位置在屏幕右边界外，
  /// 速度为各自的 `(屏宽+w)/时长`。只要在**前一条完全离开屏幕**之前，
  /// 新的左边缘没有超过前一条的右边缘，就不算撞上。
  static int? _firstScrollLane({
    required List<double?> laneSince,
    required List<double> laneWidth,
    required double now,
    required double width,
    required DanmakuLayoutConfig config,
  }) {
    final screen = config.screenWidth;
    final dur = config.scrollDuration;
    if (screen <= 0 || dur <= 0) return 0;

    for (var i = 0; i < laneSince.length; i++) {
      final since = laneSince[i];
      if (since == null) return i; // 空轨道直接用

      final prevW = laneWidth[i];
      final prevSpeed = (screen + prevW) / dur;
      final newSpeed = (screen + width) / dur;

      // 前一条的右边缘位置（进屏时右边缘在 screen + prevW 处，向左移动）
      final prevRight = screen + prevW - prevSpeed * (now - since);
      // 1) 前一条必须已完全进屏：右边缘不能还在屏幕外
      if (prevRight > screen) continue;

      // 2) 追尾判据：新弹幕左边缘追上"前一条右边缘"所需时间，
      //    必须晚于前一条完全离开屏幕（右边缘到 0）的时刻。
      //
      //    新弹幕左边缘：x_new(t) = screen - newSpeed * (t - now)
      //    前一条右边缘：x_prev(t) = prevRight - prevSpeed * (t - now)
      //    追上时 x_new == x_prev：
      //      screen - newSpeed·dt = prevRight - prevSpeed·dt
      //      dt = (screen - prevRight) / (newSpeed - prevSpeed)
      //    前一条离开（x_prev == -prevW）所需：dtLeave = prevRight/prevSpeed
      //
      //    宽弹幕更快（newSpeed > prevSpeed）→ dt > 0，需比较；
      //    否则（新的更慢或同速）永远追不上 → 安全。
      final speedDiff = newSpeed - prevSpeed;
      if (speedDiff <= 1e-9) return i; // 追不上 → 该轨道可用

      final catchUp = (screen - prevRight) / speedDiff;
      final leave = prevRight / prevSpeed;
      if (catchUp >= leave) return i;
    }
    return null;
  }

  /// 大规模模式下挑一条"最久没被使用"的轨道。
  static int _leastBusyLane(List<double?> laneSince, double now) {
    var best = 0;
    var bestAge = -1.0;
    for (var i = 0; i < laneSince.length; i++) {
      final s = laneSince[i];
      final age = s == null ? double.infinity : now - s;
      if (age > bestAge) {
        bestAge = age;
        best = i;
      }
    }
    return best;
  }

  /// 取此刻可见的弹幕（含位置）。
  ///
  /// [widthOf] 只对"候选条目"调用，避免每帧测量全部几千条。
  List<LaidOutDanmaku> visibleAt(
    double nowSeconds, {
    required DanmakuLayoutConfig config,
    required double Function(Danmaku) widthOf,
  }) {
    // 提前量：滚动弹幕从右侧进场，需要在时间到之前就开始画
    final out = <LaidOutDanmaku>[];
    final items = source;
    if (items.isEmpty) return out;

    for (var i = 0; i < items.length; i++) {
      final d = items[i];
      final t = d.timeMs / 1000.0;
      final elapsed = nowSeconds - t;

      if (d.mode == DanmakuMode.scroll) {
        final lane = scroll[i];
        if (lane < 0) continue;
        final w = widthOf(d);
        final travel = config.screenWidth + w;
        final speed = travel / config.scrollDuration;
        // 从右边缘进入（x = screenWidth）到完全离开左侧（x = -w）
        final x = config.screenWidth - speed * elapsed;
        if (x > config.screenWidth || x + w < 0) continue;
        out.add(LaidOutDanmaku(
          danmaku: d,
          lane: lane,
          x: x,
          y: config.topPadding + lane * config.laneHeight,
          opacity: config.opacity,
          measuredWidth: w,
        ));
      } else {
        // 顶部/底部：停留 fixedDuration
        if (elapsed < 0 || elapsed > config.fixedDuration) continue;
        final lane = d.mode == DanmakuMode.top ? top[i] : bottom[i];
        if (lane == null) continue;
        final w = widthOf(d);
        // 末尾 0.5 秒淡出，避免"啪"地消失
        final fade = (config.fixedDuration - elapsed).clamp(0.0, 0.5) / 0.5;
        final y = d.mode == DanmakuMode.top
            ? config.topPadding + lane * config.laneHeight
            : config.screenHeight -
                config.topPadding -
                (lane + 1) * config.laneHeight;
        out.add(LaidOutDanmaku(
          danmaku: d,
          lane: lane,
          x: (config.screenWidth - w) / 2,
          y: y,
          opacity: config.opacity * fade,
          measuredWidth: w,
        ));
      }
    }
    return out;
  }
}

/// 屏蔽词过滤（用户设置）。
///
/// 放在此处而非渲染层：过滤应在**载入时**做一次，
/// 而不是每帧都对每条弹幕做字符串包含判断。
List<Danmaku> filterBlocked(List<Danmaku> items, List<String> blocked) {
  if (blocked.isEmpty) return items;
  final words = blocked
      .map((w) => w.trim())
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return items;
  return items
      .where((d) => !words.any((w) => d.text.contains(w)))
      .toList(growable: false);
}

/// 供 painter 使用：算出文本宽度的近似值。
///
/// 用近似而非 `TextPainter`：滚动位置对宽度不敏感（误差几像素看不出来），
/// 而精确测量几千条弹幕在载入时会明显卡顿。
/// 真正绘制时仍由 `TextPainter` 排版，这里只用于轨道规划与定位。
double approximateTextWidth(String text, double fontSize) {
  // 经验系数：中文约 1.0em，ASCII 约 0.55em。按字符类型分别累计。
  var w = 0.0;
  for (final r in text.runes) {
    // CJK 及全角标点
    final isWide = (r >= 0x1100 && r <= 0x115F) ||
        (r >= 0x2E80 && r <= 0xA4CF) ||
        (r >= 0xAC00 && r <= 0xD7A3) ||
        (r >= 0xF900 && r <= 0xFAFF) ||
        (r >= 0xFE30 && r <= 0xFE6F) ||
        (r >= 0xFF00 && r <= 0xFF60) ||
        (r >= 0xFFE0 && r <= 0xFFE6);
    w += isWide ? fontSize : fontSize * 0.55;
  }
  return w;
}

/// 弹幕颜色的可读性处理。
///
/// 深色弹幕（如纯黑）在暗色画面上看不见；官方客户端通常给弹幕加描边。
/// 这里只做"过暗则提亮"的兜底，实际描边由 painter 负责。
Color readableColor(int rgb, {double opacity = 1.0}) {
  final r = (rgb >> 16) & 0xFF;
  final g = (rgb >> 8) & 0xFF;
  final b = rgb & 0xFF;
  // 亮度感知权重（ITU-R BT.601）
  final lum = 0.299 * r + 0.587 * g + 0.114 * b;
  if (lum >= 40) {
    return Color.fromRGBO(r, g, b, opacity);
  }
  // 太暗：整体提亮到可见范围。
  //
  // ⚠️ 纯黑（lum==0）不能走"按比例放大"——0 × 任何系数还是 0。
  // 首版就是这样，纯黑弹幕依然隐形。故对极暗值直接给一个中性灰。
  if (lum < 1) {
    return Color.fromRGBO(120, 120, 120, opacity);
  }
  final boost = 40 / lum;
  int up(int v) => (v * boost).round().clamp(0, 255);
  return Color.fromRGBO(up(r), up(g), up(b), opacity);
}
