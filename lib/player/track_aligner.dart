/// 服务端轨道 ↔ 播放内核轨道的**对齐**。
///
/// ## 为什么需要这个文件（用户指出的"致命问题"的最后一环）
///
/// 同一部片有**两套轨道描述**，各有各的用处，但**编号空间不同**：
///
/// | | 服务端（Emby） | 播放内核（mpv） |
/// |---|---|---|
/// | 数据 | `MediaStream`（`DisplayTitle`/`DisplayLanguage`/`IsDefault`/`IsForced`…） | `track-list[]`（`id`/`ff-index`/`codec`…） |
/// | 强项 | **名字可读**（`Chinese Simplified (PGSSUB)`）、有"默认"标记 | **能真正执行切换**（`aid`/`sid`） |
/// | 编号 | `Index` = **ffmpeg 全局流索引** | `id` = **每类型独立从 1 编号** |
///
/// 于是"用服务端的好名字 + 用内核真正切轨"需要一个**桥**。
/// 这个桥**不能是 `id`**：典型 MKV（video=0, audio=1, sub=2）下
/// 内核的 `sid` 是 **1** 而 Emby 的 `Index` 是 **2** —— **用 id 匹配会切错轨**。
///
/// 唯一正确的桥是 **mpv 的 `ff-index`**（与 Emby `Index` 同源）。
///
/// ## 降级策略（`ff-index` 可能不可用）
///
/// mpv 官方文档明确：`ff-index` 在非 libavformat 解封装时
/// *"can be potentially wrong"* 且 *"May be unavailable"*。故：
///   1. **优先 `ffIndex == server.Index` 精确匹配**
///   2. 缺失时按**同类型内出现顺序**匹配（第 n 条对第 n 条，跳过已占用的）
///   3. 都对不上 → 用内核自带信息兜底（名字差一点，但不崩、不断功能）
library;

import '../data/language_names.dart';
import '../data/models.dart';
import 'player_facade.dart';

/// 一条"对齐后"的轨道：**服务端的可读信息 + 内核的可执行 id**。
class AlignedTrack {
  const AlignedTrack({
    required this.kernelId,
    required this.label,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.matchedByIndex = false,
    this.language,
    this.codec,
    this.serverIndex,
  });

  /// 交给内核执行切换用的 id（`aid`/`sid`）—— **这是它的唯一用途**
  final String kernelId;

  /// 展示名（**优先服务端 `DisplayTitle`**）
  final String label;

  final bool isDefault;
  final bool isForced;
  final bool isExternal;

  /// 是否为 `ffIndex == Index` 的**精确**匹配。
  /// false = 走了顺序启发式（仅供诊断；UI 上不必区分）。
  final bool matchedByIndex;

  /// 服务端该流的语言码（如 `chi`/`eng`）—— 用于"首选轨不可解时找同语言轨"。
  final String? language;

  /// 服务端该流的编码（如 `truehd`）—— 用于**可解码性判断**。
  ///
  /// ⚠️ 来自服务端而非内核：mpv 的 `track-list` 里 `codec` 对音频常是
  /// 通用值（如 `eac3`），而服务端给的就是容器里写的那个（`truehd`）。
  final String? codec;

  /// 服务端该流的 `Index`（诊断用）。
  final int? serverIndex;
}

/// 内核轨道的**最小公共视图**（音轨/字幕共用）。
///
/// ## 为什么需要它（避免把匹配逻辑写两遍）
/// `FacadeAudioTrack` 与 `FacadeSubtitleTrack` 是两个类型、没有公共接口，
/// 但"按 `ffIndex` 找服务端流"的逻辑**完全一样**。
/// 第一版我写了两份（用 `dynamic`），既丑又容易不同步。
///
/// ⇒ 抽一个只有 3 个字段的**只读视图**，两个 Facade 类型各提供
///   `toKernelView()`，匹配逻辑只写一遍。
class AlignedKernelTrack {
  const AlignedKernelTrack({
    required this.id,
    required this.ffIndex,
    this.title,
    this.language,
  });

  final String id;
  final int? ffIndex;
  final String? title;
  final String? language;
}

