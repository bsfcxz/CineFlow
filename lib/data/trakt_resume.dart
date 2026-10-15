// ══════════════════════════════════════════════════════════════════════
//  Trakt「续播检查」—— 把 Trakt 的播放进度接进播放器
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户要的
// > 现在完善 trakt 中的实时追踪、同步已看状态，**续播检查**等
//
// ## 开关语义（`kTraktResumeKey`，设置页已存在）
// 「续播检查」= 起播时问 Trakt "这一集我看到哪了"，
// 若 Trakt 的进度**明显领先**本地 ⇒ 提示用户"要从 Trakt 的进度继续吗"。
//
// ## ★ 为什么不是"直接用 Trakt 的进度起播"
// 本地已有 Emby 的进度（`MediaItem.progress`），两个来源会**打架**：
// ```
// Emby:  看到 40%（用户在手机上看的）
// Trakt: 看到 75%（用户在电视/网页上看的）
// ```
// ⇒ **不能静默覆盖**。正确做法（与 §6.9.1 的"删除要保守"同源）：
//   · Trakt 进度**领先本地 ≥5%** ⇒ **问用户**（不自动跳）
//   · Trakt 进度落后或相近 ⇒ **忽略**（本地更可信，它来自当前服务器）
//   · 用户没开开关 / 没登录 ⇒ 完全不查（**零额外请求**）
//
// ## 实测依据（Trakt 契约 + 我们的实测）
// ```
// GET /sync/playback?limit=100 → 200
//   [{ progress: float(0-100), paused_at, type:'movie'|'episode',
//      movie? | episode?+show? }]
// ```
// ⚠️ 401 未登录时**正常**（不是错误）⇒ 静默跳过。
library;

import 'package:flutter/foundation.dart';

import 'trakt_client.dart';

/// 续播检查的结果（**只表达"要不要问用户"**，不直接跳转）。
///
/// ## 为什么单独一个类型（而不是返回 double?）
/// 调用方要能区分三种情况，否则会写出"0 也要提示"这种 bug：
/// | 情况 | 含义 | UI 动作 |
/// |---|---|---|
/// | `null` | 没查到 / 开关关 / 未登录 | 什么都不做 |
/// | `skip`（见 [TraktResumeHint.shouldPrompt] == false）| Trakt 进度不领先 | 什么都不做 |
/// | `prompt` | Trakt 明显领先 | **问用户** |
class TraktResumeHint {
  const TraktResumeHint({
    required this.traktPct,
    required this.localPct,
    this.season,
    this.number,
    this.title,
  });

  /// Trakt 上的进度（0–100）。
  final double traktPct;

  /// 本地的进度（0–100；来自 Emby 的 `MediaItem.progress`）。
  final double localPct;

  final int? season;
  final int? number;
  final String? title;

  /// **领先阈值**（百分点）。
  ///
  /// ## 为什么是 5 而不是 1
  /// 两个系统各自上报，**必然有抖动**（上报间隔、四舍五入）。
  /// 实测 scrobble 的 progress 是 float，但 Emby 侧的 `PlaybackPositionTicks`
  /// 转百分比后与 Trakt 常有 1–3% 的差。
  /// ⇒ 阈值太小会**频繁弹无意义的提示**（用户会烦），太大则漏掉真实差异。
  /// 5% 对一集 45 分钟 ≈ 2.2 分钟，是"确实看过头了"的量级。
  static const leadThreshold = 5.0;

  /// 是否值得**问用户**（而不是直接跳）。
  bool get shouldPrompt => traktPct - localPct >= leadThreshold;

