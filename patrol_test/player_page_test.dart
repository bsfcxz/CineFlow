/// 播放页真机 UI 走查（Patrol）。
///
/// # 这个测试补的是**全项目最大的验证缺口**
///
/// `integration_test/player_kernel_test.dart` 只驱动**内核**
/// （建纹理 → initialize → 起播 → seek → dispose），**从不碰 UI 层**。
/// 于是下面这些从没有过任何自动化验证，只能靠人肉点：
///
///   · 控制层点一下能不能显/隐
///   · 控制条上的钮**点了有没有反应**
///     （本项目真实踩过：按钮被挤出屏幕、点了因守卫静默无效 —— static analysis 全看不见）
///   · 音轨/字幕/倍速弹层能不能打开
///   · 锁定后能不能解锁
///
/// # 为什么完全离线
///
/// `PlayerPage` 只依赖几个 provider。用 `ProviderScope(overrides:)` 注入
/// [`FakeMediaProvider`]，**不需要服务器、不需要凭据、不需要网络** ——
/// 结果完全确定。这比"登录真服务器再点"可靠得多（后者会因网络/账号状态时好时坏）。
///
/// # 第一次跑就抓到一个真实崩溃（这就是补 UI 测试的价值）
///
///     Null check operator used on a null value
///     _PlayerPageState._player (player_page.dart:176)
///     _PlayerPageState._settingsDrawer (player_page.dart:2107)
///     _PlayerPageState.build (player_page.dart:1440)
///
/// `_settingsDrawer()` 在 `build` 里**无条件构建**，内部却读 `_player`（=`_facade!`），
/// 而 `_facade` 要等异步 `_boot()` 建完内核才非空 →
/// **冷启动进播放页的头几百毫秒整页 build 抛异常**（红屏）。
/// 此前无人发现，正因为**从没有测试构建过"未就绪状态"的播放页**。
/// 已修（`_settingsDrawer` 在 `!_ready` 时返回空）。
///
/// # 这个测试**不能**证明什么（不要高估它）
///
///   · **画面内容**：视频是原生纹理，断言拿不到像素，只能证明"纹理 widget 在"
///   · **真实片源能播**：假源指向黑洞端口，必然超时 —— 那恰好用来验证超时路径
///   · **手势精度**：能触发 tap/drag，但像素级手感仍需人看
///
/// 故它守的是**接线**（控件存在、可命中、点了走对分支）；
/// 真机肉眼走查仍需单独做。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:cineflow/data/models.dart';
import 'package:cineflow/keys.dart';
import 'package:cineflow/player/player_page.dart';
import 'package:cineflow/state/providers.dart';

import 'fake_media_provider.dart';

/// 造一个"多集 + 多轨"的条目 —— 「唯一性则隐藏」这条规则
/// 只有在**有可选项**时才验证得到。
MediaItem _movie() => const MediaItem(
      id: 'fake-item-1',
      name: '测试影片',
      type: 'Movie',
      productionYear: 2024,
      runtimeTicks: 72000000000,
    );

List<MediaItem> _episodes() => List.generate(
      3,
      (i) => MediaItem(
        id: 'fake-ep-${i + 1}',
        name: '第 ${i + 1} 话·测试',
        type: 'Episode',
        seriesId: 'fake-series',
        seasonId: 'fake-season',
        parentIndexNumber: 1,
        indexNumber: i + 1,
      ),
    );

/// 播放页需要的 provider 里，测试只覆盖 `embyApiProvider`（换成假实现）。
///
/// 其余（`sessionStoreProvider` / `danmakuConfigProvider` / `danmakuForItemProvider`）
/// 在生产实现下也能安全降级（读不到就走默认值）——
/// **少覆盖一处就少一处与真实路径的偏差**，故不覆盖。
Widget _hostApp({List<MediaItem>? episodes, int index = 0}) => ProviderScope(
      overrides: [
        embyApiProvider.overrideWithValue(FakeMediaProvider()),
      ],
      child: MaterialApp(
        home: PlayerPage(
          item: _movie(),
          episodes: episodes,
          index: index,
        ),
      ),
    );

