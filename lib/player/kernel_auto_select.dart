/// **内核自动适配** —— 根据媒体特征决定用哪个播放内核。
///
/// ## 为什么需要它（而不是"默认 mpv 就完了"）
/// 两个内核的能力不同，**各有各的失败场景**：
///
/// | 场景 | mpv | Media3 | 说明 |
/// |---|---|---|---|
/// | 几乎任意容器/编码 | ✅ | ⚠️ | Media3 依赖系统 MediaCodec，冷门编码设备没有解码器就播不了 |
/// | 画面滤镜 / 音视频延迟 | ✅ | ❌ | Media3 无等价能力（见 `Media3Kernel.supports`） |
/// | 与系统媒体会话集成 | ❌ | ✅ | 通知栏/蓝牙键/音频焦点（Media3 是 Android 官方栈） |
/// | 4K / HEVC 高码率 | ⚠️ | ✅ | Media3 更会用系统硬解通路，能效更好 |
/// | 转码流（HLS） | ⚠️ | ✅ | Media3 对 HLS 的支持更成熟 |
///
/// 所以"永远用 mpv"会在 **HLS/转码流**上吃亏，
/// "永远用 Media3"会在 **RMVB/冷门编码**上直接播不了。
///
/// ## 设计原则
/// 1. **保守优先**：拿不准就选 mpv（它是格式覆盖最广的那个，
///    选错的代价是"能播但不够省电"，而选 Media3 选错的代价是"播不了"）
/// 2. **纯函数**：决策不依赖网络/设备探测，只根据"已知的媒体特征"判断
///    → 可单测、可解释（用户能在「我的」里看到"为什么选它"）
/// 3. **用户可覆盖**：自动只是默认值，用户能强制指定（见 `KernelPreference`）
///
/// ## ⚠️ 诚实说明局限
/// 这里的判断基于**文件名后缀 + 服务端元数据**，**不是真正探测解码能力**。
/// 真探测需要 `MediaCodecList` 查询 + 试播回退，那是更大的工程。
/// 故本模块的定位是"**合理的默认值**"，不是"保证播得了"。
library;

import '../player/kernel_factory.dart';

/// 偏好存储键（`secure_storage`）。
///
/// ## 为什么定义在 player 层而不是 pages 层
/// 读写它的有两处：**播放器**（起播时读）与**设置页**（用户改）。
/// 播放器是低层，不能反向 import 页面 —— 故键定义放这里，
/// 设置页引用它（上层依赖下层是正确方向）。
const String kKernelPrefKey = 'player_kernel';

/// 用户在设置里选的偏好。
enum KernelPreference {
  /// 自动适配（按 [KernelAutoSelect.select] 的规则挑）。
  auto('自动（推荐）', '根据片源自动选择最合适的内核'),

  /// 强制 mpv。
  mpv('mpv 内核', '格式覆盖最全；支持画面滤镜与音视频延迟'),

  /// 强制 Media3。
  media3('Media3 内核', 'Android 官方栈；对 HLS/转码流与系统媒体会话支持更好');

  const KernelPreference(this.label, this.description);

  final String label;
  final String description;

  /// 偏好是否确实指定了内核（`auto` 表示没指定）。
  bool get isExplicit => this != KernelPreference.auto;

  /// 存进 `secure_storage` 的值（`auto` 存空串以便清除）。
  String get storageValue => this == KernelPreference.auto ? '' : name;

  /// 从存储值解析（非法/空一律回退 `auto`）。
  static KernelPreference fromStorage(String? raw) {
    if (raw == null || raw.isEmpty) return KernelPreference.auto;
    for (final p in KernelPreference.values) {
      if (p.name == raw) return p;
    }
    return KernelPreference.auto;
  }

  /// 转成内核工厂的类型。
  KernelType get kernelType => switch (this) {
        KernelPreference.auto => KernelType.auto,
        KernelPreference.mpv => KernelType.mpv,
        KernelPreference.media3 => KernelType.media3,
      };
}

