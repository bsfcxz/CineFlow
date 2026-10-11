/// 从 `PlaybackLaunch` 提取 [MediaTraits] —— **自动适配的输入适配层**。
///
/// ## 为什么单独一层（而不是让自动选择器直接读 PlaybackLaunch）
/// `KernelAutoSelect` 是**纯函数模块**，只认 `MediaTraits`（中立特征）。
/// 若它直接依赖 `PlaybackLaunch`（含 Emby 字段、headers、playSessionId…），
/// 就绑死在 Emby 上了 —— 将来接 115 网盘/本地文件时无法复用。
///
/// 本文件是**唯一**知道"PlaybackLaunch 长什么样"的地方，
/// 换成别的源只需再加一个提取函数。
///
/// ## 提取时的取值优先级（都写清理由）
/// · **容器**：优先 `container` 字段（服务端声明），
///   没有则从 URL 后缀推断 —— 服务端不一定给 container，
///   但 URL 通常有后缀（`?api_key=...` 在前，故必须先去查询串）。
/// · **分辨率**：从 `streams` 里找 `Type == 'Video'` 的那条取 height。
///   服务端 `PlaybackLaunch` 本身**没有**顶层宽高字段，只能从流里取。
/// · **视频编码**：同上，取 Video 流的 codec。
/// · **外挂字幕**：判据是"**存在 `IsExternal` 的字幕流**"。
///   ⚠️ 不是"有字幕流" —— 内嵌字幕（PGS/mov_text）mpv 与 Media3 都支持，
///   只有外挂字幕才体现 mpv 的优势（编码/字体/特效）。
library;

import '../data/media_provider.dart';
import 'kernel_auto_select.dart';

/// 从一次播放会话提取特征。
///
/// ⚠️ 所有字段都尽量取，但**取不到就是 null/false** ——
/// 绝不用猜测值填充（那会让决策看起来比实际更可靠）。
MediaTraits traitsFromLaunch(PlaybackLaunch launch) {
  // ---- URL 归属：转码流也是 HLS，两者都算 ----
  final url = launch.url;
  final lowerUrl = url.toLowerCase();
  final isTranscoding = launch.transcodingUrl != null &&
      url == launch.transcodingUrl;
  final isHls = lowerUrl.contains('.m3u8') || isTranscoding;

  // ---- 从流列表里取视频信息 ----
  int? videoHeight;
  int? videoWidth;
  String? videoCodec;
  String? audioCodec;
  var hasExternalSubtitle = false;

  /// ★★ 是否有 **PGS 图形字幕**（真机报障："字幕还是没有显示出在画面中"）。
  ///
  /// ## 为什么这个字段决定内核选择
  /// 两个内核对 PGS 的能力**不同**（都已核实）：
  /// | 内核 | PGS 支持 | 证据 |
  /// |---|---|---|
  /// | **Media3** | ✅ 有 | `media3-extractor-1.4.1.aar` 里确有<br>`androidx.media3.extractor.text.pgs.PgsParser` |
  /// | **mpv（自持 .so）** | ❌ 缺 | 真机：`Could not find subtitle decoder for format 'hdmv_pgs_subtitle'`；<br>且符号表里**没有** `ff_pgssub_decoder` |
  ///
  /// ## 修法（不是"改 UI"，是**把这类片源路由给能显示的内核**）
  /// 原规则 R4 把"有外挂字幕"判给 mpv —— 但**内嵌 PGS** 走的是
  /// 规则 R5 默认（也是 mpv）⇒ PGS 片源**一律落到缺解码器的 mpv 上**
  /// ⇒ "别的播放器能显示、我们显示不出来"。
  /// ⇒ 新增规则：**有 PGS 字幕 ⇒ 优先 Media3**。
  ///
  /// ⚠️ 若将来换掉 `libmpv.so`（补上 pgssub），这条规则应删除或放宽
  ///   （见 `tool/check_mpv_decoders.py` 的自检输出）。
  var hasPgsSubtitle = false;

  /// 视频动态范围（SDR / HDR10 / DOVI…）。
  ///
  /// ★ 借鉴 LinPlayer 的"HDR / 杜比视界自动切软解"思路（**仅取思路，未抄代码** ——
  ///   该仓库是 AGPL-3.0）。原理见 `MediaTraits.videoRange` 的说明。
  String? videoRange;

  for (final s in launch.streams) {
    switch (s.type) {
      case 'Video':
        // 取第一条视频流即可（多视频流极罕见，且分辨率通常一致）
        videoHeight ??= s.height;
        videoWidth ??= s.width;
        videoCodec ??= s.codec;
        // 数据层**早就解析了** `MediaStream.videoRange`（models.dart:538），
        // 但此前**从未进入内核决策** —— 这条线是断的，现在接上。
        videoRange ??= s.videoRange;
      case 'Audio':
        audioCodec ??= s.codec;
      case 'Subtitle':
        if (s.isExternal) hasExternalSubtitle = true;
        // PGS 的编码名在服务端可能是 `pgssub`/`PGS`/`hdmv_pgs_subtitle`
        final c = (s.codec ?? '').toLowerCase().replaceAll('-', '');
        if (c.contains('pgs')) hasPgsSubtitle = true;
    }
  }

  return MediaTraits(
    path: url,
    container: launch.container,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    width: videoWidth,
    height: videoHeight,
    bitrate: launch.bitrate,
    isHls: isHls,
    isTranscoding: isTranscoding,
    hasExternalSubtitle: hasExternalSubtitle,
    hasPgsSubtitle: hasPgsSubtitle,
    videoRange: videoRange,
  );
}
