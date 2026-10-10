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

    // ★ auto 档（用户 2026-10-09："横屏 16:9 / 竖屏 9:16"）
    //
    // ## 为什么在 widget 里解析而不是写进 provider
    // 方向是**窗口属性**，随旋转实时变；写进 provider 会引入
    // "方向变化要通知 provider"的额外链路。widget 里每次 build
    // 直接读 `MediaQuery`，天然跟随旋转，无需任何事件。
    //
    // ## ⚠️ 必须把**片源比例**一起给判定（第一版翻车的教训）
    // 只按屏幕方向强制比例 ⇒ 竖屏看 16:9 电影被硬塞进 9:16（变形）。
    // 正确语义见 `resolveAuto` 注释：方向一致才满屏，否则回 contain。
    final effective = aspect == AspectMode.auto
        ? AspectMode.resolveAuto(
            width: MediaQuery.sizeOf(context).width,
            height: MediaQuery.sizeOf(context).height,
            videoRatio: videoRatio,
          )
        : aspect;

    return switch (effective) {
      // 适应：视频完整可见，黑边留白（**唯一档位**，见 AspectMode 的说明）
      AspectMode.contain => Center(
          child: AspectRatio(aspectRatio: videoRatio, child: texture),
        ),
      // auto 已在上面解析成 contain，逻辑上不会再走到这里；
      // 保留分支以穷尽枚举（编译器要求），落到 contain 兜底。
      AspectMode.auto => Center(
          child: AspectRatio(aspectRatio: videoRatio, child: texture),
        ),
    };
  }
}