/// 决策用到的媒体特征（由调用方从 Emby 元数据/文件名填充）。
///
/// ⚠️ 全部字段都**可为空** —— 服务端不一定给全。
/// 缺字段时决策必须走"保守分支"（选 mpv），不能瞎猜。
class MediaTraits {
  const MediaTraits({
    this.path,
    this.container,
    this.videoCodec,
    this.audioCodec,
    this.width,
    this.height,
    this.bitrate,
    this.isHls = false,
    this.isTranscoding = false,
    this.hasExternalSubtitle = false,
  });

  /// 文件名或 URL（用于取扩展名）。
  final String? path;

  /// 容器（`mkv` / `mp4` / `ts` …），优先于扩展名。
  final String? container;

  final String? videoCodec;
  final String? audioCodec;
  final int? width;
  final int? height;

  /// 码率（bps）。
  final int? bitrate;

  /// 是否是 HLS/m3u8 流（转码流也是 HLS）。
  final bool isHls;

  /// 是否是服务端转码流。
  final bool isTranscoding;

  /// 是否有外挂字幕（mpv 对字幕编码/字体的支持更好）。
  final bool hasExternalSubtitle;

  /// 分辨率高度（取不到返回 null）。
  int? get shortSide {
    final w = width;
    final h = height;
    if (w == null || h == null) return null;
    return w < h ? w : h;
  }

  /// 扩展名（小写，不含点）。
  String get extension {
    final p = path;
    if (p == null || p.isEmpty) return '';
    // 去掉查询串（URL 常带 ?token=...）
    final clean = p.split('?').first.split('#').first;
    final i = clean.lastIndexOf('.');
    if (i < 0 || i == clean.length - 1) return '';
    return clean.substring(i + 1).toLowerCase();
  }

  /// 归一化后的容器名（优先显式 container，否则用扩展名）。
  String get effectiveContainer {
    final c = container;
    if (c != null && c.isNotEmpty) return c.toLowerCase();
    return extension;
  }

  /// 是否是 HLS（m3u8）。
  ///
  /// ## 为什么不能只看 `isHls` 标志（实测抓到的缺口）
  /// 写测试时发现：`MediaTraits(path: 'http://s/a.m3u8')`（没传 `isHls`）
  /// 会落到"保守默认 mpv"，**丢掉 Media3 在 HLS 分片续播上的优势**。
  ///
  /// 根因：`isHls` 是**调用方自己判断后传进来的**，任何一处漏判就失效。
  /// 而 URL 后缀是**数据本身就有的事实**，不该依赖调用方传对标志。
  ///
  /// 故这里同时看三处：显式标志 / 转码标志 / URL 与容器后缀。
  bool get isHlsStream =>
      isHls ||
      isTranscoding ||
      effectiveContainer == 'm3u8' ||
      (path?.toLowerCase().contains('.m3u8') ?? false);

  @override
  String toString() => 'MediaTraits(container: $effectiveContainer, '
      'v: $videoCodec, a: $audioCodec, ${width}x$height, '
      'hls: $isHls, transcode: $isTranscoding)';
}

/// 一次决策的结果（**含理由**，便于向用户解释）。
class KernelDecision {
  const KernelDecision({
    required this.kernel,
    required this.reason,
    this.confidence = KernelConfidence.high,
  });

  final KernelType kernel;

  /// 人类可读的理由（会显示在「我的 → 播放内核」里）。
  final String reason;

  /// 这个决定的可靠程度。
  final KernelConfidence confidence;

  @override
  String toString() => '${kernel.name}（$reason）';
}

/// 决策可靠度。
enum KernelConfidence {
  /// 有明确依据（如 HLS → Media3）。
  high,

  /// 依据不足，走了保守分支（如元数据缺失 → mpv）。
  low;

  String get label => this == KernelConfidence.high ? '明确' : '保守';
}

/// 内核自动选择器（纯函数，无状态）。
abstract final class KernelAutoSelect {
  /// 决策主入口。
  ///
  /// [preference] 非 `auto` 时**直接采纳用户选择**（不给自动逻辑留余地）——
  /// 用户显式指定了就不该被"聪明"覆盖。
  static KernelDecision select(
    MediaTraits traits, {
    KernelPreference preference = KernelPreference.auto,
  }) {
    if (preference.isExplicit) {
      return KernelDecision(
        kernel: preference.kernelType,
        reason: '你在设置里指定了「${preference.label}」',
        confidence: KernelConfidence.high,
      );
    }
    return _selectAuto(traits);
  }

