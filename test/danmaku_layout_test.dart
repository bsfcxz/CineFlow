import 'package:cineflow/danmaku/danmaku_layout.dart';
import 'package:cineflow/danmaku/danmaku_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 弹幕布局计算的单元测试。
///
/// ## 为什么这些数学必须被断言
///
/// 弹幕是**快速移动**的：肉眼根本判断不了"第 3 秒时某条弹幕是否本该出现"、
/// "两条是否真的重叠了"。而这些错误的表现是"偶尔少一条"或"某处叠了一下"，
/// 用户不会报 bug，只会觉得"这弹幕怪怪的"。
///
/// 拆成纯函数后可以按毫秒断言。所有测试都**不依赖真实渲染环境**——
/// 宽度由确定性的假测量函数提供（真实测量需要 TextPainter）。
void main() {
  // 假测量：每字符 10px（确定性，便于手算期望值）
  double fakeWidth(Danmaku d) => d.text.length * 10.0;

  Danmaku d(int ms, String text, {DanmakuMode mode = DanmakuMode.scroll}) =>
      Danmaku(timeMs: ms, text: text, mode: mode);

  DanmakuLayoutConfig cfg({
    double w = 1000,
    double h = 500,
    double lane = 25,
    bool safeArea = false,
    DanmakuOverflow overflow = DanmakuOverflow.drop,
  }) =>
      DanmakuLayoutConfig(
        screenWidth: w,
        screenHeight: h,
        laneHeight: lane,
        topPadding: 0,
        scrollDuration: 10, // 便于手算：速度 = (1000+w)/10
        fixedDuration: 5,
        // 测试默认关掉字幕预留：轨道数才好手算（生产默认开启）
        reserveSubtitleLane: safeArea,
        overflow: overflow,
      );

  group('轨道数', () {
    test('按屏幕高度的 80% 计算', () {
      expect(cfg(h: 500, lane: 25).laneCount, 16); // 500*0.8/25
    });

    test('★ 默认给字幕留一行（借鉴 canvas_danmaku 的 safeArea）', () {
      final withSafe = DanmakuLayoutConfig(
        screenHeight: 500,
        laneHeight: 25,
        reserveSubtitleLane: true,
      );
      final without = DanmakuLayoutConfig(
        screenHeight: 500,
        laneHeight: 25,
        reserveSubtitleLane: false,
      );
      expect(without.laneCount, 16);
      expect(withSafe.laneCount, 15, reason: '少一行，避免弹幕压在字幕上');
    });

    test('至少 1 条，避免极小窗口下除零/无轨道', () {
      expect(cfg(h: 10, lane: 25).laneCount, 1);
    });

    test('有上限，避免异常尺寸导致巨大数组', () {
      expect(cfg(h: 1000000, lane: 1).laneCount, 64);
    });
  });

  group('滚动弹幕位置', () {
    test('t=0 时从左边界开始（x=0 → 实际从屏右进入，见下方时间轴）', () {
      // 设计：弹幕在 timeMs 时刻其**左边缘位于屏幕右边界**，
      // 然后向左移动。所以 elapsed=0 时 x = screenWidth。
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'hi')],
        config: cfg(),
        widthOf: fakeWidth,
      );
      final vis = plan.visibleAt(0, config: cfg(), widthOf: fakeWidth);
      expect(vis.length, 1);
      expect(vis.single.x, closeTo(1000, 0.01),
          reason: '刚出现时左边缘贴着屏幕右侧');
    });

    test('随时间线性左移', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'abcd')], // 宽 40
        config: c,
        widthOf: fakeWidth,
      );
      // 速度 = (1000+40)/10 = 104 px/s
      final at1 = plan.visibleAt(1, config: c, widthOf: fakeWidth).single;
      final at2 = plan.visibleAt(2, config: c, widthOf: fakeWidth).single;
      expect(at1.x, closeTo(1000 - 104, 1));
      expect(at2.x, closeTo(1000 - 208, 1));
      expect(at1.x - at2.x, closeTo(104, 1), reason: '每秒位移应恒定');
    });

    test('完全离开左侧后不再可见（不残留、不占轨道）', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'abcd')],
        config: c,
        widthOf: fakeWidth,
      );
      // 总行程 = (1000+40)/104 ≈ 10s，11s 时必然已滚出
      expect(plan.visibleAt(11, config: c, widthOf: fakeWidth), isEmpty);
    });

    test('时间未到时不可见（不能提前出现）', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(5000, 'later')],
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.visibleAt(0, config: c, widthOf: fakeWidth), isEmpty);
      expect(plan.visibleAt(5, config: c, widthOf: fakeWidth).length, 1);
    });
  });

  group('顶部/底部固定弹幕', () {
    test('顶部弹幕居中且贴上方', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'abcd', mode: DanmakuMode.top)], // 宽 40
        config: c,
        widthOf: fakeWidth,
      );
      final v = plan.visibleAt(1, config: c, widthOf: fakeWidth).single;
      expect(v.x, closeTo((1000 - 40) / 2, 0.01), reason: '水平居中');
      expect(v.y, 0, reason: '第 0 轨贴顶（topPadding=0）');
    });

    test('底部弹幕贴下方且不与顶部同 y', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'abcd', mode: DanmakuMode.bottom)],
        config: c,
        widthOf: fakeWidth,
      );
      final v = plan.visibleAt(1, config: c, widthOf: fakeWidth).single;
      expect(v.y, 500 - 25, reason: '第 0 轨底边距 = 一行高');
    });

    test('停留时长结束后消失', () {
      final c = cfg(); // fixedDuration = 5
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'x', mode: DanmakuMode.top)],
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.visibleAt(4.9, config: c, widthOf: fakeWidth).length, 1);
      expect(plan.visibleAt(5.1, config: c, widthOf: fakeWidth), isEmpty);
    });

    test('末尾淡出（末 0.5 秒透明度下降）', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'x', mode: DanmakuMode.top)],
        config: c,
        widthOf: fakeWidth,
      );
      final early = plan.visibleAt(1, config: c, widthOf: fakeWidth).single;
      final late = plan.visibleAt(4.8, config: c, widthOf: fakeWidth).single;
      expect(early.opacity, 1.0);
      expect(late.opacity, lessThan(1.0), reason: '淡出避免"啪"地消失');
    });
  });

  group('轨道分配（防重叠）', () {
    test('同一时刻的多条滚动弹幕分到不同轨道', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'a'), d(0, 'b'), d(0, 'c')],
        config: c,
        widthOf: fakeWidth,
      );
      final vis = plan.visibleAt(0.5, config: c, widthOf: fakeWidth);
      final lanes = vis.map((v) => v.lane).toSet();
      expect(lanes.length, vis.length, reason: '同屏不该有两条共用轨道');
    });

    test('轨道按顺序填充（第 0 轨优先）', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'a'), d(0, 'b')],
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.scroll[0], 0);
      expect(plan.scroll[1], 1);
    });

    test('时间错开后轨道可复用', () {
      final c = cfg(); // 滚动时长 10s
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'a'), d(11000, 'b')], // 超过 10s 后
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.scroll[1], 0, reason: '前一条已离开，应复用第 0 轨');
    });

    test('★ 等宽弹幕可以紧跟（追尾判据允许复用轨道）', () {
      // 同宽度 → 速度相同 → 永远不会追上 → 只要前一条已进屏就能复用。
      // 这是"只判是否完全离开"会错杀的场景：等宽弹幕彼此不构成追尾风险，
      // 却要白等十几秒，密集弹幕池会因此大量丢弃。
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'aaa'), d(500, 'bbb')], // 宽度相同
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.scroll[1], 0);
      expect(plan.dropped, 0);
    });

    test('★ 窄弹幕后面紧跟宽弹幕 → 判为追尾，换轨道（物理正确）', () {
      // 速度模型是 (屏宽+文本宽)/时长 ⇒ **宽弹幕更快**。
      // 实测核算：窄弹幕 101px/s、宽弹幕 129px/s，间隔 500ms 时
      // 间距 40.5px、相对速度 28px/s ⇒ 1.45s 后追上，而那时窄弹幕
      // 右边缘还在 x≈813（屏幕中部）→ 必然视觉重叠。
      // 故此处必须换轨道，不能复用。
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [d(0, 'a'), d(500, 'a-very-long-danmaku-text-here')],
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.scroll[1], 1,
          reason: '宽弹幕会追上窄弹幕；若复用第 0 轨会看到两条叠在一起跑');
    });

    test('★ 长弹幕后面紧跟更快的长弹幕会被判追尾（换轨道）', () {
      // 两条都很宽时后一条速度更快 → 会追上 → 必须换轨道。
      // 若实现漏了追尾判据，这里会错误地复用第 0 轨并造成重叠。
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [
          d(0, 'x' * 50), // 宽 500
          d(100, 'y' * 80), // 宽 800，更快
        ],
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.scroll[1], 1,
          reason: '窄弹幕被宽弹幕追尾会造成视觉重叠，必须另找轨道');
    });

    test('大规模模式：轨道不足时复用而非丢弃', () {
      // 4 轨，6 条同刻宽弹幕
      final c = cfg(h: 500, lane: 100, overflow: DanmakuOverflow.overlap);
      final items = [for (var i = 0; i < 6; i++) d(0, 'x$i')];
      final plan = DanmakuTrackPlan.build(
        items: items,
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.dropped, 0, reason: 'overlap 模式应接受重叠而不丢弹幕');
      expect(plan.placed, 6);
    });

    test('默认（drop）模式：轨道不足时丢弃，不重叠', () {
      final c = cfg(h: 500, lane: 100, overflow: DanmakuOverflow.drop);
      final items = [for (var i = 0; i < 6; i++) d(0, 'x$i')];
      final plan = DanmakuTrackPlan.build(
        items: items,
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.dropped, 2);
      expect(plan.placed, 4);
    });

    test('同时刻超过轨道数时丢弃多余的，已排的仍正常显示', () {
      // 4 轨（500*0.8/100）
      final c = cfg(h: 500, lane: 100);
      final items = [for (var i = 0; i < 6; i++) d(0, 'x$i')];
      final plan = DanmakuTrackPlan.build(
        items: items,
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.dropped, 2, reason: '4 轨放不下 6 条，丢 2 条');
      expect(plan.visibleAt(0.5, config: c, widthOf: fakeWidth).length, 4);
    });

    test('顶部与底部轨道互相独立（同一 y 不冲突）', () {
      final c = cfg();
      final plan = DanmakuTrackPlan.build(
        items: [
          d(0, 't', mode: DanmakuMode.top),
          d(0, 'b', mode: DanmakuMode.bottom),
        ],
        config: c,
        widthOf: fakeWidth,
      );
      final vis = plan.visibleAt(1, config: c, widthOf: fakeWidth);
      expect(vis.length, 2, reason: '顶部与底部各有自己的轨道，不该互相挤掉');
      expect(vis[0].y, isNot(vis[1].y));
    });

    test('顶部弹幕超过轨道的部分被丢弃', () {
      final c = cfg(h: 100, lane: 100); // 只有 0.8 → 1 轨
      final plan = DanmakuTrackPlan.build(
        items: [
          d(0, 'a', mode: DanmakuMode.top),
          d(0, 'b', mode: DanmakuMode.top),
        ],
        config: c,
        widthOf: fakeWidth,
      );
      expect(plan.dropped, 1);
    });
  });

  group('屏蔽词过滤', () {
    test('命中屏蔽词的整条丢弃', () {
      final items = [d(0, '正常弹幕'), d(1, '这是广告内容'), d(2, '也好')];
      final out = filterBlocked(items, ['广告']);
      expect(out.length, 2);
      expect(out.any((x) => x.text.contains('广告')), isFalse);
    });

    test('空屏蔽列表不做任何过滤（且不复制列表，省开销）', () {
      final items = [d(0, 'a')];
      expect(filterBlocked(items, const []), same(items));
    });

    test('全是空白的屏蔽词被忽略', () {
      final items = [d(0, 'a')];
      expect(filterBlocked(items, ['  ', '']), same(items));
    });

    test('多个屏蔽词', () {
      final items = [d(0, '广告'), d(1, '剧透'), d(2, '正常')];
      expect(filterBlocked(items, ['广告', '剧透']).length, 1);
    });
  });

  group('文本宽度估算', () {
    test('中文按 1em，ASCII 按 0.55em', () {
      expect(approximateTextWidth('中', 20), closeTo(20, 0.01));
      expect(approximateTextWidth('a', 20), closeTo(11, 0.01));
    });

    test('混排累加', () {
      // 2 中文 + 2 ASCII = 2*20 + 2*11 = 62
      expect(approximateTextWidth('中文ab', 20), closeTo(62, 0.01));
    });

    test('空文本宽度为 0', () {
      expect(approximateTextWidth('', 20), 0);
    });
  });

  group('深色弹幕可读性', () {
    test('纯黑被提亮（否则在暗色画面上看不见）', () {
      final c = readableColor(0x000000);
      final lum = 0.299 * (c.r * 255) + 0.587 * (c.g * 255) + 0.114 * (c.b * 255);
      expect(lum, greaterThan(0), reason: '纯黑弹幕等于隐形');
    });

    test('亮色不被改动（保持原色相）', () {
      final c = readableColor(0xFFFFFF);
      expect(c.r, closeTo(1.0, 0.01));
      expect(c.g, closeTo(1.0, 0.01));
      expect(c.b, closeTo(1.0, 0.01));
    });

    test('透明度参数生效', () {
      expect(readableColor(0xFFFFFF, opacity: 0.5).a, closeTo(0.5, 0.01));
    });

    test('典型红色（16711680）保持可见', () {
      final c = readableColor(16711680);
      expect(c.r * 255, closeTo(255, 1));
      expect(c.g * 255, closeTo(0, 1));
    });
  });
}
