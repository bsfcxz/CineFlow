/// 视频层：内核纹理 + 画幅模式（五档）。
///
/// 由 [VideoState.aspectMode]（videoStateProvider）驱动，播放页与
/// 调试试验台共用 —— 两处必须看到完全一致的画幅行为。
///
/// ⚠️ Texture 没有固有尺寸（TextureBox 布局时取无限大）——
///    绝不能直接塞进 FittedBox（渲染期崩溃，单测抓过）。
///    一律用显式尺寸的子树（AspectRatio / SizedBox）提供边界。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/player_constants.dart';
import '../../application/providers/player_providers.dart';

class AspectVideo extends ConsumerWidget {
  const AspectVideo({super.key, required this.textureId, required this.videoRatio});

  final int textureId;

  /// 内核解析出的视频宽高比（未知 → 16:9）。
  final double videoRatio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final aspect = ref.watch(videoStateProvider.select((s) => s.aspectMode));
    final texture = Texture(textureId: textureId);

    return switch (aspect) {
      // 适应（默认）：视频完整可见，黑边留白
      AspectMode.contain => Center(
          child: AspectRatio(aspectRatio: videoRatio, child: texture),
        ),
      // 拉伸：铺满整个图层（宽高比忽略）
      AspectMode.fill => SizedBox.expand(child: texture),
      // 裁剪：短边对齐铺满，超出部分裁掉
      AspectMode.cover => LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          final videoW = w / videoRatio >= h ? w : h * videoRatio;
          return ClipRect(
            child: Center(
              child: SizedBox(
                width: videoW,
                height: videoW / videoRatio,
                child: texture,
              ),
            ),
          );
        }),
      // 固定比例：忽略片源比例，按指定比例显示
      AspectMode.ratio16x9 => Center(
          child: AspectRatio(aspectRatio: 16 / 9, child: texture),
        ),
      AspectMode.ratio4x3 => Center(
          child: AspectRatio(aspectRatio: 4 / 3, child: texture),
        ),
    };
  }
}