/// 把服务端流与内核轨道对齐。
///
/// 音轨与字幕**各对齐各的** —— 两套编号互不相干
/// （服务端 `Index` 是全局的，但内核 `aid` 与 `sid` 是两个独立序列）。
abstract final class TrackAligner {
  /// 对齐音轨。[defaultIndex] = 服务端 `DefaultAudioStreamIndex`
  static List<AlignedTrack> alignAudio(
    List<MediaStream> server,
    List<FacadeAudioTrack> kernel, {
    int? defaultIndex,
  }) {
    final view = [
      for (final k in kernel)
        AlignedKernelTrack(
          id: k.id,
          ffIndex: k.ffIndex,
          title: k.title,
          language: k.language,
        ),
    ];
    return _align(      server: server,
      count: kernel.length,
      kernelView: view,
      serverIndexAt: (i) => server[i].index,
      // ★ 服务端标签改走 `chineseLabel`（把英文语言名换中文），
      //   并让内核的中文名参与（见该 getter 的说明）
      serverLabelAt: (i) {
        final kIdx = _kernelIndexFor(server, view, i);
        return server[i]
            .chineseLabel(kernelTitle: kIdx == null ? null : view[kIdx].title);
      },
      defaultIndex: defaultIndex,
      kernelFfIndexAt: (i) => kernel[i].ffIndex,
      kernelIdAt: (i) => kernel[i].id,
      serverLanguageAt: (i) => server[i].language,
      serverCodecAt: (i) => server[i].codec,
      // 内核自带信息兜底（仅在完全匹配不上时用）
      fallbackLabelAt: (i) {
        final k = kernel[i];
        return _kernelLabel(
          title: k.title,
          language: k.language,
          extras: [
            // ⚠️ 声道保留（用户能理解），**编码去掉**（用户要求）
            if (k.channels != null && k.channels! > 0) '${k.channels}ch',
          ],
          fallback: '音轨 ${k.id}',
        );
      },
    );
  }

