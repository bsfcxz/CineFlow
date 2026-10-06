/// 面板内通用小组件（规格 §5 `shared/widgets`）。
///
/// ## 为什么集中在一个文件
/// 这五个组件（SettingRow / SliderRow / SegmentedGroup / DelayStepper /
/// InfoRow）是"面板内的行"，**结构同构、样式必须一致**。
/// 拆五个文件会让"统一改行高"要改五处 —— 本项目已有过教训：
/// 卡片组件化前各页手写 `Container`，尺寸/圆角/透明度互不相同。
///
/// 每个组件的**唯一职责**是把一种"设置行的形状"固定下来，
/// 调用方只提供值 + 回调，不再关心 padding/字号/分隔线。
library;

import 'package:flutter/material.dart';

import '../player_ui_tokens.dart';

/// 通用设置行：左标签（+ 可选副标题），右值或控件。
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.label,
    this.hint,
    this.value,
    this.trailing,
    this.onTap,
    this.showDivider = true,
  });

  final String label;

  /// 标签下方的小字说明（可选）。
  final String? hint;

  /// 右侧文案值（与 [trailing] 二选一）。
  final String? value;

  /// 右侧任意控件（开关、选择器等）。
  final Widget? trailing;

  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final row = Container(
      // 命中区 ≥52dp（规格 §7.6 的行高）；不可点的行也给足高度，
      // 否则相邻两行会挤在一起。
      constraints: const BoxConstraints(minHeight: PlayerUi.settingRowMinHeight),
      padding: PlayerUi.panelPadding,
      decoration: showDivider
          ? const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: PlayerUi.divider, width: 0.5),
              ),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: PlayerUi.labelColor,
                    fontSize: PlayerUi.labelSize,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (hint case final h? when h.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    h,
                    style: const TextStyle(
                      color: PlayerUi.hintColor,
                      fontSize: PlayerUi.hintSize,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (trailing != null)
            trailing!
          else if (value case final v?)
            Text(
              v,
              style: const TextStyle(
                color: PlayerUi.valueColor,
                fontSize: PlayerUi.valueSize,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );

    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// 带滑块的设置行（亮度/对比度/饱和度/色相/音量/透明度…）。
///
/// ## 为什么值要显示在右侧
/// 滑块本身看不出具体数值，而"亮度 0"和"亮度 15"是不同状态。
/// 显示数值还能让用户确认"我调到 0 了确实复位了"。
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.valueLabel,
    this.divisions,
    this.showDivider = true,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  /// 拖动结束（用于落盘 —— 拖一次会触发几十次 onChanged，不能每次都写存储）。
  final ValueChanged<double>? onChangeEnd;

  /// 右侧文案；不传则显示取整后的数值。
  final String? valueLabel;
  final int? divisions;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 8),
      decoration: showDivider
          ? const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: PlayerUi.divider, width: 0.5),
              ),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: PlayerUi.labelColor,
                    fontSize: PlayerUi.labelSize,
                  ),
                ),
                const Spacer(),
                Text(
                  valueLabel ?? value.round().toString(),
                  style: const TextStyle(
                    color: PlayerUi.valueColor,
                    fontSize: PlayerUi.valueSize,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: PlayerUi.progressFilled,
              inactiveTrackColor: PlayerUi.progressTrack,
              thumbColor: Colors.white,
              overlayColor: PlayerUi.progressFilled.withValues(alpha: 0.2),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: SizedBox(
              // 滑块命中区：视觉细但可点（沿用本项目 U5 的结论）
              height: 36,
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分段选择组（画面比例 / 解码方式 / 字号 / 编码 / 区域…）。
///
/// ## 为什么不用 Material 的 `SegmentedButton`
/// 它自带 M3 的容器色与描边，压在深色玻璃面板上会**发灰**，
/// 与原型（选中 = 蓝色半透明底 + 蓝字）不一致。
/// 自绘也更简单：一行等宽按钮 + 选中态换色。
class SegmentedGroup<T> extends StatelessWidget {
  const SegmentedGroup({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.label,
    this.labelBuilder,
    this.showDivider = true,
  });

  final List<T> options;
  final T value;
  final ValueChanged<T> onChanged;

  /// 可选的行标签（如"画面比例"）。
  final String? label;

  /// 每项显示文案；不传则用 `toString()`。
  final String Function(T)? labelBuilder;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: showDivider
          ? const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: PlayerUi.divider, width: 0.5),
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label case final l?) ...[
            Text(
              l,
              style: const TextStyle(
                color: PlayerUi.labelColor,
                fontSize: PlayerUi.labelSize,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              for (final o in options) ...[
                Expanded(
                  child: _Segment(
                    text: (labelBuilder ?? (T v) => '$v')(o),
                    active: o == value,
                    onTap: () => onChanged(o),
                  ),
                ),
                if (o != options.last) const SizedBox(width: 6),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.text,
    required this.active,
    required this.onTap,
  });

  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PlayerUi.tabRadius),
        child: Container(
          height: PlayerUi.tabHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? PlayerUi.tabActiveBg : Colors.transparent,
            borderRadius: BorderRadius.circular(PlayerUi.tabRadius),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? PlayerUi.tabActiveText : PlayerUi.tabInactiveText,
              fontSize: PlayerUi.segmentSize,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 延迟步进器（音频/字幕延迟，规格 §7.6：−5s…+5s，步进 0.1s）。
///
/// ## 为什么用 ± 按钮而不是滑块
/// 0.1s 精度的滑块在 10s 量程上**一个像素 ≈ 0.1s**，手指根本对不准；
/// 而"微调 0.1s"正是这个功能的真实用法（对口型）。
/// 到边界时按钮**禁用**（不是静默无效）—— 让用户知道已经到头了。
class DelayStepper extends StatelessWidget {
  const DelayStepper({
    super.key,
    required this.label,
    required this.delay,
    required this.onChanged,
    this.min = const Duration(seconds: -5),
    this.max = const Duration(seconds: 5),
    this.step = const Duration(milliseconds: 100),
    this.showDivider = true,
  });

  final String label;
  final Duration delay;
  final ValueChanged<Duration> onChanged;
  final Duration min;
  final Duration max;
  final Duration step;
  final bool showDivider;

  /// 显示为 `+0.3s` / `-1.2s` / `0.0s`。
  static String format(Duration d) {
    final s = d.inMilliseconds / 1000.0;
    if (s == 0) return '0.0s';
    final sign = s > 0 ? '+' : '-';
    return '$sign${s.abs().toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context) {
    final canDec = delay > min;
    final canInc = delay < max;
    return Container(
      constraints: const BoxConstraints(minHeight: PlayerUi.settingRowMinHeight),
      padding: PlayerUi.panelPadding,
      decoration: showDivider
          ? const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: PlayerUi.divider, width: 0.5),
              ),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: PlayerUi.labelColor,
                fontSize: PlayerUi.labelSize,
              ),
            ),
          ),
          _StepButton(
            icon: Icons.remove,
            enabled: canDec,
            onTap: () => onChanged(_clamp(delay - step)),
          ),
          SizedBox(
            width: 62,
            child: Text(
              format(delay),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: PlayerUi.valueColor,
                fontSize: PlayerUi.valueSize,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add,
            enabled: canInc,
            onTap: () => onChanged(_clamp(delay + step)),
          ),
        ],
      ),
    );
  }

  Duration _clamp(Duration d) {
    if (d < min) return min;
    if (d > max) return max;
    return d;
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 命中区 36dp：面板内密集排布，36 是"能点中"与"不显臃肿"的折中
      // （主控制层按钮仍是 48+，这里属面板内次要操作）
      width: 36,
      height: 36,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        onPressed: enabled ? onTap : null,
        icon: Icon(icon),
        color: Colors.white,
        disabledColor: Colors.white24,
        splashRadius: 18,
        tooltip: enabled ? null : '已到边界',
      ),
    );
  }
}

/// 信息行（信息 Tab）：`label: value`，虚线分隔。
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.showDivider = true,
  });

  final String label;

  /// 值；null 或空 → 显示「—」（**不编造**：内核给不了就说给不了）。
  final String? value;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final v = (value == null || value!.isEmpty) ? '—' : value!;
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: PlayerUi.panelPadding,
      decoration: showDivider
          ? const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: PlayerUi.divider, width: 0.5),
              ),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(
                color: PlayerUi.hintColor,
                fontSize: PlayerUi.valueSize,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                color: PlayerUi.labelColor,
                fontSize: PlayerUi.valueSize,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 信息分组标题。
class InfoSection extends StatelessWidget {
  const InfoSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Text(
            title,
            style: const TextStyle(
              color: PlayerUi.tabActiveText,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

/// 面板空态（如"没有音轨可选"）。
class PanelEmpty extends StatelessWidget {
  const PanelEmpty({super.key, required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        children: [
          if (icon case final i?)
            Icon(i, size: 32, color: PlayerUi.hintColor),
          if (icon != null) const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: PlayerUi.hintColor,
              fontSize: PlayerUi.valueSize,
            ),
          ),
        ],
      ),
    );
  }
}
