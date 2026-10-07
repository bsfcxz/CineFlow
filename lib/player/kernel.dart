/// 播放内核抽象 —— player_page / pan115_player 只依赖此接口。
///
/// ## 为什么要有这一层
///
/// 迁移前的 `player_page.dart` 直接 `new Player()`（media_kit），
/// 于是"换内核"等于"改 2000 行播放器页"。抽出 [PlayerKernel] 后：
///   - UI / 手势 / 弹幕 / 进度上报**一行不动**（它们只认门面 API）；
///   - 换内核 = 新增一个实现类 + 改工厂一行。
///
/// 唯一实现是 [NativeKernel]（安卓原生 mpv，MethodChannel + PlatformView）。
///
/// ## 与 media_kit API 的对应关系
///
/// 这里的 API 面是**刻意对齐 media_kit `Player` 的子集**的，
/// 目的就是让 `player_page.dart` 的改动量降到最低。
/// 成员名（`state` / `stream` / `open` / `setAudioTrack`…）都保持原样。
library;

import 'dart:async';

import 'domain/player_constants.dart' show DecodeMode;

/// 内核统一状态快照（对齐 media_kit `Player.state` 的使用面）
class KernelState {
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final bool playing;
  final bool buffering;
  final double rate;

  /// 音量 0~100（竖滑手势要读它作为起点）
  final double volume;

  const KernelState({
    required this.position,
    required this.duration,
    required this.buffer,
    required this.playing,
    required this.buffering,
    required this.rate,
    this.volume = 100,
  });

  KernelState copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffer,
    bool? playing,
    bool? buffering,
    double? rate,
    double? volume,
  }) {
    return KernelState(
      position: position ?? this.position,
      duration: duration ?? this.duration,
      buffer: buffer ?? this.buffer,
      playing: playing ?? this.playing,
      buffering: buffering ?? this.buffering,
      rate: rate ?? this.rate,
      volume: volume ?? this.volume,
    );
  }
}

/// 轨道信息（统一形状；native 侧由 mpv `track-list` JSON 归一化）
///
/// `id` 用 String 而非 int：mpv 的 `aid`/`sid` 支持 `auto` / `no` 这两个
/// 字面量，用 int 会丢掉"关闭字幕"的表达能力。
///
/// ## 为什么字段这么多（用户要求）
/// > "多音轨多字幕这种，我在选择的时候你显示出名称，像字幕的话
/// >  有中字、双语、繁体等"
///
/// 只靠 `title` 往往**分不清**两条轨：实测片源里常见
/// `Audio --aid=1 (aac 2ch)` vs `Audio --aid=3 (eac3 6ch)` ——
/// 两者 title 都为空，**声道数与编解码才是唯一区分点**。
/// 而字幕常常只有 `language`（`chi`/`zho`/`eng`）没有 title。
///
/// 故这里保留 mpv `track-list` 里所有对"人做选择"有用的字段。
class KernelTrack {
  final String id;
  final String? title;
  final String? language;

  /// 编解码器（如 `aac` / `eac3` / `mov_text` / `ass`）
  final String? codec;

  /// 音频声道数（如 `2` / `6`）—— 多音轨时最有效的区分点
  final int? channels;

  /// **ffmpeg 全局流索引**（mpv `track-list[].ff-index`）。
  ///
  /// ## 为什么必须有它（对齐 Emby 轨道的唯一可靠键）
  ///
  /// `id`（= `aid`/`sid`）是 **每种类型独立从 1 开始**编号的：
  /// 典型 MKV 里 audio 的 aid 可能是 1，而 sub 的 sid 也是 1。
  /// 而 Emby 的 `MediaStream.Index` 是 **ffmpeg 的全局流索引**
  /// （video=0, audio=1, sub=2）。
  ///
  /// 两者**不是同一套编号** → 用 `id` 去匹配 Emby 的 `Index` 会**切错轨**
  /// （多音轨/多字幕时尤其明显）。
  ///
  /// mpv 的 `ff-index` 才与 Emby `Index` 同源。故：
  /// **要按服务端轨道选轨，请匹配 `ffIndex`；`id` 只用于发给 mpv 执行切换。**
  ///
  /// 注：mpv 文档提示 `ff-index` 在非 libavformat 解封装时可能不可用
  /// （此时为 null，调用方应回退到顺序匹配）。
  final int? ffIndex;

  /// 是否默认轨（mpv `default` 字段）
  final bool isDefault;

  /// 是否外挂（mpv `external` 字段）—— 外挂字幕常需特别标注
  final bool isExternal;

  /// 是否强制字幕（mpv `forced` 字段）
  final bool isForced;

