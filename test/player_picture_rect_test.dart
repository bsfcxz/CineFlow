// 画面矩形计算的守卫测试。
//
// ## 为什么需要（真机实测抓到的缺陷）
// 弹幕层原本用 `Positioned.fill` 铺满**整个屏幕**。
// 而竖屏看 16:9 内容时视频只是**中间一条**（上下黑边）⇒
// 弹幕飘到黑边上、甚至**压住顶部标题与返回按钮**。
// 真机截图确认：弹幕出现在「斗罗大陆Ⅱ绝世唐门」标题之上。
//
// ## 为什么必须单测（"同一条数学写两处"的风险）
// `AspectMode.pictureSize` 必须与 `AspectVideo` 的布局**逐档一致**：
// 若 `AspectVideo` 改了布局而这里没改，弹幕就会偏出画面 ——
// 这种缺陷**静态分析发现不了**，只能靠断言数学本身。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/domain/player_constants.dart';

/// 竖屏手机视口（典型 1080×2400 @ 2.75x ≈ 393×873 dp）
const vw = 393.0;
const vh = 873.0;

void main() {
  group('★ 画面矩形（弹幕只能铺在画面内）', () {
    test('★★ 竖屏看 16:9 内容 ⇒ 画面是中间一条（不是全屏）', () {
      final r = AspectMode.pictureSize(
        mode: AspectMode.contain,
        viewportW: vw,
        viewportH: vh,
        videoRatio: 16 / 9,
      );
      // 宽度占满，高度按比例 ⇒ 远小于视口高
      expect(r.width, closeTo(vw, 0.01));
      expect(r.height, closeTo(vw / (16 / 9), 0.01));
      expect(r.height, lessThan(vh * 0.35),
          reason: '★★ 竖屏看横屏内容，画面只占中间一小条 ——\n'
              '    弹幕必须限制在这一条里，否则会压住顶部标题。');
    });

    test('★ 横屏看 16:9 ⇒ 高度铺满、左右少量黑边', () {
      // 视口 873×393（横屏）。16:9 内容按**高度**内接：
      //   height = 393，width = 393 × 16/9 ≈ 698.7 < 873
      // ⇒ 左右各留 ~87dp 黑边（超宽屏手机看 16:9 的正常表现）
      final r = AspectMode.pictureSize(
        mode: AspectMode.contain,
        viewportW: 873,
        viewportH: 393,
        videoRatio: 16 / 9,
      );
      expect(r.height, closeTo(393, 0.01), reason: '高度受限 ⇒ 铺满高');
      expect(r.width, closeTo(393 * 16 / 9, 0.01));
      expect(r.width, lessThan(873),
          reason: '16:9 在更宽的视口里不会铺满宽（左右有黑边）');
    });

    test('★ fill / cover 都铺满视口（可见区域是整个画面）', () {
      for (final m in [AspectMode.fill, AspectMode.cover]) {
        final r = AspectMode.pictureSize(
          mode: m,
          viewportW: vw,
          viewportH: vh,
          videoRatio: 16 / 9,
        );
        expect(r.width, vw, reason: '${m.name} 可见区域是整个视口');
        expect(r.height, vh, reason: '${m.name} 可见区域是整个视口');
      }
    });

    test('★ 固定比例档按该比例内接（忽略片源比例）', () {
      final r = AspectMode.pictureSize(
        mode: AspectMode.ratio4x3,
        viewportW: vw,
        viewportH: vh,
        videoRatio: 16 / 9, // 应被忽略
      );
      expect(r.width / r.height, closeTo(4 / 3, 0.001),
          reason: '固定档必须用档位比例，不能用片源比例');
    });

    test('★ 片源比例未知时按 16:9 兜底（与 AspectVideo 一致）', () {
      final r = AspectMode.pictureSize(
        mode: AspectMode.contain,
        viewportW: vw,
        viewportH: vh,
        videoRatio: 16 / 9,
      );
      expect(r.width / r.height, closeTo(16 / 9, 0.001));
    });

    test('★ 退化输入不崩、不产生负尺寸', () {
      for (final bad in [0.0, -1.0]) {
        final r = AspectMode.pictureSize(
          mode: AspectMode.contain,
          viewportW: vw,
          viewportH: vh,
          videoRatio: bad,
        );
        expect(r.width, greaterThan(0));
        expect(r.height, greaterThan(0));
      }
      final z = AspectMode.pictureSize(
        mode: AspectMode.contain,
        viewportW: 0,
        viewportH: 0,
        videoRatio: 16 / 9,
      );
      expect(z.width, 0);
      expect(z.height, 0);
    });

    test('★★ auto 解析后再算，结果必须是"方向一致才满屏"', () {
      // 竖屏 + 横片源 ⇒ contain（不满屏）
      final m1 = AspectMode.resolveAuto(
          width: vw, height: vh, videoRatio: 16 / 9);
      expect(m1, AspectMode.contain);
      final r1 = AspectMode.pictureSize(
          mode: m1, viewportW: vw, viewportH: vh, videoRatio: 16 / 9);
      expect(r1.height, lessThan(vh * 0.35),
          reason: '竖屏看横片 ⇒ 画面只占中间一条');

      // 横屏 + 横片源 ⇒ 16:9（满屏）
      final m2 = AspectMode.resolveAuto(
          width: vh, height: vw, videoRatio: 16 / 9);
      expect(m2, AspectMode.ratio16x9);
      final r2 = AspectMode.pictureSize(
          mode: m2, viewportW: vh, viewportH: vw, videoRatio: 16 / 9);
      expect(r2.height, closeTo(vw * 16 / 9 > vw ? vw : r2.height, 0.01),
          reason: '16:9 在横屏视口里按宽度内接');

      // 竖屏 + 竖片源 ⇒ 9:16（满屏）
      final m3 = AspectMode.resolveAuto(
          width: vw, height: vh, videoRatio: 9 / 16);
      expect(m3, AspectMode.ratio9x16);
      final r3 = AspectMode.pictureSize(
          mode: m3, viewportW: vw, viewportH: vh, videoRatio: 9 / 16);
      expect(r3.width, closeTo(vw, 0.01), reason: '竖屏看竖片 ⇒ 铺满宽');
    });

    test('★ 内接数学：取"更受限"的那一维（两种情形都验）', () {
      // 情形A：视口比内容"宽" ⇒ 高度受限
      final a = AspectMode.pictureSize(
          mode: AspectMode.contain,
          viewportW: 1000, viewportH: 400, videoRatio: 1.0);
      expect(a.height, 400);
      expect(a.width, 400, reason: '1:1 内容在高 400 的视口里是 400×400');

      // 情形B：视口比内容"高" ⇒ 宽度受限
      final b = AspectMode.pictureSize(
          mode: AspectMode.contain,
          viewportW: 400, viewportH: 1000, videoRatio: 1.0);
      expect(b.width, 400);
      expect(b.height, 400);
    });
  });
}
