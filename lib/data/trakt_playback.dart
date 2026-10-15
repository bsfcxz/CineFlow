/// **播放态同步**（「实时追踪」的实现）。
///
/// ## 职责边界（为什么单独一个文件）
/// `TraktSync` 只管**发请求**（HTTP 契约）。
/// 这里管**什么时候发** —— 这是完全不同的关注点：
/// · 播放器会高频回调 position（每秒多次）⇒ 必须节流
/// · 契约规定 `stop` 在 1%–79% 时会被服务端**降级为 pause**
///   ⇒ 我们不能假设"发了 stop 就是看完了"
/// · 409（刚 scrobble 过）/ 422（<1%）**必然出现**，不能当错误刷日志
///
/// ## 契约来源
/// `trakt/trakt-api` 的 `contracts/scrobble/index.ts`：
/// · `start` —— 开始播放**或取消暂停**时调用；**会清空**播放进度
/// · `pause` —— 暂停时调用（保留进度）
/// · `stop`  —— 停止/播完时调用；**>80% 视为看完**；1%–79% 降级为 pause；
///              **<1% 被忽略并返回 422**
library;

import 'package:flutter/foundation.dart';

import 'trakt_client.dart';

/// 播放进度上报的**节流器 + 状态机**。
///
/// ## 用法（在播放器里）
/// ```dart
/// final rep = TraktPlaybackReporter(sync: sync, episodeIds: ids);
/// await rep.onStarted();                    // 开始播放
/// await rep.onPaused(progressPercent);      // 暂停
/// await rep.onStopped(progressPercent);     // 退出/播完
/// ```
///
/// ## 为什么内部要记状态（而不是每次都发）
/// | 场景 | 若每次都发 |
/// |---|---|
/// | 用户反复取消暂停/暂停 | 每次都 `start` ⇒ start **会清空进度** ⇒ 把用户的播放位置抹掉 |
/// | 每秒 position 回调 | 请求淹没（且触发 Trakt 速率限制）|
class TraktPlaybackReporter {
  TraktPlaybackReporter({
    required this.sync,
    this.episodeIds,
    this.movieIds,
    this.movieTitle,
    this.movieYear,
    this.minInterval = const Duration(seconds: 10),
  });

  final TraktSync sync;

  /// 剧集 id（**必须能用** —— `usableForEpisode == true`，即含 trakt 或 tvdb）。
  final TraktIds? episodeIds;

  /// 电影 id（契约支持 tmdb）。
  final TraktIds? movieIds;
  final String? movieTitle;
  final int? movieYear;

  /// 同类动作的最小间隔。
  ///
  /// ## 为什么是 10 秒（不是随便定的）
  /// Trakt 官方对 scrobble 的建议是"每 10 秒或每次用户交互后上报"；
  /// 取 10 秒既满足语义，又避免频繁请求触发速率限制。
  final Duration minInterval;

  DateTime? _lastSentAt;
  TraktScrobbleAction? _lastAction;

  /// 是否具备上报条件（id 齐全）。
  ///
  /// ⚠️ **剧集只给了 tmdb 时返回 false** —— 那不是"配置问题"，
  /// 而是契约限制（episode ids 没有 tmdb）⇒ 调用方应先解析出 trakt/tvdb。
  bool get canReport {
    if (episodeIds != null) return episodeIds!.usableForEpisode;
    if (movieIds != null) return true;
    return false;
  }

  /// 开始播放（或**取消暂停**）。
  ///
  /// ⚠️ 契约：`start` 会**清空**已有进度 ⇒ 只在"真的从头/继续播"时调用，
  /// 不要在"同一秒内反复 play/pause"时重复发（这里的节流就是为它）。
  Future<TraktScrobbleResult> onStarted({double progress = 0}) {
    return _send(TraktScrobbleAction.start, progress);
  }

  /// 暂停（保留进度）。
  Future<TraktScrobbleResult> onPaused(double progressPercent) {
    return _send(TraktScrobbleAction.pause, progressPercent);
  }

  /// 停止/播完。
  ///
  /// ⚠️ 服务端**可能把它降级为 `pause`**（progress 1%–79%），
  /// 结果里的 `serverAction` 才是实际动作。
  Future<TraktScrobbleResult> onStopped(double progressPercent) {
    return _send(TraktScrobbleAction.stop, progressPercent);
  }

  Future<TraktScrobbleResult> _send(
      TraktScrobbleAction action, double progressPercent) async {
    if (!canReport) {
      // ⚠️ **不打 error 级日志** —— 这是"我们没有该剧的 trakt/tvdb id"，
      //    属可预期情况（新剧刚上线时 trakt 还没有），不是故障。
      debugPrint('[TraktTrack] 跳过 scrobble: ${action.name} '
          '(ids 不可用: ep=${episodeIds?.usableForEpisode}, mv=${movieIds != null})');
      return const TraktScrobbleResult(statusCode: 0, error: '缺少可用的 Trakt id');
    }

    // ── 节流：同类动作在 minInterval 内不重复 ──
    final now = DateTime.now();
    if (_lastAction == action && _lastSentAt != null &&
        now.difference(_lastSentAt!) < minInterval) {
      debugPrint('[TraktTrack] 节流跳过: ${action.name} '
          '(${now.difference(_lastSentAt!).inSeconds}s < '
          '${minInterval.inSeconds}s)');
      return const TraktScrobbleResult(statusCode: 0, error: '节流跳过');
    }
    _lastAction = action;
    _lastSentAt = now;

    // 契约：progress 是 0–100 的 float
    final p = progressPercent.clamp(0.0, 100.0);
    final r = await sync.scrobble(
      action: action,
      progress: p,
      episodeIds: episodeIds,
      movieIds: movieIds,
      movieTitle: movieTitle,
      movieYear: movieYear,
    );

    // ── 日志分级（409/422 不是错误）──
    if (r.ok) {
      debugPrint('[TraktTrack] ${action.name} ok  '
          'p=${p.toStringAsFixed(1)}%  server=${r.serverAction ?? '?'}');
    } else if (r.duplicate) {
      debugPrint('[TraktTrack] ${action.name} 409 重复（正常，忽略）');
    } else if (r.tooShort) {
      debugPrint('[TraktTrack] ${action.name} 422 进度<1%（正常，忽略）');
    } else {
      debugPrint('[TraktTrack] ${action.name} 失败 code=${r.statusCode} '
          '${r.error ?? ''}');
    }
    return r;
  }
}
