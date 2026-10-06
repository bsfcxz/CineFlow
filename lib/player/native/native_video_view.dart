/// 原生 mpv 的视频输出层（Flutter 纹理）。
///
/// 为什么是纹理而不是 PlatformView：
///   - `Texture` 是普通 Flutter 图层，弹幕 `CustomPainter`、手势
///     `GestureDetector`、控制层都能直接叠在上面，**不存在 PlatformView
///     的手势仲裁问题**（那正是原方案 PLAYER-KERNEL.md §4 点名的头号风险）；
///   - 不需要我们自己写 EGL / 管理 GL 线程（mpv 用 `gpu-context=android`
///     自己建上下文，与 mpv-android、media_kit_video 一致）。
///
/// 宽高比：mpv 会回传 `width`/`height`（见 native_kernel 的属性观察），
/// 拿到之前按 16:9 兜底，避免首帧抖动。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'native_kernel.dart';

class NativeVideoView extends StatelessWidget {
  const NativeVideoView({
    super.key,
    required this.kernel,
    this.fit = BoxFit.contain,
    this.tick = 0,
  });

  final NativeKernel kernel;

  /// 与 media_kit `Video(fit:)` 对齐：contain / cover / fillWidth…
  final BoxFit fit;

  /// 尺寸变化时由外部 `setState` 递增，触发重建（本组件无状态）
  final int tick;

  @override
  Widget build(BuildContext context) {
    final id = kernel.textureId;
    if (!Platform.isAndroid || id == null) {
      // 纹理尚未就绪（或非安卓平台）：纯黑底，避免白闪
      return const ColoredBox(color: Color(0xFF000000));
    }

    final ar = kernel.aspectRatio ?? (16 / 9);
    // 用 AspectRatio + FittedBox 复刻 media_kit 的 fit 语义：
    // 纹理按视频原始比例，外层再按 fit 决定缩放/裁切方式。
    return ClipRect(
      child: FittedBox(
        fit: fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: ar * 1000,
          height: 1000,
          child: Texture(
            key: ValueKey('mpv-tex-$id-$tick'),
            textureId: id,
            filterQuality: FilterQuality.low,
          ),
        ),
      ),
    );
  }
}
