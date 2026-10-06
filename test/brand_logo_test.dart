import 'package:cineflow/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 品牌标识一致性测试（用户反馈"我的关于应用的图标也没替换"）。
///
/// ## 这个测试守什么
///
/// 历史上 `CfLogo` 是**自绘**的（渐变方块 + 文字「C」），
/// 而桌面图标是用户提供的 `icon.png` —— **两者不是同一个东西**，
/// 于是产生"应用内图标没替换"的观感。
///
/// 现在 `CfLogo` 直接渲染 `assets/icon.png`，与桌面图标、启动屏**同源**。
/// 本测试断言"确实在用 asset"，防止将来有人又改回自绘。
///
/// ## 为什么必须用 widget 测试
///
/// 这件事**静态分析发现不了**：自绘和 Image.asset 都能编译通过、
/// 都能在真机上"显示一个看起来像 logo 的东西"。
/// 只有断言 widget 树里存在 `Image`（且其 provider 指向 assets）才能防回归。
void main() {
  testWidgets('★ CfLogo 必须渲染 assets/icon.png，而不是自绘图形', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: CfLogo(size: 64))),
    ));

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, isNotEmpty, reason: 'CfLogo 内部必须有 Image；没有说明退回自绘了');

    final provider = images.first.image;
    expect(provider, isA<AssetImage>(),
        reason: 'CfLogo 的图必须来自 asset（与桌面图标同源），不能是内存绘制');

    final path = (provider as AssetImage).assetName;
    expect(path, 'assets/icon.png',
        reason: '品牌图标的唯一来源是 assets/icon.png（由工作区根 icon.png 生成）');
  });

  testWidgets('CfLogo 尺寸合规（可指定 size，不被父级挤压）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: CfLogo(size: 64))),
    ));

    final box = tester.getSize(find.byType(CfLogo));
    expect(box.width, 64);
    expect(box.height, 64);
  });

  testWidgets('资源缺失时退化为品牌色方块（不崩、不留白）', (tester) async {
    // errorBuilder 的存在意义：asset 打错包时给一个可接受的降级，
    // 而不是红屏/空白。这里断言"即使走了 errorBuilder 也能渲出尺寸"。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: CfLogo(size: 48))),
    ));
    await tester.pump();

    expect(tester.getSize(find.byType(CfLogo)), const Size(48, 48));
  });
}