  const KernelTrack({
    required this.id,
    this.title,
    this.language,
    this.codec,
    this.channels,
    this.ffIndex,
    this.isDefault = false,
    this.isExternal = false,
    this.isForced = false,
  });

  /// 人类可读的显示名（选择列表与控制条都用它）。
  ///
  /// 拼装规则（按信息量从高到低，**只保留有值的部分**，用 ` · ` 连接）：
  ///   1. `title` —— 片源里最准确的描述（"简体中文"、"双语"、"评论音轨"）
  ///   2. 语言标签 —— title 缺失或未提及时补上（`chi`→中文）
  ///   3. 声道数 —— 多音轨的关键区分（`5.1 声道` / `立体声`）
  ///   4. 编解码 —— **总是附上**：`eac3` vs `aac` 代表不同音质，
  ///      且实测多轨片源常靠它才能区分（两条轨 title/语言/声道都一样时）
  ///   5. 标记 —— 强制 / 外挂
  ///
  /// 例：`国语 · 5.1 声道 · eac3` / `中文 · 外挂` / `日语 · 立体声 · aac`
  String get displayName {
    final parts = <String>[];

    final t = title?.trim();
    final hasTitle = t != null && t.isNotEmpty;
    if (hasTitle) parts.add(t);

    // title 已含语言信息时不必重复（如 title 就是"简体中文"）
    final lang = _languageLabel;
    if (lang != null && !_titleMentionsLanguage(t, lang)) parts.add(lang);

    final ch = _channelLabel;
    if (ch != null) parts.add(ch);

    // codec 总是附上（有值时）：它是最细粒度的区分点，
    // 只在"其它段都没有"时才用会丢掉关键信息（eac3 与 aac 音质差别明显）。
    final c = codec?.trim();
    if (c != null && c.isNotEmpty) parts.add(c);

    if (isForced) parts.add('强制');
    if (isExternal) parts.add('外挂');

    return parts.isEmpty ? '轨道 $id' : parts.join(' · ');
  }

  /// 语言标签归一化。
  ///
  /// mpv 给的是 ISO 639-2 三字码（`chi`/`zho`/`eng`/`jpn`），
  /// 直接显示对用户没意义。这里映射成中文名。
  String? get _languageLabel {
    final l = language?.trim().toLowerCase();
    if (l == null || l.isEmpty) return null;
    return switch (l) {
      'chi' || 'zho' || 'zh' || 'chs' || 'cht' => '中文',
      'eng' || 'en' => '英语',
      'jpn' || 'ja' => '日语',
      'kor' || 'ko' => '韩语',
      'fra' || 'fre' || 'fr' => '法语',
      'deu' || 'ger' || 'de' => '德语',
      'spa' || 'es' => '西班牙语',
      'rus' || 'ru' => '俄语',
      'tha' || 'th' => '泰语',
      'vie' || 'vi' => '越南语',
      'por' || 'pt' => '葡萄牙语',
      'ita' || 'it' => '意大利语',
      'ara' || 'ar' => '阿拉伯语',
      _ => l.toUpperCase(), // 未知语言直接显示码，至少能区分
    };
  }

  String? get _channelLabel {
    final c = channels;
    if (c == null || c <= 0) return null;
    return switch (c) {
      1 => '单声道',
      2 => '立体声',
      6 => '5.1 声道',
      8 => '7.1 声道',
      _ => '$c 声道',
    };
  }

  /// title 里是否已经提到了这个语言（避免"简体中文 · 中文"这种重复）
  static bool _titleMentionsLanguage(String? title, String langLabel) {
    if (title == null || title.isEmpty) return false;
    // "简体中文"/"繁体中文" 都含"中"；"国语"/"汉语"也算
    if (langLabel == '中文' &&
        (title.contains('中') || title.contains('国') || title.contains('汉'))) {
      return true;
    }
    if (langLabel == '英语' && (title.contains('英') || title.contains('EN'))) {
      return true;
    }
    if (langLabel == '日语' && title.contains('日')) return true;
    return title.contains(langLabel);
  }
}

class KernelTracks {
  final List<KernelTrack> audio;
  final List<KernelTrack> subtitle;

  const KernelTracks({
    this.audio = const [],
    this.subtitle = const [],
  });
}

/// 当前选中轨道（id 可能为 'auto' / 'no' / 数字串）
class KernelSelection {
  final String audioId;
  final String subtitleId;

  const KernelSelection({this.audioId = 'auto', this.subtitleId = 'auto'});
}

/// 播放内核接口。
///
/// 实现者必须保证：
///   1. [dispose] 之后不再有任何事件推到 stream 上；
///   2. 所有 stream 都是 broadcast（UI 可能多处订阅）；
///   3. 错误只经 [errorStream] 暴露，**不抛异常给 UI**
///      （播放失败不该让整个页面炸掉）。
/// 内核能力项 —— UI 据此禁用做不到的功能（见 [PlayerKernel.supports]）。
enum EngineFeature {
  /// 画面滤镜：亮度 / 对比度 / 饱和度 / 色相。
  videoFilters,