  /// **音频编码在 Android 上是否可解码**（真机实测驱动）。
  ///
  /// ## 为什么需要（真机实测的"没声音"根因）
  /// 《复仇者联盟》的 `DefaultAudioStreamIndex=1` 是 **English TRUEHD 7.1**，
  /// 而 mpv 在 Android 上**解不了 TRUEHD**：
  /// ```
  /// [mpv/ad] Failed to initialize a decoder for codec 'truehd'.
  /// [mpv/cplayer] Audio: no audio
  /// ```
  /// ⇒ 忠实选服务端默认轨 = **播放无声**（用户报障）。
  ///
  /// ## 为什么以前有声音（重要）
  /// 修复 `parseTracks` 之前轨道列表恒为空 ⇒ `_applyServerDefaultTracks`
  /// **从不执行** ⇒ mpv 用自己的默认策略（跳过了 truehd，选了能解的）
  /// ⇒ 恰好有声。**修好解析后忠实选轨，反而暴露了这个真问题。**
  ///
  /// ## 判据从哪来（不猜）
  /// · **可以解**：`aac`/`ac3`/`eac3`/`mp3`/`opus`/`vorbis`/`flac`/
  ///   `dts`（Android 6+ 的 DTS 软解在 mpv 内置 ffmpeg 里可用）
  /// · **不可解（Android）**：`truehd`/`mlp`（Dolby TrueHD，
  ///   Android 没有 decoder）；`dts-hd`/`dtshd`（High-Res 扩展层）
  ///
  /// ⚠️ 这是**保守白名单**：不确定的一律**允许**（宁可让内核试，
  ///    也不要因为误判把用户能播的轨挡掉）。真不可解时 mpv 会报
  ///    `Failed to initialize a decoder`，那时我们再回退。
  /// **音频编码在给定内核上是否可解**。
  ///
  /// ## ★ 必须按内核区分（真机实测：两个内核的失败方式不同）
  /// | 编码 | mpv（自持 .so） | Media3（系统 MediaCodec） |
  /// |---|---|---|
  /// | `truehd` / `mlp` | ❌ `Failed to initialize a decoder` | ❌ `ERROR_CODE_DECODER_INIT_FAILED` |
  /// | `dtshd*` / `dtsx` | ❌ 缺解码器 | ⚠️ 部分机型可能支持（未核实） |
  /// | `dca`(DTS 核心) | ✅ | ✅ |
  /// | `ac3`/`eac3`/`aac` | ✅ | ✅ |
  ///
  /// ## 真机证据（《复仇者联盟》，2026-10-11）
  /// **mpv 侧**：
  /// ```
  /// [mpv/ad] Failed to initialize a decoder for codec 'truehd'.
  /// [mpv/cplayer] Audio: no audio
  /// ```
  /// **Media3 侧**（同一片源，同一编码）：
  /// ```
  /// CF-Media3: 播放错误: ERROR_CODE_DECODER_INIT_FAILED
  ///            MediaCodecAudioRenderer error, index=1,
  ///            format=Format(3, 国语, ..., truehd)
  /// ```
  /// ⇒ truehd 在**两个内核上都解不了**（Android 系统 MediaCodec 没有
  ///   truehd 解码器；我们的 libmpv 也没编）
  ///
  /// ## 为什么不硬编码"Media3 也不行"就完事
  /// 保留 [kernelMpv] 是为了将来：若换了带 truehd 的 libmpv，
  /// 只需改 mpv 侧的表（Media3 侧保持"拦 truehd"）。
  static bool isAudioCodecLikelyPlayable(
    String? codec, {
    bool kernelMpv = true,
  }) {
    if (codec == null || codec.isEmpty) return true; // 未知 → 允许
    final c = codec.toLowerCase().replaceAll('-', '').replaceAll('_', '');

    // ⓐ **两个内核都解不了**（Android 平台能力 + 自持 .so 均缺）
    //    truehd / mlp：MediaCodec 无此解码器；libmpv 也没编
    //
    // ## 真机证据（两个内核分别验证过，2026-10-11《复仇者联盟》）
    // mpv：`[mpv/ad] Failed to initialize a decoder for codec 'truehd'` → 无声
    // Media3：`ERROR_CODE_DECODER_INIT_FAILED`（format=truehd）
    //         → **整个播放停住**（不是静音继续）
    //   ⚠️ Media3 的失败是**致命**的：`AudioRenderer` 起不来 ⇒ 画面也黑
    const blockedBothKernels = {'truehd', 'mlp'};
    if (blockedBothKernels.contains(c)) return false;

    if (kernelMpv) {
      // ★ mpv **能解 DTS**：`ff_dca_decoder` 在符号表里，且真机
      //   `aid=3 dts` 时确实出声（«英语 · DTS · 7.1» 即 dca 所解）
      //   ⇒ 只有"扩展层"（MA/HRA/X）在部分构建里缺，保守拦掉
      const mpvBlocked = {'dtshd', 'dtshdma', 'dtshdhra', 'dtsx'};
      return !mpvBlocked.contains(c);
    }

    // ⓑ **Media3 额外解不了 DTS 系**（平台能力，与本项目构建无关）
    //
    // ## 为什么（Android 的真实限制）
    // DTS 是**授权编码**：厂商需单独付费才能内置解码器。
    // Google 官方支持的编码是 AAC/FLAC/MP3/Opus/Vorbis/PCM
    // + **AC3/EAC3**（Android 5.0 起系统自带杜比解码）。
    // ⇒ 小米这类机型**没有** DTS 解码器，Media3 直接初始化失败。
    //
    // ⚠️ 服务端对 DTS-HD MA 报的 `codec` 是 **`dts`**（不是 `dtshd`）
    //   —— 真机：`«English DTS-HD MA 7.1» codec=dts`
    //   ⇒ 必须拦 `dts`，否则会"退到另一条同样解不了的轨"（本轮实测踩到：
    //     truehd → dts → 仍 DECODER_INIT_FAILED）。
    const media3Blocked = {
      'dts', 'dtshd', 'dtshdma', 'dtshdhra', 'dtsx', 'dca',
    };
    return !media3Blocked.contains(c);
  }

