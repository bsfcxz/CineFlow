/// 播放内核工厂 —— 双内核的**唯一选择点**。
///
/// ## 为什么需要工厂（而不是让 UI `if/else`）
/// 规格 §12 要求"播放引擎通过抽象接口对接，UI 层不直接依赖具体实现"。
/// 若 UI 里写 `if (useMedia3) Media3Kernel() else NativeKernel()`，
/// 那 UI 就**知道了两个具体类** —— 抽象形同虚设，且新增第三个内核
/// （如 `fvp`）要改 UI。
///
/// 工厂把"选哪个"收敛到一个地方：
/// ```dart
/// final kernel = PlayerKernelFactory.create(KernelType.auto);
/// ```
///
/// ## `auto` 的选取策略（**不是**"哪个新用哪个"）
/// | 场景 | 选谁 | 理由 |
/// |---|---|---|
/// | 默认 | **mpv** | 格式支持最全（滤镜/延迟/任意容器），是主力内核 |
/// | 用户手动切换 | Media3 | 需要与系统媒体会话集成时 |
///
/// **默认必须是 mpv**：本项目的主力是"播放用户自己的各种片源"，
/// 而 Media3 对冷门编码/容器的支持明显弱于 mpv（它依赖系统 MediaCodec 解码器，
/// 设备没有对应解码器就播不了）。Media3 的价值在系统集成，
/// 而不是"更好的默认选择"。
library;

import 'kernel.dart';
import 'media3/media3_kernel.dart';
import 'native/native_kernel.dart';

/// 内核类型。
enum KernelType {
  /// 自动选择（当前 = mpv，见文件头说明）。
  auto('自动'),

  /// 原生 mpv（自持 libmpv.so）—— 主力内核。
  mpv('mpv 内核'),

  /// androidx.media3 / ExoPlayer —— 系统集成内核。
  media3('Media3 内核');

  const KernelType(this.label);
  final String label;
}

/// 内核工厂。
abstract final class PlayerKernelFactory {
  /// 创建内核实例。
  ///
  /// ⚠️ 每次调用返回**新实例**（内核持有原生资源与 StreamController，
  /// 共享实例会导致 dispose 相互踩踏）。调用方负责 `dispose()`。
  static PlayerKernel create([KernelType type = KernelType.auto]) {
    return switch (type) {
      KernelType.media3 => Media3Kernel(),
      // auto 与显式 mpv 都走 mpv（见文件头"默认必须是 mpv"）
      KernelType.auto || KernelType.mpv => NativeKernel(),
    };
  }

  /// `auto` 会选到哪个（供 UI 显示"当前内核"）。
  static KernelType get autoResolvesTo => KernelType.mpv;

  /// 某个内核类型是否**在能力上**适合当前媒体。
  ///
  /// 本方法目前只做静态判断（基于容器/编码的已知短板）。
  /// 真正的"播不了就回退"需要运行时报错后重试 —— 那是更高的复杂度，
  /// 暂不实现（诚实记录为未完成项，见 `docs/local/PLAYER-UI-REBUILD.md`）。
  static bool canHandle(
    KernelType type, {
    required String path,
  }) {
    final ext = path.contains('.')
        ? path.split('.').last.toLowerCase()
        : '';
    return switch (type) {
      // mpv 几乎通吃
      KernelType.auto || KernelType.mpv => true,
      // Media3 依赖系统解码器：对冷门容器/编码（RMVB/WMV/部分 ASS 特效）
      // 支持有限。这里列出**已知需要 mpv** 的扩展名。
      KernelType.media3 => !_mpvOnlyExtensions.contains(ext),
    };
  }

  /// 只有 mpv 能可靠处理的扩展名（基于本项目实测与 mpv 的格式覆盖）。
  ///
  /// ⚠️ 这份清单是**保守估计**：Android 各版本自带的解码器不同，
  /// 同一个文件在某些设备上 Media3 能播、另一些上不能。
  /// 故只列出"几乎确定 Media3 不行"的。
  static const Set<String> _mpvOnlyExtensions = {
    'rmvb', 'rm', // RealMedia：Android 从不支持
    'wmv', 'asf', // Windows Media：多数设备无解码器
    'flv', // 部分设备无
    'vob', // DVD
    'ts', 'm2ts', // 依赖具体编码，Media3 支持不稳
    'ape', 'wv', // 冷门无损音频
  };
}
