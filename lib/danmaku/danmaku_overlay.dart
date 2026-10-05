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

import '../core/theme.dart';
import 'danmaku_layout.dart';
import 'danmaku_models.dart';

/// 弹幕渲染层。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    this.enabled = true,
    this.opacity = 1.0,
    this.fontScale = 1.0,
    this.blockedWords = const [],
    this.showArea = 1.0,
  });

  /// 已按时间排序的弹幕（由 `DanmakuBatch.sorted()` 保证）
  final List<Danmaku> items;

  /// 当前播放位置
  final Duration position;

  /// 弹幕开关
  final bool enabled;

  final double opacity;

  /// 字号缩放（用户设置）
  final double fontScale;

  /// 屏蔽词
  final List<String> blockedWords;

  /// 显示区域比例（1.0 = 全屏；0.5 = 只占上半屏）
  final double showArea;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  /// 轨道规划缓存。
  ///
  /// ⚠️ 必须在 State 里缓存，**不能放在 paint 里**：
  /// paint 每帧都跑，若每帧重新分配轨道，同一条弹幕在不同帧可能落到
  /// 不同轨道——视觉上就是"弹幕上下横跳"。而且几千条的规划每帧做一次
  /// 会直接掉帧。
  DanmakuTrackPlan? _plan;

  /// 规划对应的输入指纹（用于判断是否需要重算）
  String _planKey = '';

  DanmakuLayoutConfig _config(BoxConstraints c) => DanmakuLayoutConfig(
        fontSize: 16 * widget.fontScale,
        laneHeight: 26 * widget.fontScale,
        screenWidth: c.maxWidth,
        screenHeight: c.maxHeight * widget.showArea.clamp(0.2, 1.0),
        opacity: widget.opacity,
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
          final shown = filterBlocked(widget.items, widget.blockedWords);

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
              position: widget.position,
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
    final key = '$text|${style.fontSize}|${color.toARGB32()}';
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
        fontWeight: FontWeight.w600,
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
    final key = '$text|${style.fontSize}|s${strokeColor.toARGB32()}';
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
              size: 19,
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
