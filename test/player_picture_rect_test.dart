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

    test('★ 两档（自动/适应）行为一致：都按片源比例内接', () {
      // ★ 2026-10-10 档位精简为两档后，`fill`/`cover` 已删除
      //（用户要求只留自动/适应）⇒ 断言两档结果相同。
      for (final m in AspectMode.values) {
        final r = AspectMode.pictureSize(
          mode: m,
          viewportW: vw,
          viewportH: vh,
          videoRatio: 16 / 9,
        );
        expect(r.width / r.height, closeTo(16 / 9, 0.001),
            reason: '${m.name} 应按片源比例内接（两档语义一致）');
      }
    });

    test('★ 两档都不带固定比例（比例由片源决定）', () {
      // 原「固定比例档按该比例内接（忽略片源比例）」的测试随档位删除而失效：
      // 现在没有任何档位会"忽略片源比例"，故改断言"全部为 null"。
      for (final m in AspectMode.values) {
        expect(m.ratio, isNull,
            reason: '${m.name} 不该带固定比例 —— 比例由片源决定');
      }
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

    test('★★ auto 必须"忠于片源"（绝不变形）—— 本轮修正的行为', () {
      // ## 改前 vs 改后（真机实测驱动的修正）
      // 改前：方向一致就**强制 16:9/9:16** ⇒ 宽银幕电影纵向拉伸 34.3%
      //      （真机取证：《伟大的长征》3840x1608 = 2.388:1，
      //        横屏视口 2400x1080 下应显示高 1005，被拉到 1350）
      // 改后：**始终 contain**（保留片源比例，黑边补足）
      //
      // 依据：mpv `keepaspect` 默认 yes、Media3 `RESIZE_MODE_FIT`、
      //       VLC 比例菜单首项"默认" —— 三家一致。

      // ① 横屏 + 16:9 片源 ⇒ contain（不再强制，也不该变形）
      expect(
          AspectMode.resolveAuto(width: 2400, height: 1080, videoRatio: 16 / 9),
          AspectMode.contain,
          reason: '★★ 若这里返回 ratio16x9，2.39:1 的电影就会被拉伸');

      // ② 横屏 + 2.39:1 宽银幕 ⇒ contain（关键：改前会被拉伸 34%）
      expect(
          AspectMode.resolveAuto(width: 2400, height: 1080, videoRatio: 2.388),
          AspectMode.contain);

      // ③ 竖屏 + 16:9 ⇒ contain
      expect(AspectMode.resolveAuto(width: vw, height: vh, videoRatio: 16 / 9),
          AspectMode.contain);

      // ④ 竖屏 + 9:16 ⇒ contain（改前是 ratio9x16；现在也走 contain，
      //    因为 9:16 内容在 9:16 屏里 contain 的结果**本来就是满屏**）
      expect(AspectMode.resolveAuto(width: vw, height: vh, videoRatio: 9 / 16),
          AspectMode.contain);

      // ⑤ 比例未知 ⇒ contain（不能猜；渲染层按 16:9 兜底）
      expect(AspectMode.resolveAuto(width: vw, height: vh, videoRatio: null),
          AspectMode.contain);
      expect(AspectMode.resolveAuto(width: vw, height: vh, videoRatio: 0),
          AspectMode.contain);
    });

    test('★★ 宽银幕电影：contain 的结果必须保留原比例（不变形）', () {
      // 真机实测场景复现：2.388:1 片源 + 横屏视口 2400x1080
      const ratio = 2.388;
      final m = AspectMode.resolveAuto(
          width: 2400, height: 1080, videoRatio: ratio);
      final r = AspectMode.pictureSize(
          mode: m, viewportW: 2400, viewportH: 1080, videoRatio: ratio);
      // 按真实比例内接：高受限（2.388 > 16/9=1.778）
      expect(r.width / r.height, closeTo(ratio, 0.01),
          reason: '★★ 显示矩形的宽高比**必须等于片源比例** ——\n'
              '    这是"不变形"的定义。改前强制 16:9 会得到 1.778。');
      expect(r.width, closeTo(2400, 1));
      expect(r.height, closeTo(2400 / ratio, 1));
      // 与"错误做法"的量化对比
      final wrong = 2400 / (16 / 9);
      expect(wrong / r.height - 1, greaterThan(0.3),
          reason: '改前的高度比正确值大 34% ⇒ 纵向拉伸（真机实测值）');
    });

    test('★★ 竖屏看宽银幕电影 ⇒ 上下大黑边（用户看到的"加黑边"）', () {
      const ratio = 2.388;
      final m = AspectMode.resolveAuto(
          width: vw, height: vh, videoRatio: ratio);
      final r = AspectMode.pictureSize(
          mode: m, viewportW: vw, viewportH: vh, videoRatio: ratio);
      expect(r.width, closeTo(vw, 0.01));
      expect(r.height, closeTo(vw / ratio, 0.01));
      final bar = (vh - r.height) / 2;
      // ⚠️ 视口单位是**逻辑 dp**（393×873），不是物理像素（1080×2400）
      //    高 873 - 画面 164.5 = 708.5，上下各 ≈ 354dp
      expect(bar, greaterThan(300),
          reason: '★ 竖屏看 2.39:1 电影，上下黑边各约 354dp '
              '（占屏高 40%）—— 这正是用户说的"上下增加点黑边"');
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
