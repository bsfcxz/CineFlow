/// 反馈层（规格 §7.1 的 `FeedbackLayer`）—— 手势过程中显示的各项指示器。
///
/// ## 四类反馈与它们的出现时机
///
/// | 指示器 | 触发 | 位置 |
/// |---|---|---|
/// | 亮度 | 左半屏上下滑 | 屏幕中央圆形 |
/// | 音量 | 右半屏上下滑 | 屏幕中央圆形 |
/// | 快进/快退 | 横向滑动 | 屏幕中央胶囊 |
/// | 长按倍速 | 长按 500ms | 屏幕中央胶囊（**持续显示**） |
///
/// ## 为什么全部忽略指针事件
/// 它们盖在画面正中 —— 若吃掉手势，用户滑动到一半松手再滑会失效。
/// 统一 `IgnorePointer`（本项目弹幕层也踩过同一个坑）。
///
/// ## ⚠️ 真实事故（2026-10-07 真机实测，**视频完全无法操作**）
///
/// 本文件曾**只在非长按分支**包 `IgnorePointer`：
/// ```dart
/// if (isLongPressing) {
///   return _CenterSlot(...);        // ← 没有 IgnorePointer！
/// }
/// return IgnorePointer(child: ...);  // ← 只有这里有
/// ```
/// 而 `_CenterSlot` 是 `Center(child: ...)`，在 `Positioned.fill` 下会
/// **撑满全屏并吃掉所有指针事件**。
///
/// 于是只要 `isLongPressing` 为 true，**整个播放页的点击/滑动全部失效** ——
/// 而长按本身又因为收不到 `pointerUp` 无法结束 → 状态永久卡在长按 →
/// **UI 从此再也点不动**（用户实测现象：屏幕常驻"3.0x 快进中"，
/// 单击、双击、滑动、按钮**全部无反应**）。
///
/// **教训**：反馈层是"纯展示层"，它**任何分支**都不能参与命中测试。
/// 故现在把 `IgnorePointer` 提到**最外层统一包**，而不是在各分支里各写一遍 ——
/// 后者必然漏（本次就是漏在长按分支）。
library;

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../domain/models/gesture_state.dart';
import '../player_ui_tokens.dart';

/// 反馈层容器：根据手势状态决定显示哪个指示器。
///
/// ⚠️ **根节点永远是 `IgnorePointer`**（见文件头的事故说明）——
/// 任何新增分支都不要绕过它。
class PlayerFeedbackLayer extends StatelessWidget {
  const PlayerFeedbackLayer({
    super.key,
    required this.gesture,
    required this.isLongPressing,
    required this.longPressSpeed,
    this.volumePercent,
  });

  final GestureState gesture;

  /// 长按快进中（优先于其他指示器显示）。
  final bool isLongPressing;
  final double longPressSpeed;

  /// 音量显示用 0–100（与手势的 0–100 一致）。
  final double? volumePercent;

  @override
  Widget build(BuildContext context) {
    // 外层 `IgnorePointer` 是**唯一入口**：里面的分支只管"显示什么"，
    // 结构上不可能绕过命中过滤。新增分支时也不会漏。
    //
    // ## 关于"是否必要"的更正（我先前写过两个错误理由，勿再沿用）
    //
    // 理由 A（已推翻）：「长按分支不包 IgnorePointer → `Center` 撑满全屏
    //   吃掉指针 → UI 永久卡死」。**反证注入实验表明行为用例全绿** ——
    //   因为 `_Pill`/`_LevelIndicator` 各自都自带 `IgnorePointer`，
    //   且 `Center` 本身 `hitTestSelf=false`。故这不是"卡死"的成因。
    //   提到最外层仍是**更好的结构**（不易漏），但属"防未来"而非"修现状"。
    //
    // 理由 B（已推翻）：「必须设 `ignoringSemantics: false`，否则丢语义」。
    //   最小实验显示 `IgnorePointer(child: Semantics(…))` 的语义
    //   **本来就能被读到**，不需要该参数；且它在 Flutter 3.8 后
    //   **已废弃**（analyze 报 `deprecated_member_use`）。
    //   故用默认值 —— 既不丢语义，也不依赖废弃 API。
    return IgnorePointer(child: _buildIndicator(context));
  }