  /// 从对齐后的音轨里挑一条**当前能播**的。
  ///
  /// ## 策略（优先保留用户/服务端的意图）
  /// 1. 首选 [preferred]（服务端默认轨）—— 但**必须编码可解**
  /// 2. 同语言的其他可解轨（保留"用户想听国语"的意图）
  /// 3. 任意可解轨
  /// 4. 全不可解 → 返回 null（**不设 aid**，让 mpv 自己挑 —— 
  ///    它至少会试，比我们硬设一条解不了的强）
  ///
  /// [codecOf] 取该轨对应的编码（来自服务端流，内核不保证有 codec）。
  static AlignedTrack? pickPlayableAudio(
    List<AlignedTrack> aligned, {
    AlignedTrack? preferred,
    required String? Function(AlignedTrack) codecOf,
    /// 当前内核是否为 mpv（**能力表按内核区分**，见
    /// [isAudioCodecLikelyPlayable] 的能力表与真机证据）。
    bool kernelMpv = true,
  }) {
    bool ok(AlignedTrack t) =>
        isAudioCodecLikelyPlayable(codecOf(t), kernelMpv: kernelMpv);

    // ① 首选不可解 → 先看同语言的
    if (preferred != null && ok(preferred)) return preferred;
    if (preferred != null) {
      final lang = preferred.language;
      if (lang != null && lang.isNotEmpty) {
        for (final t in aligned) {
          if (t.kernelId == preferred.kernelId) continue;
          if (t.language == lang && ok(t)) return t;
        }
      }
    }
    // ② 任意可解
    for (final t in aligned) {
      if (ok(t)) return t;
    }
    // ③ 全不可解
    return null;
  }

  /// **运行时已知"当前进程解不了"的编码**（由解码失败日志动态填充）。
  ///
  /// ## 为什么用"运行时侦测"而不是"静态硬编码"
  /// 我第一版把 `pgssub` 写死在黑名单里 —— 那是**错的**（用户两次指正）：
  /// · **mpv 上游支持 PGS**（全量 ffmpeg）；我们缺只是**当前这份 .so** 的问题
  /// · **Media3 有 `PgsParser`**（已核实 `media3-extractor-1.4.1.aar` 里有
  ///   `androidx.androidx.media3.extractor.text.pgs.PgsParser`）⇒ 它能显示
  /// ⇒ 硬编码会让"修好之后"仍然禁用该编码（**修好反而坏掉**）。
  ///
  /// ## 机制
  /// 内核报 `Could not find subtitle decoder` / `Failed to initialize a
  /// decoder` 时，把那个编码记进来（见 `NativeKernel` 的
  /// `_maybeSurfaceDecodeFailure`）⇒ 本次会话后续换轨时自动跳过它。
  /// **下次启动进程会重置** ⇒ 换了 .so 之后自然恢复。
  static final Set<String> runtimeUnsupportedSubtitleCodecs = <String>{};

  /// 记录一个"运行时证实解不了"的字幕编码（供 [isSubtitleCodecLikelyPlayable] 用）。
  ///
  /// ## 为什么要把**同义名一起记**（测试直接抓到的缺口）
  /// 同一个解码器在 ffmpeg 里有**多个名字**：
  /// | 名字 | 来源 | 例子 |
  /// |---|---|---|
  /// | `AVCodec.name` | 解码器注册名 | `pgssub` |
  /// | `AVCodecDescriptor.name` | 位流格式名 | `hdmv_pgs_subtitle` |
  /// | 短别名 | 部分实现用 | `pgs` |
  ///
  /// mpv 的报错用的是**第二种**（`Could not find subtitle decoder for
  /// format 'hdmv_pgs_subtitle'`），而服务端 `MediaStream.codec` 给的常是
  /// **第一种或第三种**（`pgssub` / `PGS`）。
  /// ⇒ 只记报错里那一个名字，就**拦不住**服务端给的另一个名字
  ///   （实测：`mark('pgssub')` 之后 `isPlayable('pgs')` 仍为 true）。
  static void markSubtitleCodecUnsupported(String? codec) {
    if (codec == null || codec.isEmpty) return;
    final n = _normCodec(codec);
    runtimeUnsupportedSubtitleCodecs.add(n);
    // ★ 同义名一起记（否则"报了 A 却按 B 判断"）
    for (final alias in _codecAliases[n] ?? const <String>[]) {
      runtimeUnsupportedSubtitleCodecs.add(alias);
    }
  }

