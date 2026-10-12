/// **骨架屏**（热播 TMDB 栏加载中占位）。
///
/// ## 为什么需要（实测）
/// TMDB 热播首次要发 **12 个请求**（4 类 × 3 页），实测约 **12 秒**。
/// 那期间如果只显示一个转圈：
/// · 用户不知道"在加载"还是"卡死了"
/// · 也不知道**加载完会是什么样**（几列、什么形状）
///
/// ⇒ 骨架屏用**和真实内容同样的布局**（3 列海报 + 标题行），
///    让等待期也有信息量（这是"感知性能"的常规做法）。
///
/// ## 微光动画
/// 稿子的 `.skeleton` 是静态灰块；这里加一个**左右扫过的高光**
/// （`AnimationController` 驱动 `LinearGradient` 位移）——
/// 静态灰块容易被误认成"图挂了"，动起来才明确是"在加载"。
library;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 热播网格的骨架屏（3 列 × [rows] 行）。
class HotSkeleton extends StatefulWidget {
  const HotSkeleton({super.key, this.rows = 3});

  final int rows;

  @override
  State<HotSkeleton> createState() => _HotSkeletonState();
}

class _HotSkeletonState extends State<HotSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: widget.rows * 3,
      // ⚠️ 列数/比例必须与真实网格**一致**（否则加载完成时会"跳一下"）
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.55,
      ),
      itemBuilder: (_, i) => _Card(anim: _c),
    );
  }
}

/// 单张骨架卡（海报块 + 两行文字块），带扫光。
class _Card extends StatelessWidget {
  const _Card({required this.anim});

  final Animation<double> anim;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _Shimmer(anim: anim, radius: Cf.radiusMd)),
        const SizedBox(height: 6),
        // 标题占位（两行里第一行）
        _Shimmer(anim: anim, height: 10, radius: Cf.radiusXs, widthFactor: 0.9),
        const SizedBox(height: 5),
        // 第二行（评分/年份）
        _Shimmer(anim: anim, height: 8, radius: Cf.radiusXs, widthFactor: 0.5),
      ],
    );
  }
}

/// 扫光块：底色 `surface2` + 一道从左到右的高光。
class _Shimmer extends StatelessWidget {
  const _Shimmer({
    required this.anim,
    this.height,
    this.radius = Cf.radiusSm,
    this.widthFactor = 1.0,
  });

  final Animation<double> anim;
  final double? height;
  final double radius;
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (_, __) {
        // -1 → 2 让高光完整扫过（含进出边缘）
        final t = anim.value * 3 - 1;
        return FractionallySizedBox(
          widthFactor: widthFactor,
          alignment: Alignment.centerLeft,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: Cf.surface2,
              borderRadius: BorderRadius.circular(radius),
              gradient: LinearGradient(
                begin: Alignment(t - 0.6, 0),
                end: Alignment(t + 0.6, 0),
                colors: [
                  Cf.surface2,
                  Cf.surface3,
                  Cf.surface2,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        );
      },
    );
  }
}
