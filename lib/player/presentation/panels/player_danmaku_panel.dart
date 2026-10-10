/// 弹幕面板（规格 §7.7）—— 右侧抽屉，与设置面板互斥。
///
/// 内容：开关 / 透明度 / 字号 / 速度 / 显示区域 / 来源。
///
/// ## 单位说明（容易搞错）
/// 面板用**规格单位**（透明度 0–100、速度档 1–10），
/// 换算成既有 `DanmakuConfig` 单位（opacity 0.2–1.0、speed 0.5–2.0）
/// 由 `DanmakuPanelState` 的纯函数负责并有往返测试。
/// **本文件不做任何单位换算** —— 只展示与转发。
library;

import 'package:flutter/material.dart';

import '../../domain/models/danmaku_panel_state.dart';
import '../../../keys.dart';
import '../player_ui_tokens.dart';
import '../widgets/panel_widgets.dart';
import 'player_panel_host.dart';

class PlayerDanmakuPanel extends StatelessWidget {
  const PlayerDanmakuPanel({
    super.key,
    required this.state,
    required this.onToggle,
    required this.onOpacity,
    required this.onFontPercent,
    required this.onShowArea,
    required this.onSpeedLevel,
    required this.onArea,
    required this.onImportLocal,
    required this.onMatchOnline,
    required this.onClose,
  });

  final DanmakuPanelState state;
  final ValueChanged<bool> onToggle;

  /// 不透明度 0–100（**0 = 完全隐藏**，B站 同款语义）。
  final ValueChanged<double> onOpacity;

  /// 字号百分比 60–180（B站 同款滑条）。
  final ValueChanged<double> onFontPercent;

  /// 显示区域 0–100（B站 同款滑条）= 弹幕占屏幕高度比例。
  final ValueChanged<double> onShowArea;

  final ValueChanged<int> onSpeedLevel;
  final ValueChanged<DanmakuArea> onArea;
  final VoidCallback onImportLocal;
  final VoidCallback onMatchOnline;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: keys.player.danmakuPanel,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(title: '弹幕设置', onClose: onClose),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              children: [
                // ---- 开关 ----
                SettingRow(
                  label: '弹幕开关',
                  hint: state.enabled ? '当前显示弹幕' : '已关闭（不影响播放）',
                  trailing: Switch(
                    key: keys.player.danmakuSwitch,
                    value: state.enabled,
                    onChanged: onToggle,
                    activeThumbColor: PlayerUi.progressFilled,
                  ),
                ),

                // ---- 关闭时其余项禁用（避免"改了半天发现没开"）----
                _Disabled(
                  disabled: !state.enabled,
                  child: Column(
                    children: [
                      // ---- 以下五项全部是**滑条**（B站 同款）----
                      //
                      // ## 为什么字号/显示区域从"档位选择"改成滑条
                      // 用户明确要求：
                      // > "弹幕的显示区域修改一下，改成 b站一样的 0-100
                      // >  可以拖动的。字体大小也是可以拖动的和透明度一样"
                      //
                      // B站 的弹幕设置里这些都是滑条 —— 因为
                      // "大一点/小一点"是很细的个人偏好，固定档位太粗。
                      SliderRow(
                        label: '不透明度',
                        value: state.opacity,
                        min: 0,
                        max: 100,
                        valueLabel: '${state.opacity.round()}%',
                        onChanged: onOpacity,
                      ),
                      SliderRow(
                        label: '字体大小',
                        value: state.fontPercent,
                        min: 60,
                        max: 180,
                        valueLabel: '${state.fontPercent.round()}%',
                        onChanged: onFontPercent,
                      ),
                      SliderRow(
                        label: '显示区域',
                        value: state.showArea,
                        min: 20,
                        max: 100,
                        // B站 的"弹幕区域"就是占屏高的比例
                        valueLabel: '${state.showArea.round()}%'
                            '${state.showArea <= 20 ? '（最小）' : ''}',
                        onChanged: onShowArea,
                      ),
                      SliderRow(
                        label: '弹幕速度',
                        value: state.speedLevel.toDouble(),
                        min: 1,
                        max: 10,
                        divisions: 9,
                        // 显示档位 + 中文名（原型 DANMAKU_SPEED_LABELS），
                        // 只显示数字用户不知道"5"是快还是慢
                        valueLabel: '${state.speedLevel} · '
                            '${DanmakuPanelState.speedLabel(state.speedLevel)}',
                        onChanged: (v) => onSpeedLevel(v.round()),
                      ),
                      // ⚠️ 标签是「弹幕类型」（不是"显示区域"）——
                      //    取值是滚动/顶部/底部，那是**类型**的语义；
                      //    "显示区域"已被上面那个 0–100 滑条占用。
                      SegmentedGroup<DanmakuArea>(
                        label: '弹幕类型',
                        options: DanmakuArea.values,
                        value: state.area,
                        onChanged: onArea,
                        labelBuilder: (a) => a.label,
                      ),
                    ],
                  ),
                ),

                // ---- 来源 ----
                SettingRow(
                  label: '导入本地弹幕文件',
                  hint: '支持 .xml / .ass / .json',
                  value: '选择文件',
                  onTap: onImportLocal,
                ),
                SettingRow(
                  label: '在线匹配弹幕库',
                  hint: '根据文件名自动匹配',
                  value: '匹配',
                  onTap: onMatchOnline,
                  showDivider: false,
                ),

                // ---- 性能提示（>100 条时降采样，规格 §11.5）----
                if (state.enabled && state.activeCount > 100)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        const Icon(Icons.speed,
                            size: 14, color: PlayerUi.hintColor),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '当前屏 ${state.activeCount} 条，已启用降采样以保证流畅',
                            style: const TextStyle(
                              color: PlayerUi.hintColor,
                              fontSize: PlayerUi.hintSize,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 把子树整体降透明度 + 屏蔽交互（关闭弹幕时用）。
class _Disabled extends StatelessWidget {
  const _Disabled({required this.disabled, required this.child});

  final bool disabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: disabled,
      child: AnimatedOpacity(
        opacity: disabled ? 0.35 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: child,
      ),
    );
  }
}