  /// 编码名 → 同义名集合（**双向**：任一名字报错，其余都算不可用）。
  ///
  /// ## 为什么要双向
  /// 报错可能来自 `AVCodec.name`（`pgssub`）也可能来自
  /// `AVCodecDescriptor.name`（`hdmv_pgs_subtitle`）——
  /// 哪边报错都要拦住另一边。
  static const Map<String, List<String>> _codecAliases = {
    'pgssub': ['hdmvpgssubtitle', 'pgs'],
    'hdmvpgssubtitle': ['pgssub', 'pgs'],
    'pgs': ['pgssub', 'hdmvpgssubtitle'],
    // 图形字幕的其他变体
    'dvdsub': ['vobsub', 'dvdsubtitle'],
    'vobsub': ['dvdsub', 'dvdsubtitle'],
    'dvdsubtitle': ['dvdsub', 'vobsub'],
    'dvbsub': ['dvbsubtitle'],
    'dvbsubtitle': ['dvbsub'],
    // 文本字幕的常见别名（互为同义）
    'subrip': ['srt'],
    'srt': ['subrip'],
    'ass': ['ssa'],
    'ssa': ['ass'],
  };

  static String _normCodec(String codec) =>
      codec.toLowerCase().replaceAll('-', '').replaceAll('_', '');

  /// **字幕编码是否可解**（默认放行；只拦运行时已证实的）。
  ///
  /// ## 设计原则：**不猜**
  /// | 判据 | 是否可靠 | 为什么 |
  /// |---|---|---|
  /// | 符号名 `ff_<x>_decoder` | ✅ 可靠 | 实测：能工作的解码器符号都在（dca/ac3/hevc） |
  /// | 解码器"名字字符串" | ❌ 不可靠 | `ff_mlp_parser` 在 ⇒ 字符串 `mlp` 会出现，但那是**解析器** |
  /// | 硬编码黑名单 | ❌ 危险 | mpv 上游/Media3/MX 都支持 PGS ⇒ 修好 .so 后会被误禁 |
  /// | **运行时失败日志** | ✅✅ 最可靠 | 是**当前这个进程**的实测结论 |
  ///
  /// ⇒ 本函数用**最后一种**：只拦 [runtimeUnsupportedSubtitleCodecs] 里
  ///    已被真机日志证实的编码。
  ///
  /// [kernelMpv] 保留（两个内核能力不同：mpv 缺 PGS 解码器、
  /// Media3 有 `PgsParser`），但**不再据此硬编码** —— 由运行时结论决定。
  static bool isSubtitleCodecLikelyPlayable(
    String? codec, {
    bool kernelMpv = true,
  }) {
    if (codec == null || codec.isEmpty) return true;
    // ★ 只拦"运行时已证实解不了"的（默认放行，不猜）
    return !runtimeUnsupportedSubtitleCodecs.contains(_normCodec(codec));
  }

  /// 对齐字幕。[defaultIndex] = 服务端 `DefaultSubtitleStreamIndex`
  static List<AlignedTrack> alignSubtitle(
    List<MediaStream> server,
    List<FacadeSubtitleTrack> kernel, {
    int? defaultIndex,
  }) {
    final view = [
      for (final k in kernel)
        AlignedKernelTrack(
          id: k.id,
          ffIndex: k.ffIndex,
          title: k.title,
          language: k.language,
        ),
    ];
    return _align(
      server: server,
      count: kernel.length,
      kernelView: view,
      serverIndexAt: (i) => server[i].index,
      serverLabelAt: (i) {
        final kIdx = _kernelIndexFor(server, view, i);
        return server[i]
            .chineseLabel(kernelTitle: kIdx == null ? null : view[kIdx].title);
      },
      defaultIndex: defaultIndex,
      kernelFfIndexAt: (i) => kernel[i].ffIndex,
      kernelIdAt: (i) => kernel[i].id,
      // ★★ 字幕也必须带 language/codec（真机踩到的"配了没接线"）
      //
      // ## 为什么关键
      // `autoPickSubtitle` 靠 `isSubtitleCodecLikelyPlayable(codec)` 判断
      // "这条字幕能不能显示"。而 `AlignedTrack.codec` **只由
      // `serverCodecAt` 填充** —— 不传就恒为 null ⇒ 判断永远返回 true
      // ⇒ 仍然会选中 PGS ⇒ **"勾了却什么都不显示"**（真机二次报障）。
      serverLanguageAt: (i) => server[i].language,
      serverCodecAt: (i) => server[i].codec,
      fallbackLabelAt: (i) {
        final k = kernel[i];
        return _kernelLabel(
          title: k.title,
          language: k.language,
          extras: [
            if (k.isForced) '强制',
            if (k.isExternal) '外挂',
          ],
          fallback: '字幕 ${k.id}',
        );
      },
    );
  }

