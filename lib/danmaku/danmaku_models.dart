/// 弹幕数据模型 —— 对齐弹弹Play 兼容协议。
///
/// ## 协议来源
///
/// 弹弹Play 的弹幕接口被多个自建服务实现（`danmu_api`、`misaka_danmu_server`），
/// 它们共用同一套**条目形状**，因此本仓库只针对该形状建模，不绑定具体服务。
///
/// 官方接口 `api.dandanplay.net` 在本机网络**不可达**（实测 HTTP 000），
/// 故实际使用自建服务；这反过来也说明**接口形状必须按兼容协议写**，
/// 而不是围绕某个具体服务的私有字段。
///
/// ## 防御式解析
///
/// 遵循 AGENTS.md §5.3：自建服务的实现质量参差，
/// 字段缺失/类型不符是常态，一律不抛异常、给默认值。
library;

/// 一条弹幕。
class Danmaku {
  const Danmaku({
    required this.timeMs,
    required this.text,
    this.mode = DanmakuMode.scroll,
    this.color = 0xFFFFFF,
    this.fontSize = 25,
    this.userHash = '',
  });

  /// 出现时间（毫秒）。协议里是秒（浮点），这里统一成毫秒避免各处乘 1000。
  final int timeMs;

  /// 弹幕文本。空文本在解析阶段就被丢弃。
  final String text;

  final DanmakuMode mode;

  /// RGB 颜色（不含 alpha）。协议里是十进制整数。
  final int color;

  final int fontSize;

  /// 发送者标识（用于按用户屏蔽；自建服务常返回空串）。
  final String userHash;

  /// 清洗弹幕文本。
  ///
  /// ⚠️ 某些兼容服务（实测 danmu_api）会给 `m` 追加**非内容后缀**：
  ///   - 重复计数：`原文\u200Ax\u200A3`（该弹幕被发了 3 次）
  ///   - 点赞标记：`原文\u200A♡12` 或 `原文\u200A🔥3.2k`
  /// 这些是元数据不是弹幕内容，直接显示会出现「哈哈 x 3 ♡12」这种杂乱文本。
  ///
  /// 分隔符是 `\u200A`（hair space）而非普通空格——用普通空格去匹配会失败。
  static String cleanText(String raw) {
    var s = raw.replaceAll('\u200A', ' ').trim();
    // 去掉尾部的 ×N / xN 计数
    s = s.replaceFirst(RegExp(r'\s*[x×]\s*\d{1,4}\s*$'), '').trim();
    // 去掉尾部的点赞/热度标记
    s = s.replaceFirst(RegExp(r'\s*[♡❤🔥]\s*[\d.]+[kwKW]?\s*$'), '').trim();
    return s;
  }