void main() {
  patrolTest(
    '播放页：控制层可显隐；控制条按钮存在且可点；弹层能打开',
    ($) async {
      await $.pumpWidgetAndSettle(_hostApp(episodes: _episodes()));

      // ---- 1. 进入播放页 ----
      await $(keys.player.page).waitUntilVisible();

      // 视频手势区必须在（它承载"点一下显隐控制层"）
      expect(
        $(keys.player.videoGestureArea).evaluate().isNotEmpty,
        isTrue,
        reason: '视频手势区缺失 —— 单击显隐/双击快进/长按倍速全部失效',
      );

      // ---- 2. 控制层显隐 ----
      //
      // ## 判据为什么读 `AnimatedOpacity.opacity` 而不是 `finder.visible`
      //
      // 三个坑全踩过，记录下来免得后人重走：
      //
      //   坑 1：`initState` 里有 `_armHide(seconds: 6)`，而 `pumpWidgetAndSettle`
      //        会**推进仿真时间直到无待处理帧** → 那个定时器在 settle 期间就触发了
      //        → 回到测试代码时控制层已自动隐藏。**不能假设初值**。
      //
      //   坑 2：`controls` 键挂在 `Column` 上，而 `PatrolFinder.visible` 的口径是
      //        `hitTestable(at: Alignment.center)` —— 那个 Column 的中心正好是
      //        `Spacer()` 空白，**永远命不中** → `controls.visible` 恒 false。
      //
      //   坑 3：改用 `rateButton.visible` 后，`.tap()` 视频区又抛
      //        `WaitUntilVisibleTimeoutException`（视频层在控制层之下，
      //        控制层可见时点不到它）；改坐标点后 `rateButton.visible` 仍恒 true
      //        ——因为控制层隐藏时用的是 `AnimatedOpacity`（**只改透明度，
      //        不摘出树**），而 `hitTestable` 对 0 透明度的 `Opacity` 层
      //        判定并不可靠（`IgnorePointer` 在 `AnimatedOpacity` **内层**，
      //        外层仍可命中）。
      //
      // ## 直接读状态才是**诚实**的判据
      //
      // 控制层的显隐由 `AnimatedOpacity.opacity` 表达（`_showControls ? 1 : 0`）。
      // 读它就是读"UI 到底有没有把控制层显示出来"，不绕 hit-test 的语义。
      double controlsOpacity() {
        final w = $.tester.widgetList<AnimatedOpacity>(
            find.byKey(keys.player.controls));
        // 控制层的 AnimatedOpacity 是 keys.player.controls 的**祖先**（Column 在它内部）
        final ancestors = find.ancestor(
          of: find.byKey(keys.player.controls),
          matching: find.byType(AnimatedOpacity),
        );
        final list = $.tester.widgetList<AnimatedOpacity>(ancestors).toList();
        if (list.isEmpty) {
          // 兜底：有可能键所在子树里就有 AnimatedOpacity
          return w.isEmpty ? -1 : w.first.opacity;
        }
        return list.first.opacity;
      }

      Future<void> tapVideoArea() async {
        final size = $.tester.view.physicalSize / $.tester.view.devicePixelRatio;
        // ⚠️ 两个坑，都踩过：
        //
        // 坑 A：**不能点正中心**。屏幕正中就是那个 62×62 的播放/暂停按钮，
        //      点它会触发 `_togglePlay()` 而不是视频层的 `_onTap()` ——
        //      现象是"控制层没翻转"，很容易误判成 `_onTap` 没接线。
        //      改点左上区域空白（横屏下约 1/4 宽、1/4 高处：
        //      在顶栏之下、中央按钮之左）。
        //
        // 坑 B：**必须等过双击判定窗**。视频层同时注册了 `onTap` 与 `onDoubleTap`，
        //      而 Flutter 的 `GestureDetector` 为了区分单/双击，会**故意延迟
        //      `onTap` 约 300ms**（`kDoubleTapTimeout`）。
        //      `pumpAndSettle` 只推进"有帧待处理"的时间，**不保证覆盖这个定时器**，
        //      于是 `onTap` 可能还没触发就去断言了 → 现象是"点了没反应"
        //      （又一个极易误判的点）。
        //      故这里显式 pump 过 400ms 再 settle。
        await $.tester.tapAt(Offset(size.width * 0.25, size.height * 0.25));
        await $.tester.pump(const Duration(milliseconds: 400));
        await $.pumpAndSettle();
      }

      final opacityAtStart = controlsOpacity();
      expect(opacityAtStart, anyOf(0.0, 1.0),
          reason: '控件层的 AnimatedOpacity 不在预期状态（读不到说明结构变了）');

      await tapVideoArea();
      expect(
        controlsOpacity(),
        isNot(opacityAtStart),
        reason: '点一下屏幕控制层没有翻转 —— _onTap 没接线',
      );

      await tapVideoArea();
      expect(
        controlsOpacity(),
        opacityAtStart,
        reason: '再点一下应回到初始显隐状态',
      );

      // 后续步骤要点控制条上的按钮 → 确保控制层处于**可见**态
      if (controlsOpacity() != 1.0) {
        await tapVideoArea();
      }
      expect(controlsOpacity(), 1.0,
          reason: '无法让控制层显示 —— 后面的按钮都点不到');

      // ---- 3. 控制条上的按钮：存在即可点（不该被挤出屏幕）----
      //
      // 背景：本项目踩过"7 个按钮塞进不可滚动 Row → 横向溢出 →
      // 选集按钮被静默裁掉"。所以这里逐个断言**能找到**。
      expect($(keys.player.rateButton).evaluate().isNotEmpty, isTrue,
          reason: '倍速按钮不在树上');
      expect($(keys.player.danmakuButton).evaluate().isNotEmpty, isTrue,
          reason: '弹幕按钮不在树上');
      // 多集（3 集）→ 选集按钮应出现。
      // 注意这个判据只看 `widget.episodes`（**不依赖内核**），故本测试能验证。
      expect($(keys.player.episodeButton).evaluate().isNotEmpty, isTrue,
          reason: '3 集却没有选集按钮 —— 「多集才显示」的判据错了');

      // ⚠️ 音轨/字幕按钮**本测试验证不到**，这不是缺陷而是设计使然：
      //
      //   `_showAudioBtn => showAudioButton(_pstate.tracks.audio.length)`
      //   —— 判据用的是**播放内核报告的轨道数**（`_pstate` 来自 mpv 的
      //   `track-list`），而 `_pstate` 只在真机内核初始化后才非空。
      //   纯 Widget 测试里没有 mpv → 轨道数恒为 0 → 按钮**按设计隐藏**。
      //
      //   换句话说：**「有 2 条音轨就显示音轨按钮」这条规则，
      //   用假数据源是验证不了的** —— 这也解释了为什么它是"接线"测试的边界。
      //
      //   要验证它只有两条路：
      //     a) 真机走查（真实片源 + 真实内核）—— 见第 20 轮真机验证；
      //     b) 补一个**纯函数单测**断言 `showAudioButton(2) == true`
      //        （判据本身与 UI 解耦，已由 `test/` 覆盖）。
      //
      //   这里显式断言"当前隐藏"是**有意**的：一旦将来有人把判据改成读
      //   `launch.streams`（服务端轨数），这条断言会变红，提醒同步更新注释与真机验证。
      expect(
        $(keys.player.audioButton).evaluate().isEmpty,
        isTrue,
        reason: '无内核轨道时音轨按钮应当隐藏（判据走 _pstate.tracks，非服务端 streams）'
            '—— 若这里变红，说明判据改了，需同步真机验证与注释',
      );

      // ---- 4. 倍速弹层：点了要真的打开 ----
      //
      // 倍速按钮**不依赖内核**（它只改 mpv 的 speed 属性，弹层本身是静态列表），
      // 所以这条"点了有反应"在纯 Widget 测试里验证得到。
      await $(keys.player.rateButton).tap();
      // 用 waitUntilExists 而非 waitUntilVisible：弹层元素**已在树上**就证明它打开了；
      // 而 waitUntilVisible 还要求其中心点可命中 —— 弹层背后那层透明遮罩会让它判失败
      // （实测踩过：文本明明 Found 1 widget，却因 hit-test 不可达而超时）。
      await $('播放速度').waitUntilExists();
      await $.tester.tapAt(const Offset(20, 20));
      await $.pumpAndSettle();

      // ---- 5. 选集弹层：多集时能打开 ----
      //
      // 这是用户明确反馈过的那条路径：「剧集详情页应是"播放/立即播放"而非"选集"」
      // 之后，选集入口移到了播放页控制条上 —— 必须确保它**真的能点开**。
      await $(keys.player.episodeButton).tap();
      await $('第 1 集 第 1 话·测试').waitUntilExists();
      await $.tester.tapAt(const Offset(20, 20));
      await $.pumpAndSettle();

      // ---- 6. 锁按钮：锁定后解锁按钮必须仍在 ----
      //
      // 否则用户会被**永久锁死**在锁定态（灾难性缺陷）—— 这条断言就是在守它。
      await $(keys.player.lockButton).tap();
      await $.pumpAndSettle();
      expect($(keys.player.lockButton).evaluate().isNotEmpty, isTrue,
          reason: '锁定后解锁按钮消失了 —— 用户会被永久锁在锁定态');
    },
  );

  patrolTest(
    '播放页：无分集时「选集」按钮必须隐藏（唯一性则隐藏）',
    ($) async {
      // 电影：没有分集 → 选集按钮不该出现（点开发现别无选择 = 噪音）
      await $.pumpWidgetAndSettle(_hostApp());

      await $(keys.player.page).waitUntilVisible();

      expect(
        $(keys.player.episodeButton).evaluate().isEmpty,
        isTrue,
        reason: '电影（无分集）不该显示选集按钮 —— 用户明确要求「唯一性则隐藏」',
      );
      // 但倍速/弹幕这类**总是有选择余地**的按钮仍应存在
      expect($(keys.player.rateButton).evaluate().isNotEmpty, isTrue);
      expect($(keys.player.danmakuButton).evaluate().isNotEmpty, isTrue);
    },
  );
}