  /// 音频延迟调节。
  audioDelay,

  /// 字幕延迟调节。
  subtitleDelay,

  /// 切换硬解/软解。
  decodeMode,

  /// 外挂字幕文件。
  externalSubtitle,

  /// 画面比例模式（裁剪/拉伸等；只有 `contain` 时也算支持）。
  aspectMode,
}

abstract class PlayerKernel {
  /// 引擎标识（'native'）
  String get engine;

  /// 原生视图标识（native 引擎返回 PlatformView 的 viewType）
  String? get viewType;

  /// Flutter 纹理 id（纹理输出型内核）；null = 本内核不用纹理渲染。
  ///
  /// 纹理型内核（mpv / Media3）在 [ensureTexture] 之后可用。
  /// 默认 null —— 未来的非纹理内核（如 PlatformView 型）无需理会。
  int? get textureId => null;

  /// 建纹理（纹理输出型内核覆盖；默认 no-op）。
  ///
  /// 必须在 [open] 之前完成，否则内核没有渲染目标。
  Future<void> ensureTexture({int width = 1920, int height = 1080}) async {}

  /// 视频宽高比（从流信息解析）；未知为 null（UI 回退 16:9）。
  double? get aspectRatio => null;

  /// 视频尺寸变化通知（分辨率切换/首帧解析时触发，UI 重算宽高比）。
  /// 默认空流 —— 非纹理内核无需理会。
  Stream<void> get videoSizeStream => const Stream.empty();

  /// 打开媒体。
  ///
  /// [headers] 是**必须原样透传**的 HTTP 头：
  /// 115 网盘的 CDN 直链与取址 UA 强绑定，且要带 `download_token` Cookie，
  /// 两者都不在 URL 里。漏掉 → CDN 403 → 现象是"地址取到了但播不了"。
  Future<void> open(
    String url, {
    bool play = true,
    Duration? start,
    Map<String, String>? headers,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> togglePlay();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> setAudioTrack(String id);
  Future<void> setSubtitleTrack(String id);

  // ---------------- 引擎能力协商（双内核的关键）----------------
  //
  // ## 为什么需要"能力声明"
  //
  // 本项目有**两个内核**：自持 mpv（`NativeKernel`）与 androidx.media /
  // Media3（`Media3Kernel`）。两者能力**不等价**：
  //
  // | 能力 | mpv | Media3 |
  // |---|---|---|
  // | 视频滤镜（亮度/对比度/饱和度/色相） | ✅ 原生 property | ❌ 需自叠 GL 层 |
  // | 音视频延迟 | ✅ `audio-delay`/`sub-delay` | ⚠️ 无等价属性，需时间戳偏移 |
  // | 换解码方式（硬/软） | ✅ | ⚠️ 仅部分支持 |
  //
  // UI 必须**据此禁用**做不到的项 —— 否则用户点了没反应，
  // 会以为"功能坏了"（这比"功能不存在"更糟，本项目已踩过：
  // `default_rate` 有读无写，用户设了倍速却没生效）。
  //
  // 规格要求"UI 不直接依赖具体播放器实现"，能力协商正是这条约束的落点：
  // UI 只问 `kernel.supports(EngineFeature.videoFilters)`，
  // 不关心背后是 mpv 还是 Media3。
  bool supports(EngineFeature feature);

  /// 设置画面滤镜（亮度/对比度/饱和度/色相）。
  ///
  /// 取值范围按规格 §7.6：前三个 −100…+100、色相 −180…+180。
  /// 不支持的内核应**静默忽略**（而非抛异常）——
  /// UI 已据 [supports] 禁用入口，万一真被调用也不该中断播放。
  Future<void> setVideoFilters({
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
  });

  /// 音频延迟（正 = 音频延后于画面）。
  Future<void> setAudioDelay(Duration delay);

  /// 字幕延迟（正 = 字幕延后于画面）。
  Future<void> setSubtitleDelay(Duration delay);

  /// 设置解码方式（硬解/软解）。
  Future<void> setDecodeMode(DecodeMode mode);

  KernelState get state;
  KernelTracks get tracks;
  KernelSelection get selection;

  Stream<KernelState> get stateStream;
  Stream<KernelTracks> get tracksStream;
  Stream<KernelSelection> get selectionStream;

  /// 错误消息（空串无意义）
  Stream<String> get errorStream;

  /// 播放完成（end-file reason=eof）
  Stream<bool> get completedStream;

  Future<void> dispose();
}