  /// 从弹弹Play 的 `p` 字段解析。
  ///
  /// ## ⚠️ 有两种格式，段数不同且**颜色位置不同**（实测踩过）
  ///
  /// 1. **弹弹Play 原生（4 段）**——官方接口与本项目直连时使用：
  ///    `时间(秒), 模式, 颜色(十进制), 发送者ID`
  ///    真实 fixture：`"0.01,1,16777215,[Gamer]hui0810yong"`
  ///    → **颜色在 index 2**，第 4 段是发送者 ID（不是颜色！）
  ///
  /// 2. **B站格式（8 段）**——部分兼容服务（如 danmu_api 的 `format=xml`）使用：
  ///    `时间, 模式, 字号, 颜色, 时间戳, 弹幕池, 用户hash, 行ID`
  ///    → 颜色在 index 3，且 index 2 是字号
  ///
  /// 首版按 B站 8 段解析官方数据，结果把**字号当颜色**、
  /// 把**颜色当用户 ID**——弹幕颜色会全错，但不会报错。
  ///
  /// 判别依据：段数 ≥ 8 走 B站布局；否则按原生 4 段。
  /// 再加一条兜底：index 2 若 ≤ 64（不可能是颜色，更像字号）
  /// 且 index 3 > 255（像颜色），也判为 B站布局。
  static Danmaku? fromP(String cid, String p, String m) {
    final text = cleanText(m);
    if (text.isEmpty) return null;

    final parts = p.split(',');
    if (parts.isEmpty) return null;

    final seconds = double.tryParse(parts[0].trim());
    if (seconds == null || seconds.isNaN || seconds < 0) return null;

    // 模式：1/2/3 = 滚动，4 = 底部，5 = 顶部（两种格式一致）。
    // 未知值按滚动处理——显示总比丢掉好。
    final rawMode = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
    final mode = switch (rawMode) {
      4 => DanmakuMode.bottom,
      5 => DanmakuMode.top,
      _ => DanmakuMode.scroll,
    };

    final i2 = parts.length > 2 ? int.tryParse(parts[2].trim()) : null;
    final i3 = parts.length > 3 ? int.tryParse(parts[3].trim()) : null;

    // 是否 B站 8 段布局
    final bili = parts.length >= 8 ||
        (i2 != null && i3 != null && i2 <= 64 && i3 > 255);

    final fontSize = bili ? (i2 ?? 25) : 25;
    final color = bili ? (i3 ?? 0xFFFFFF) : (i2 ?? 0xFFFFFF);
    final hashIdx = bili ? 6 : 3;
    final hash = parts.length > hashIdx ? parts[hashIdx].trim() : '';

    return Danmaku(
      timeMs: (seconds * 1000).round(),
      text: text,
      mode: mode,
      // 颜色夹到 24 位：兼容服务偶尔返回带 alpha 的 32 位数，
      // 直接给 Flutter 会因 alpha=0 变成全透明（弹幕"消失"且无从排查）。
      color: color & 0xFFFFFF,
      fontSize: fontSize.clamp(12, 64),
      userHash: hash,
    );
  }
}

enum DanmakuMode {
  /// 从右向左滚动（绝大多数弹幕）
  scroll,

  /// 顶部固定
  top,

  /// 底部固定（字幕位，应避免与字幕重叠）
  bottom,
}

/// 一次弹幕拉取的结果。
class DanmakuBatch {
  const DanmakuBatch({
    required this.items,
    this.episodeId,
    this.animeTitle,
    this.episodeTitle,
  });

  final List<Danmaku> items;

  /// 服务端确认的剧集 id（可回写以便下次直接命中）
  final int? episodeId;
  final String? animeTitle;
  final String? episodeTitle;

  static const empty = DanmakuBatch(items: []);

  /// 按时间排序（渲染层假定有序，乱序会导致"弹幕突然补发一堆"）
  DanmakuBatch sorted() => DanmakuBatch(
        items: [...items]..sort((a, b) => a.timeMs.compareTo(b.timeMs)),
        episodeId: episodeId,
        animeTitle: animeTitle,
        episodeTitle: episodeTitle,
      );
}

/// 弹幕源的服务类型。
///
/// 两者**协议相同**（都兼容 `/api/v2/comment/{episodeId}`），
/// 唯一区别是异步生成支持：
/// - [dandanplayCompat]：直接调同步接口，适配所有兼容弹弹Play 的服务
///   （含 `danmu_api`，以及 2.7.0 之前的 `misaka_danmu_server`）
/// - [misaka]：2.7.0+ 的 `misaka_danmu_server`，额外支持 `?async=1` 异步生成
enum DanmakuSourceKind {
  dandanplayCompat,
  misaka;

  String get label => switch (this) {
        DanmakuSourceKind.dandanplayCompat => '弹弹Play 兼容服务',
        DanmakuSourceKind.misaka => '御坂弹幕服务（Misaka）',
      };

  /// 是否使用异步生成（附加 `?async=1` 并轮询 taskId）
  bool get usesAsync => this == DanmakuSourceKind.misaka;
}

/// 拉取弹幕时的人为可读错误。
///
/// 不用裸 Exception：弹幕失败**不该影响播放**，UI 需要拿到
/// 可直接展示的中文原因（AGENTS.md §5.6 文案全中文）。
class DanmakuException implements Exception {
  const DanmakuException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
