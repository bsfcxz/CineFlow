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

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'kernel.dart';
import 'kernel_auto_select.dart';
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
  /// 测试注入点：非 null 时替代默认构造。
  ///
  /// 仅 widget 测试使用（生产代码**不得**设置）—— 离线测试无法建
  /// 原生纹理/通道，需要塞入 FakeKernel 验证接线层逻辑。
  @visibleForTesting
  static PlayerKernel Function()? debugFactory;

  /// 创建内核实例。
  ///
  /// ⚠️ 每次调用返回**新实例**（内核持有原生资源与 StreamController，
  /// 共享实例会导致 dispose 相互踩踏）。调用方负责 `dispose()`。
  static PlayerKernel create([KernelType type = KernelType.auto]) {
    if (debugFactory != null) return debugFactory!();
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
  /// ⚠️ 已**委托**给 `KernelAutoSelect`（单一事实源）。
  /// 原先这里有一份独立的扩展名清单，与自动选择逻辑重复 ——
  /// 两处各改一半必然漂移，故收敛到一处。
  static bool canHandle(KernelType type, {required String path}) {
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    return switch (type) {
      // mpv 几乎通吃
      KernelType.auto || KernelType.mpv => true,
      // Media3 依赖系统解码器：冷门容器不支持
      KernelType.media3 => !KernelAutoSelect.isMpvOnlyContainer(ext),
    };
  }

}