  /// **服务端没给默认字幕时，自动选一条中文轨**（用户报"字幕没有显示在画面中"）。
  ///
  /// ## 为什么需要（真机实测的根因）
  /// 《复仇者联盟》的 `DefaultSubtitleStreamIndex` 是 **null**
  /// ⇒ `_applyServerDefaultTracks` 直接跳过字幕 ⇒ **mpv 不选任何字幕**
  /// ⇒ 画面里没有任何字幕。
  ///
  /// 真机 mpv 日志（8 条字幕，**没有一条带 `(*)` 选中标记**）：
  /// ```
  /// Subs --sid=5 --slang=chi '简体中字' (hdmv_pgs_subtitle)
  /// ```
  ///
  /// ## ★★ 第二个坑：选了一条**永远显示不出来**的轨（真机二次报障）
  /// 修好"自动选"之后，用户仍报"字幕没有在播放画面中"。真机取证：
  /// ```
  /// srv.sub idx=2 «Chinese Simplified (默认 PGSSUB)»
  /// [PlayerFlow] 字幕：自动选中«简体中文» id=1     ← 选中的是 PGS
  /// [mpv/sub] Could not find subtitle decoder for format 'hdmv_pgs_subtitle'.
  /// ```
  /// ⇒ **中文优先**选到了 PGS 图形字幕，而我们的内核解不了 PGS
  ///   ⇒ "选中了但永远不显示"（比"没选中"更难查：UI 显示已勾选）。
  ///
  /// ## 选择策略（**先可播，再中文**）
  /// 1. **可播 + 中文 + 非 forced**
  /// 2. 可播 + 中文
  /// 3. 可播 + 非 forced
  /// 4. 可播（任意）
  /// 5. 全都不可播 → 返回 null（**不选**，让用户自己看到"没有可用字幕"
  ///    比"勾了一条却什么都不显示"更诚实）
  ///
  /// ⚠️ 与音频 `pickPlayableAudio` 同款思路：**能力优先于偏好**。
  ///    偏好（中文）只在"能播的集合"里起作用。
  static AlignedTrack? autoPickSubtitle(
    List<AlignedTrack> aligned, {
    String? Function(AlignedTrack)? codecOf,
  }) {
    if (aligned.isEmpty) return null;

    // ⚠️ 必须 `toLowerCase()`（label 里可能是 `CHS`/`Chi`/`ZHO` 等大小写混用）
    bool isChinese(AlignedTrack t) {
      final l = t.label.toLowerCase();
      return l.contains('中文') ||
          l.contains('简体') ||
          l.contains('繁体') ||
          l.contains('简英') ||
          l.contains('繁英') ||
          l.contains('中字') ||
          l.contains('国配') ||
          // 语言码/缩写（已小写）
          l.contains('chi') ||
          l.contains('zho') ||
          l.contains('chs') ||
          l.contains('cht') ||
          l.contains('zh');
    }

    // ★ 可播性：优先服务端 codec（更准），退化到轨道自带的 codec
    bool playable(AlignedTrack t) {
      final c = codecOf?.call(t) ?? t.codec;
      return isSubtitleCodecLikelyPlayable(c);
    }

    // ① 可播 + 中文 + 非 forced
    for (final t in aligned) {
      if (playable(t) && isChinese(t) && !t.isForced) return t;
    }
    // ② 可播 + 中文
    for (final t in aligned) {
      if (playable(t) && isChinese(t)) return t;
    }
    // ③ 可播 + 非 forced
    for (final t in aligned) {
      if (playable(t) && !t.isForced) return t;
    }
    // ④ 可播（任意）
    for (final t in aligned) {
      if (playable(t)) return t;
    }
    // ⑤ 全不可播 → 不选（**不勾选任何一条**，避免"勾了却不显示"）
    return null;
  }

  /// 服务端第 [si] 条流对应的**内核轨道下标**（按 `ffIndex == Index` 精确匹配）。
  ///
  /// 用于把内核的中文标题（如 `简英特字`）喂给服务端标签做本地化。
  /// 匹配不上返回 null（调用方退化为纯服务端标签）。
  static int? _kernelIndexFor(
    List<MediaStream> server,
    List<AlignedKernelTrack> kernel,
    int si,
  ) {
    final idx = server[si].index;
    if (idx == null) return null;
    for (var ki = 0; ki < kernel.length; ki++) {
      if (kernel[ki].ffIndex == idx) return ki;
    }
    return null;
  }

