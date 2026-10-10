/// 弹幕渲染层（`CustomPainter`）。
///
/// ## 为什么自绘而不是每条弹幕一个 widget
///
/// 一集可能有**几千条**弹幕（实测某集 7628 条），但同时可见的通常不到 30 条。
/// 用 widget 会构造几千个元素、每帧重建；自绘只画可见的那几条。
///
/// ## 与播放器的关系
///
/// 本层**不持有播放状态**：位置由外部每帧传入（`position`）。
/// 这样它既能在播放器里用（跟着 `_pos` 走），也能在测试里用假时钟驱动。
///
/// ## 关键交互约定
///
/// - **不能拦截手势**：`IgnorePointer` 包裹。弹幕层盖在视频上，
///   若吃掉点击，播放器的"单击显隐控制层/双击快进"就全废了。
/// - **必须在控制层之下**：渲染顺序上，弹幕在视频之上、控制层之下
///   （否则弹幕会飘在按钮上，很难看）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../core/theme.dart';
import 'danmaku_config.dart';
import 'danmaku_layout.dart';
import 'danmaku_models.dart';

/// 弹幕渲染层。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    this.playing = true,
    this.enabled = true,
    this.opacity = 1.0,
    this.fontScale = 1.0,
    this.blockedWords = const [],
    this.showArea = 1.0,
    this.modes = DanmakuDisplayModes.all,
    this.speed = 1.0,
    this.bold = false,
    this.avoidSubtitle = true,
    this.filterLevel = 0,
  });

  /// 已按时间排序的弹幕（由 `DanmakuBatch.sorted()` 保证）
  final List<Danmaku> items;

  /// 当前播放位置（来自内核，**被限流到 250ms** —— 见渲染层的平滑时钟）
  final Duration position;

  /// 是否正在播放。
  ///
  /// ## 为什么弹幕层需要知道它
  /// 渲染层为了让弹幕平滑，会在两次 `position` 推送之间**本地外推**。
  /// 暂停时若继续外推，画面停住而弹幕还在飞 —— 明显错误。
  final bool playing;

  /// 弹幕开关
  final bool enabled;

  final double opacity;

  /// 字号缩放（用户设置）
  final double fontScale;

  /// 屏蔽词
  final List<String> blockedWords;

  /// 显示区域比例（1.0 = 全屏；0.5 = 只占上半屏）
  final double showArea;

  /// 显示模式分类开关（滚动 / 顶部 / 底部）—— 对照 B 站的弹幕类型开关。
  final DanmakuDisplayModes modes;

  /// 弹幕速度倍率（1.0 = 默认；越大飞得越快、同屏越少）
  final double speed;

  /// 是否加粗（B 站的"弹幕加粗"）
  final bool bold;

  /// 是否避开字幕区（B 站的"防挡字幕"）
  final bool avoidSubtitle;

  /// 过滤等级 0–4（见 `filterByLevel`）。
  ///
  /// ⚠️ 顺序：**先按等级过滤、再按屏蔽词**。
  /// 反过来也能得到同样结果，但先按等级能**减少**后一步的比对条数
  ///（等级过滤通常砍掉更多）。
  final int filterLevel;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  /// 轨道规划缓存。
  ///
  /// ⚠️ 必须在 State 里缓存，**不能放在 paint 里**：
  /// paint 每帧都跑，若每帧重新分配轨道，同一条弹幕在不同帧可能落到
  /// 不同轨道——视觉上就是"弹幕上下横跳"。而且几千条的规划每帧做一次
  /// 会直接掉帧。
  DanmakuTrackPlan? _plan;

  /// 规划对应的输入指纹（用于判断是否需要重算）
  String _planKey = '';

  // ══════════════════════════════════════════════════════════════
  // ★★ 平滑时钟（修复"弹幕卡顿不自然"，2026-10-10）
  // ══════════════════════════════════════════════════════════════
  //
  // ## 问题（真机观察 + 代码取证）
  // 弹幕位置完全由 `widget.position` 决定，而它来自内核的
  // `stateStream` —— 那条流被**故意限流到 250ms**
  //（`player_flow_page` 的 `_posFlushTimer`，目的是"消除每帧重建整页"）。
  //
  // ⇒ 弹幕**每秒只移动 4 步**：视觉上是明显的跳变/卡顿。
  //   而视频本身是 60fps 解码，两者叠加就显得"不自然"。
  //
  // ## 修法：本地插值（不碰内核，不影响其它订阅者）
  // 用 `position` 作为**权威基准**，两次推送之间用本地 elapsed 平滑外推：
  // ```
  // 平滑位置 = 基准位置 + (本地已过时间) × 播放倍速
  // ```
  // · 每次 `position` 更新 ⇒ 重置基准（**不会累积漂移**，
  //   因为基准来自内核而不是本地推算）
  // · 用 `Ticker`（vsync）驱动重绘 ⇒ 跟随屏幕刷新率（60/90/120Hz）
  // · 暂停时停止外推（否则画面停住后弹幕还在飞）
  //
  // ## 为什么不直接"把内核限流取消"
  // 那个限流是**为了让整页不每帧重建**（进度条/通知栏/唤醒锁等
  // 十几个订阅者都挂在同一条流上）。取消它会连累整页性能。
  // ⇒ 只让**弹幕**这一处平滑，是代价最小、收益最直接的做法。
  Ticker? _ticker;

  /// 基准位置（来自内核，权威）
  Duration _basePos = Duration.zero;

  /// 收到 `_basePos` 时的本地时刻
  Duration _baseAt = Duration.zero;

  /// 本帧渲染用的插值位置
  Duration _smoothPos = Duration.zero;

  /// 最近一次 `Ticker` 回调的时刻（算"基准落地时间"用）
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _basePos = widget.position;
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    // 记录本帧时刻 —— `didUpdateWidget` 用它算"基准位置的落地时刻"
    _lastTick = elapsed;
    // 暂停/未播放时不做外推：让弹幕停在当前位置（与视频一致）
    if (!widget.playing) {
      if (_smoothPos != _basePos) {
        setState(() => _smoothPos = _basePos);
      }
      return;
    }
    // 外推：基准 + 本地流逝 × 倍速
    final delta = elapsed - _baseAt;
    // 上限保护：若长时间没有新的 position（如内核卡住），
    // 不能让弹幕无限往前飞 —— 最多外推 400ms。
    final capped = delta > const Duration(milliseconds: 400)
        ? const Duration(milliseconds: 400)
        : delta;
    final next = _basePos + capped * widget.speed;
    // 只在变化超过 1ms 时 setState（避免 120Hz 下的无效重建）
    if ((next - _smoothPos).abs() > const Duration(milliseconds: 1)) {
      setState(() => _smoothPos = next);
    }
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    // 内核给了新位置 ⇒ 重置基准（关键：**不累积漂移**）
    if (old.position != widget.position) {
      _basePos = widget.position;
      // 用**上一次 tick 的时刻**作基准落地时间。
      // ⚠️ 不用 `Ticker.lastElapsedDuration`：该 getter 在本版本不存在
      //    （analyze 报 undefined），自己记更可靠且无版本依赖。
      _baseAt = _lastTick;
      // ⚠️ 若新位置**倒退**（seek 回跳），直接跳到新位置，
      //    不要平滑 —— 否则会看到弹幕"倒着飞"。
      if (widget.position < _smoothPos) {
        _smoothPos = widget.position;
      }
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  DanmakuLayoutConfig _config(BoxConstraints c) => DanmakuLayoutConfig(
        fontSize: 16 * widget.fontScale,
        laneHeight: 26 * widget.fontScale,
        screenWidth: c.maxWidth,
        // 防挡字幕：给底部字幕留出一行（B 站"防挡字幕"的作用）
        // 关闭时弹幕可铺满整屏
        screenHeight: c.maxHeight *
            widget.showArea.clamp(0.2, 1.0) *
            (widget.avoidSubtitle ? 0.88 : 1.0),
        opacity: widget.opacity,
        // 速度倍率直接作用于"弹幕飞过屏幕的时长"
        speed: widget.speed,
        bold: widget.bold,
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) {
          final config = _config(c);
          // ★ 先按等级过滤（砍掉刷屏），再按屏蔽词（用户显式指定的）
          final shown = filterBlocked(
            filterByLevel(widget.items, widget.filterLevel),
            widget.blockedWords,
          );

          // 指纹：仅当"弹幕集合或屏幕尺寸变化"时才重算轨道
          final key = '${identityHashCode(widget.items)}|'
              '${config.screenWidth.round()}|'
              '${config.screenHeight.round()}|'
              '${config.fontSize}|'
              '${widget.blockedWords.join(",")}';
          if (_plan == null || _planKey != key) {
            _planKey = key;
            _plan = DanmakuTrackPlan.build(
              items: shown,
              config: config,
              widthOf: (d) => approximateTextWidth(d.text, config.fontSize),
            );
          }

          return CustomPaint(
            size: Size(c.maxWidth, c.maxHeight),
            painter: _DanmakuPainter(
              plan: _plan!,
              config: config,
              // ★ 用**插值后**的位置（不是 widget.position）
              position: _smoothPos,
            ),
          );
        },
      ),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.plan,
    required this.config,
    required this.position,
  });

  final DanmakuTrackPlan plan;
  final DanmakuLayoutConfig config;
  final Duration position;

  /// 文本测量缓存：弹幕里短句会反复出现，同一帧内也要测多条。
  static final _textPainters = <String, TextPainter>{};

  static TextPainter _painterFor(
      String text, TextStyle style, Color color) {
    // ⚠️ key 必须含 **fontWeight**：否则"弹幕加粗"开关切换后，
    // 已缓存的同文本弹幕仍会用旧的细体渲染器 → 开关看似无效。
    // （实测隐患：一条弹幕只要出现过一次，加粗就对它不生效。）
    final key = '$text|${style.fontSize}|${style.fontWeight?.value}|'
        '${color.toARGB32()}';
    final hit = _textPainters[key];
    if (hit != null) return hit;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    // 容量控制：长期播放不至于无限增长
    if (_textPainters.length > 3000) _textPainters.clear();
    _textPainters[key] = tp;
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final nowSeconds = position.inMilliseconds / 1000.0;
    final visible = plan.visibleAt(
      nowSeconds,
      config: config,
      widthOf: (d) => approximateTextWidth(d.text, config.fontSize),
    );
    if (visible.isEmpty) return;

    for (final v in visible) {
      final style = TextStyle(
        fontSize:
            config.fontSize * (v.danmaku.fontSize / 25.0).clamp(0.6, 1.6),
        // 用户开了「弹幕加粗」用 w800，否则 w600（B 站同款选项）
        fontWeight: config.bold ? FontWeight.w800 : FontWeight.w600,
        height: 1.2,
      );
      final color = readableColor(v.danmaku.color, opacity: v.opacity);
      final offset = Offset(v.x, v.y);

      // 描边层：深色画面上白字也需要轮廓才清晰。
      // 用同一 TextPainter 的 foreground stroke 画一遍，比 shadow 更快更锐利。
      final stroke = _strokePainterFor(v.danmaku.text, style, color);
      stroke.paint(canvas, offset);

      final fill = _painterFor(v.danmaku.text, style, color);
      fill.paint(canvas, offset);
    }
  }

  static final _strokePainters = <String, TextPainter>{};

  static TextPainter _strokePainterFor(
      String text, TextStyle style, Color fillColor) {
    final lum = 0.299 * fillColor.r + 0.587 * fillColor.g + 0.114 * fillColor.b;
    final strokeColor =
        lum > 0.55 ? const Color(0xCC000000) : const Color(0xCCFFFFFF);
    // 同 _painterFor：key 必须含 fontWeight，否则加粗开关对已缓存项无效
    final key = '$text|${style.fontSize}|${style.fontWeight?.value}|'
        's${strokeColor.toARGB32()}';
    final hit = _strokePainters[key];
    if (hit != null) return hit;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..color = strokeColor,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    if (_strokePainters.length > 3000) _strokePainters.clear();
    _strokePainters[key] = tp;
    return tp;
  }

  @override
  bool shouldRepaint(_DanmakuPainter old) =>
      old.position != position ||
      !identical(old.plan, plan) ||
      old.config.opacity != config.opacity ||
      old.config.fontSize != config.fontSize ||
      old.config.screenWidth != config.screenWidth;
}

/// 弹幕开关按钮（供播放器控制层使用）。
///
/// 单独成 widget 是为了让播放器里那行调用尽量短——
/// `player_page.dart` 已经 1600+ 行，不宜再长。
class DanmakuToggleButton extends StatelessWidget {
  const DanmakuToggleButton({
    super.key,
    required this.enabled,
    required this.onTap,
    this.pending = false,
    this.progressText,
  });

  final bool enabled;
  final VoidCallback onTap;

  /// 正在生成弹幕（异步模式）——显示转圈而不是普通图标
  final bool pending;

  /// 生成进度描述（服务端给的 description，直接展示）
  final String? progressText;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (pending)
            SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                  strokeWidth: 1.8, color: Cf.accent),
            )
          else
            Icon(
              enabled
                  ? Icons.subtitles_rounded
                  : Icons.subtitles_off_rounded,
              size: 20,
              color: enabled ? Cf.accent : Cf.text3,
            ),
          if (pending && progressText != null) ...[
            SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                progressText!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: Cf.text3),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