  /// 只决定"显示哪个指示器"，**不负责**命中过滤（外层已统一处理）。
  Widget _buildIndicator(BuildContext context) {
    // 长按倍速：**透明小徽章 + 左上角**（用户要求：不遮挡视频）
    //
    // ⚠️ 不用 `_CenterSlot`（居中）—— 那会正好压住画面主体，
    //    而长按是持续状态，遮挡时间最久。
    if (isLongPressing) {
      // 位置选右上的理由（不是"居中随便挪个角"）：
      //   · 居中会压住画面主体，且长按是持续状态，遮挡最久
      //   · 左上角与顶栏返回按钮同区（顶栏全宽，y<480）
      //   · 右上、顶栏**下方**：不撞顶栏，也不撞右中部的锁按钮
      //     （锁按钮实测 y 474..606；徽章放 top≈90..300 一带）
      return Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 16, top: 90),
          child: _LongPressBadge(speed: longPressSpeed),
        ),
      );
    }

    return switch (gesture.mode) {
      GestureMode.brightness => _CenterSlot(
          child: _LevelIndicator(
            icon: Icons.brightness_6,
            value: gesture.currentBrightness,
            max: 100,
            label: '亮度',
          ),
        ),
      GestureMode.volume => _CenterSlot(
          child: _LevelIndicator(
            icon: Icons.volume_up,
            value: gesture.currentVolume,
            max: 100,
            label: '音量',
          ),
        ),
      GestureMode.seek => _CenterSlot(
          child: _Pill(
            icon: gesture.deltaRatio >= 0
                ? Icons.fast_forward
                : Icons.fast_rewind,
            text: _seekText(gesture),
          ),
        ),
      // none / dead：不显示任何东西（死区就该"什么都不发生"）
      GestureMode.none || GestureMode.dead => const SizedBox.shrink(),
    };
  }

  /// `+35s` / `-12s`（原型用 `Math.round(deltaSeconds)`）。
  static String _seekText(GestureState g) {
    final start = g.startPositionInVideo;
    final target = g.currentSeekTarget;
    final delta = (target - start).inSeconds;
    final sign = delta > 0 ? '+' : '';
    return '$sign${delta}s';
  }
}

