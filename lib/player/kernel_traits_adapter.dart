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

  for (final s in launch.streams) {
    switch (s.type) {
      case 'Video':
        // 取第一条视频流即可（多视频流极罕见，且分辨率通常一致）
        videoHeight ??= s.height;
        videoWidth ??= s.width;
        videoCodec ??= s.codec;
      case 'Audio':
        audioCodec ??= s.codec;
      case 'Subtitle':
        if (s.isExternal) hasExternalSubtitle = true;
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
  );
}