  /// 自动规则的实现。
  ///
  /// ## 规则顺序（**顺序即优先级**，改顺序会改变行为）
  ///
  /// 1. **HLS / 转码流 → Media3**
  ///    理由：Media3 对 HLS 的分片续播、码率切换支持更成熟。
  ///    这是**收益最明确**的一条（也是引入 Media3 的主要价值）。
  ///    ⚠️ 但若同时是"冷门视频编码"，仍按第 2 条优先（播放优先于体验）。
  ///
  /// 2. **mpv 独占格式 → mpv**
  ///    （RMVB/WMV/ASF/VOB 等，系统解码器通常没有）
  ///    → 播得了 > 一切
  ///
  /// 3. **高码率 4K/HEVC → Media3**
  ///    理由：Media3 走系统硬解通路，能效与稳定性更好。
  ///
  /// 4. **有外挂字幕 → mpv**
  ///    理由：mpv 对字幕编码（GBK/BIG5）、ASS 特效、字体回退支持更好。
  ///    本项目实测过 mpv 能识别 `mov_text` 与编码选择，Media3 无此能力。
  ///
  /// 5. **其余 → mpv**（保守：格式覆盖最全）
  static KernelDecision _selectAuto(MediaTraits t) {
    // ---- 规则 2 前置：冷门格式一律 mpv（播放优先于一切）----
    if (isMpvOnlyContainer(t.effectiveContainer)) {
      return KernelDecision(
        kernel: KernelType.mpv,
        reason: '${t.effectiveContainer.toUpperCase()} 格式系统解码器通常不支持，'
            'mpv 才能放',
      );
    }

    // ---- 规则 1：HLS / 转码流 ----
    if (t.isHlsStream) {
      return KernelDecision(
        kernel: KernelType.media3,
        reason: t.isTranscoding ? '服务端转码流（HLS）' : 'HLS 流',
        confidence: KernelConfidence.high,
      );
    }

    // ---- 规则 3：高码率 4K / HEVC ----
    final h = t.shortSide;
    if (h != null && h >= 2000) {
      return KernelDecision(
        kernel: KernelType.media3,
        reason: '${h}p 高分辨率，用系统硬解通路能效更好',
      );
    }

    // ---- 规则 4：外挂字幕 ----
    if (t.hasExternalSubtitle) {
      return KernelDecision(
        kernel: KernelType.mpv,
        reason: '有外挂字幕，mpv 对字幕编码与特效支持更好',
      );
    }

    // ---- 规则 5：保守默认 ----
    // 元数据全缺时 confidence=low，让 UI 如实显示"保守选择"
    final known = t.effectiveContainer.isNotEmpty ||
        t.videoCodec != null ||
        t.height != null;
    return KernelDecision(
      kernel: KernelType.mpv,
      reason: known ? '常规片源，mpv 格式覆盖最全' : '片源信息不足，保守选 mpv',
      confidence: known ? KernelConfidence.high : KernelConfidence.low,
    );
  }

  /// 只有 mpv 能可靠处理的容器。
  ///
  /// ⚠️ 这份清单来自 `PlayerKernelFactory._mpvOnlyExtensions`，
  /// **单一事实源**在这里，工厂那边的方法也读它（避免两处清单漂移）。
  static bool isMpvOnlyContainer(String container) =>
      mpvOnlyContainers.contains(container.toLowerCase());

  /// 只有 mpv 可靠的容器集合（保守估计：只列"几乎确定 Media3 不行"的）。
  ///
  /// 为什么不列全：Android 各版本自带解码器不同，同一文件在 A 机能播、
  /// B 机不能。故只列**确定**的，其余交给保守默认（也是 mpv）。
  static const Set<String> mpvOnlyContainers = {
    'rmvb', 'rm', // RealMedia：Android 从不支持
    'wmv', 'asf', // Windows Media：多数设备无解码器
    'flv',
    'vob', // DVD
    'ape', 'wv', // 冷门无损音频
    'm2ts', 'ts', // 依赖具体编码，Media3 支持不稳
  };
}