/// 居中放置。
class _CenterSlot extends StatelessWidget {
  const _CenterSlot({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(child: child);
}

/// 胶囊型提示（快进/长按倍速）。
/// 长按快进提示 —— **透明、小、不遮挡画面**（用户要求）。
///
/// ## 用户反馈（2026-10-07）
/// "长按快进的显示应该也是透明且小的，不遮挡播放的视频"
///
/// ## 原来的问题
/// 与 seek/亮度/音量共用 [_Pill]：`Color(0xCC000000)`（80% 黑）+ 16px 字 +
/// **屏幕正中**。后果：
///   · 一块近黑的牌子压在画面中央 → 看视频时正好挡住主体
///   · 长按是**持续**状态（不像 seek 一闪而过），遮挡时间最长
///
/// ## 现在的设计
/// | 维度 | 原 | 现 |
/// |---|---|---|
/// | 位置 | 屏幕正中 | **左上角**（避开画面主体） |
/// | 底色 | `0xCC000000` 80% 黑 | `0x33FFFFFF` 20% 白（**很淡**） |
/// | 字号 | 16 | 12 |
/// | 图标 | 22 | 14 |
/// | 内边距 | 18×12 | 8×4 |
///
/// ## 为什么底色用"淡白"而不是"更淡的黑"
/// 视频画面可能是亮的也可能是暗的。黑色在暗画面上看不见（等于没提示），
/// 淡白在亮画面上会被冲淡 —— 两者都不可靠。
/// 折中：**20% 白 + 深色文字阴影**（阴影保证亮背景上可读，
/// 白底保证暗背景上有对比）。这比纯黑在两种极端下都更稳。
class _LongPressBadge extends StatelessWidget {
  const _LongPressBadge({required this.speed});

  final double speed;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: PlayerUi.longPressBg,
          borderRadius: BorderRadius.circular(Cf.radiusXs),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fast_forward,
                size: 14, color: PlayerUi.longPressText),
            const SizedBox(width: 4),
            Text(
              '${speed.toStringAsFixed(1)}x',
              style: const TextStyle(
                color: PlayerUi.longPressText,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
                // 阴影让文字在**亮画面**上也读得到（淡白底挡不住亮背景）
                shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// seek 反馈胶囊（快进/快退）。
///
/// ⚠️ 长按快进**不再用它** —— 长按有自己的 [_LongPressBadge]
/// （更小、更透明、左上角）。本组件现在只服务 seek。
class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: PlayerUi.feedbackBg,
          borderRadius: BorderRadius.circular(PlayerUi.feedbackRadius),
          border: Border.all(color: Colors.white24, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: Colors.white),
            const SizedBox(width: 10),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆形电量式指示器（亮度/音量）。
///
/// 用 `CircularProgressIndicator` 而不是横向条：
/// 圆形在画面正中不会像横条那样"割裂"画面，也更像系统级的音量提示。
class _LevelIndicator extends StatelessWidget {
  const _LevelIndicator({
    required this.icon,
    required this.value,
    required this.max,
    required this.label,
  });

  final IconData icon;
  final double value;
  final double max;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ratio = (value / max).clamp(0.0, 1.0);
    return Semantics(
      // ## 为什么加语义（两个理由）
      // 1. **无障碍**：读屏用户滑动调亮度/音量时，应听到"亮度 60"。
      // 2. **可验证**：无 `Semantics` 时真机 `uiautomator` 读不到该节点 ——
      //    自动化无法区分"手势没启动"与"指示器无标签"。
      //
      // ## ⚠️ 一条被实验推翻的错误认知（留此以免重犯）
      // 我一度认为「`IgnorePointer` 会丢弃子树语义，所以 `Semantics`
      // 必须在外层」。**实测推翻**：`IgnorePointer(child: Semantics)`
      // 的语义同样能被找到（见 `_tmp_semantics_diag_test` 实验 3）。
      //
      // 真正让测试当初失败的是**匹配方式**：真实 label 是 `"亮度\n60"`
      // （Flutter 把 label 与 value 合并），
      // 而 `find.bySemanticsLabel('亮度')` 是精确匹配 → 恒 0。
      //
      // 现在写成 `Semantics(child: IgnorePointer(...))` 是**风格选择**
      // （语义在外的可读性更好），**不是**强制约束。
      liveRegion: true, // 值在滑动中持续变化 → 让读屏主动播报
      label: label,
      value: '${value.round()}',
      child: IgnorePointer(
        child: Container(
          width: PlayerUi.levelIndicatorSize,
          height: PlayerUi.levelIndicatorSize,
          decoration: const BoxDecoration(
            color: PlayerUi.feedbackBg,
            shape: BoxShape.circle,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: PlayerUi.levelIndicatorSize - 12,
                height: PlayerUi.levelIndicatorSize - 12,
                child: CircularProgressIndicator(
                  value: ratio,
                  strokeWidth: 4,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: Colors.white),
                  const SizedBox(height: 2),
                  Text(
                    '${value.round()}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    label,
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首次进入的手势提示（原型 `flashGestureHint`）。
///
/// 只在**第一次**进入播放器时显示一次 ——
/// 每次都弹会干扰用户（原型用 `hintShown` 标记，只展示一次）。
class PlayerGestureHint extends StatelessWidget {
  const PlayerGestureHint({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: PlayerUi.feedbackBg,
            borderRadius: BorderRadius.circular(PlayerUi.feedbackRadius),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _HintRow(icon: Icons.brightness_6, text: '左半屏上下滑调亮度'),
              SizedBox(height: 8),
              _HintRow(icon: Icons.volume_up, text: '右半屏上下滑调音量'),
              SizedBox(height: 8),
              _HintRow(icon: Icons.swipe, text: '横向滑动快进/快退'),
            ],
          ),
        ),
      ),
    );
  }
}

class _HintRow extends StatelessWidget {
  const _HintRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 8),
          Text(text,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      );
}
