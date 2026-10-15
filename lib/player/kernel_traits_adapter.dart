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
  /// ## 两个内核对 PGS 的能力（2026-10-15 **已更新**）
  /// | 内核 | PGS 支持 | 证据 |
  /// |---|---|---|
  /// | **Media3** | ✅ 有 | `media3-extractor-1.4.1.aar` 里确有 `PgsParser` |
  /// | **mpv（自持 .so）** | ✅ **有**（本轮已修）| 符号级实测 `ff_pgssub_decoder` **1** |
  ///
  /// ⚠️ **本条曾经是 `❌ 缺`** —— 那时 `.so` 是 `default` 白名单变体
  /// （150 个解码器，无 pgssub），真机报
  /// `Could not find subtitle decoder for format 'hdmv_pgs_subtitle'`。
  ///
  /// **2026-10-15 换成 `full` 变体**（`media-kit/libmpv-android-video-build`
  /// v1.1.11 `full-arm64-v8a.jar`）：
  /// ```
  /// 旧 default：150 个解码器  ff_pgssub_decoder ❌ 0（含 truehd/mlp/mov_text 也缺）
  /// 新 full   ：513 个解码器  ff_pgssub_decoder ✅ 1
  /// tool/check_mpv_decoders.py → 18/18 通过
  /// ```
  ///
  /// ## 连带改动（**必须一起看**）
  /// `kernel_auto_select.dart` 里原有一条**最高优先级**规则
  /// "有 PGS ⇒ 强制走 Media3"，**依据就是"mpv 缺这个解码器"**。
  /// 该前提已不成立 ⇒ **规则已删除**（它自己的注释就写明了删除条件）。
  ///
  /// ⚠️ 否则后果是：PGS 片源被强制降级到 Media3
  /// ⇒ 丢掉 mpv 的 HDR 色调映射 + 4 项独有能力（滤镜/延迟/运行中切硬解）。
  ///
  /// ## 字段为什么**保留**（不删）
  /// 它是"**mpv 是否有 PGS 能力**"这个前提的**数据载体**：
  /// 若将来 `.so` 又被换回裁剪版（`check_mpv_decoders.py` 会报红），
  /// 应把这**按原样恢复** ⇒ 前提信息还在，不必重做数据管道。
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