  /// 给用户看的差值（四舍五入到整数百分点）。
  ///
  /// ## ⚠️ 为什么要"先加极小量再 round"（实测踩到的浮点坑）
  /// ```
  /// 74.6 - 40.1 = 34.499999999999996   ← 二进制浮点表示误差
  /// (74.6 - 40.1).round() = 34          ← 期望 35
  /// ```
  /// 这两个数在**十进制**里差 34.5（应进位），但浮点减法给出的
  /// `34.4999...` 让 `round()` 向下取。
  /// ⇒ 加一个远小于显示精度、又大于累积误差的 epsilon（1e-9）。
  ///
  /// ⚠️ **不要**改成"先转字符串再解析"之类的做法：那只是把误差
  ///    藏起来，`shouldPrompt` 用的是原始 double，两者会不一致。
  int get leadPct {
    final d = traktPct - localPct;
    return (d + (d >= 0 ? 1e-9 : -1e-9)).round();
  }

  @override
  String toString() => 'TraktResumeHint(trakt=$traktPct%, local=$localPct%, '
      'S$season E$number)';
}

/// 续播检查器。
///
/// ## 为什么做成"可注入 clock/token"的小类（而不是塞进页面）
/// 页面里写这段会有两个问题：
/// ① **没法单测**（本仓库已因"点了没反应"型缺陷吃过亏，见 §8.1）
/// ② 播放器页已经 3300+ 行（§6.10 规则⑤：大文件改动前先划边界）
class TraktResumeChecker {
  TraktResumeChecker({required this.sync, this.debugLabel = ''});

  final TraktSync sync;

  /// 日志前缀（便于分辨是哪个页面的调用）。
  final String debugLabel;

  /// 查 Trakt 上这一集的进度，并与本地比对。
  ///
  /// [tmdbShowId] 是**剧的** tmdb（不是集级的 —— 见 `TraktEpisodeResolver`
  /// 的注释：`Episode.ProviderIds` 里的 Tmdb 是**集级**的，用错会匹配不上）。
  ///
  /// ## 返回 null 的全部情况（**都不是错误**）
  /// · 未登录（401）⇒ 静默
  /// · 网络失败 ⇒ 静默（续播检查是**增强**，不能影响起播）
  /// · Trakt 上没有这部剧的记录 ⇒ 静默
  /// · 没找到匹配的季/集 ⇒ 静默
  Future<TraktResumeHint?> check({
    required String tmdbShowId,
    required int season,
    required int number,
    required double localPct,
  }) async {
    if (tmdbShowId.trim().isEmpty) return null;
    if (number <= 0) return null;
    try {
      final list = await sync.getPlayback(limit: 100);
      if (list.isEmpty) {
        debugPrint('[TraktResume$debugLabel] Trakt 无播放记录');
        return null;
      }
      // ① 先按 tmdb 找到这部剧（TraktPlaybackItem.tmdbShowId）
      // ⚠️ tmdb 在 episode 模式下**可能缺失**（契约限制）⇒ 也接受
      //    "按季/集号匹配且 tmdb 相同"的条目；tmdb 缺失的条目**不能**
      //    仅凭季集号就认（不同剧的 S1E1 到处都是）。
      final want = int.tryParse(tmdbShowId);
      final hit = list.where((e) =>
          e.type == 'episode' &&
          e.season == season &&
          e.number == number &&
          e.tmdbShowId != null &&
          (want == null || e.tmdbShowId == want)).firstOrNull;
      if (hit == null) {
        debugPrint('[TraktResume$debugLabel] Trakt 无 S$season E$number 的记录'
            '（共 ${list.length} 条）');
        return null;
      }
      final hint = TraktResumeHint(
        traktPct: hit.progress,
        localPct: localPct,
        season: hit.season,
        number: hit.number,
        title: hit.title,
      );
      debugPrint('[TraktResume$debugLabel] $hint '
          '⇒ ${hint.shouldPrompt ? "值得问用户" : "不领先，忽略"}');
      return hint;
    } catch (e) {
      // ★ 续播检查失败**绝不影响播放**（它是锦上添花）
      debugPrint('[TraktResume$debugLabel] 检查失败（不影响播放）: $e');
      return null;
    }
  }
}