  /// 用内核信息拼标签（**语言名转中文** + **去掉编码后缀**）。
  ///
  /// ⚠️ 内核的 `codec` **不再拼进去** —— 用户要求去掉编码后缀
  ///（`英语 · TRUEHD · 7.1` → `英语 · 7.1`）。
  /// 编码对选轨决策没帮助，还挤占面板宽度。
  static String _kernelLabel({
    required String? title,
    required String? language,
    required List<String> extras,
    required String fallback,
  }) {
    final parts = <String>[];
    // 内核的 title 常已是中文（`国语`/`简英特字`）—— 优先
    if (title != null && title.trim().isNotEmpty) {
      parts.add(title.trim());
    } else {
      final zh = languageToChinese(language);
      if (zh != null) parts.add(zh);
    }
    parts.addAll(extras);
    if (parts.isEmpty) return fallback;
    return MediaStream.stripCodecSuffix(parts.join(' · '));
  }


  /// 通用对齐逻辑（音轨/字幕共用）。
  ///
  /// 传函数而不是泛型：音轨与字幕的**内核类型不同**且没有公共接口，
  /// 用 3 个访问器函数比引入泛型约束更直观。参数已压到最少。
  ///
  /// [kernelView] 是内核轨道的统一视图（`id`/`ffIndex`/`title`/`language`）
  /// —— 目前只用于**标签本地化**时反查内核的中文名（见 `_kernelIndexFor`）。
  static List<AlignedTrack> _align({
    required List<MediaStream> server,
    required int count,
    required int? Function(int) serverIndexAt,
    required String Function(int) serverLabelAt,
    required int? defaultIndex,
    required int? Function(int) kernelFfIndexAt,
    required String Function(int) kernelIdAt,
    required String Function(int) fallbackLabelAt,
    String? Function(int)? serverLanguageAt,
    String? Function(int)? serverCodecAt,
    List<AlignedKernelTrack> kernelView = const [],
  }) {
    final n = server.length;
    final used = List<bool>.filled(n, false);

    // ① 精确匹配：kernel.ffIndex == server.Index
    final labels = List<String?>.filled(count, null);
    final isDefault = List<bool>.filled(count, false);
    final precise = List<bool>.filled(count, false);
    // ★ 记录每条内核轨**匹配到的服务端流下标** —— 用于取 language/codec
    final matchedSi = List<int?>.filled(count, null);

    for (var ki = 0; ki < count; ki++) {
      final ff = kernelFfIndexAt(ki);
      if (ff == null) continue;
      for (var si = 0; si < n; si++) {
        if (used[si] || serverIndexAt(si) != ff) continue;
        labels[ki] = serverLabelAt(si);
        isDefault[ki] = defaultIndex != null && serverIndexAt(si) == defaultIndex;
        precise[ki] = true;
        matchedSi[ki] = si;
        used[si] = true;
        break;
      }
    }

    // ② 未匹配的，用剩下的服务端流按顺序补（启发式）
    var next = 0;
    for (var ki = 0; ki < count; ki++) {
      if (precise[ki]) continue;
      while (next < n && used[next]) {
        next++;
      }
      if (next >= n) break;
      labels[ki] = serverLabelAt(next);
      isDefault[ki] = defaultIndex != null && serverIndexAt(next) == defaultIndex;
      matchedSi[ki] = next;
      used[next] = true;
      next++;
    }

    // ③ 组装（仍无匹配 → 内核兜底）
    return [
      for (var ki = 0; ki < count; ki++)
        AlignedTrack(
          kernelId: kernelIdAt(ki),
          label: labels[ki] ?? fallbackLabelAt(ki),
          isDefault: isDefault[ki],
          matchedByIndex: precise[ki],
          // 服务端的语言/编码（用于"可解码性判断"与"同语言回退"）
          language: matchedSi[ki] == null
              ? null
              : serverLanguageAt?.call(matchedSi[ki]!),
          codec:
              matchedSi[ki] == null ? null : serverCodecAt?.call(matchedSi[ki]!),
          serverIndex:
              matchedSi[ki] == null ? null : serverIndexAt(matchedSi[ki]!),
        ),
    ];
  }
}
