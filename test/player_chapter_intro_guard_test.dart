// 章节刻度 / 跳过片头 —— 守卫测试（对齐旧页能力，防"切默认页倒退"）。
//
// ## 这些测试守的是什么
// 新播放页（`PlayerFlowPage`）原先**缺**旧页已有的两项能力：
//   · 章节刻度（进度条上的分段标记）
//   · 跳过片头（自动跳过 + 浮钮）
// 补齐后，若将来有人删掉任一处接线，**功能会静默消失**
// （页面照常渲染，只是少了刻度 / 不再跳片头）——静态分析发现不了。
// 故用断言把"接线存在"固化下来。
//
// ## 为什么断言要剥注释（AGENTS §8.4 第 1 条）
// 实测踩过：`contains('s.videoRange')` 命中了**注释**里的同名文本，
// 删掉真代码测试仍全绿。故这里统一先 `_readCode()` 去掉注释行，
// 再断言 —— 否则本文件的断言会被自己的说明文字满足。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读源码并**剥掉注释行**（否则断言可能被注释满足 —— §8.4 第 1 条）。
String _readCode(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .split('\n')
      .where((l) {
        final t = l.trimLeft();
        return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
      })
      .join('\n');
}

void main() {
  group('章节刻度（进度条）', () {
    late String bars;
    late String tokens;

    setUpAll(() {
      bars = _readCode('lib/player/presentation/widgets/player_bars.dart');
      tokens = _readCode('lib/player/presentation/player_ui_tokens.dart');
    });

    test('PlayerProgressBar 必须有 chapters + duration 参数', () {
      // 为什么两个都要：chapters 是"秒"，换算成 0–1 需要 duration；
      // 只留 chapters 而删掉 duration，刻度就无法定位（或要靠外部预算，
      // 那会把"duration 未知"和"第 0 秒章节"混为一谈）。
      expect(bars.contains('this.chapters = const []'), isTrue,
          reason: '★ PlayerProgressBar 缺 chapters 参数 ⇒ 画不出刻度');
      expect(bars.contains('this.duration'), isTrue,
          reason: '★ 缺 duration ⇒ 无法把秒换算成 0–1 的刻度位置');
    });

    test('刻度位置必须用 duration 现算（且 duration 为 0 时不画）', () {
      // 守的是"除零"：起播早期 duration=0，直接除会得到 Infinity/NaN。
      final i = bars.indexOf('final totalMs = widget.duration?.inMilliseconds');
      expect(i, greaterThanOrEqualTo(0),
          reason: '★ 刻度换算必须走 totalMs 这个中间变量（并带 >0 判定）');
      expect(bars.contains('totalMs > 0'), isTrue,
          reason: '★ 缺 duration>0 判定 ⇒ 起播早期会画出错位刻度或抛异常');
    });

    test('刻度必须真的被渲染（不只是算了位置）', () {
      // 若只算 ticks 而不画，测试若只断言"含 ticks"仍会全绿 ——
      // 故断言**渲染循环**本身。
      expect(bars.contains('for (final t in ticks)'), isTrue,
          reason: '★ 算了刻度却没渲染 ⇒ 进度条上看不到分段');
      // ⚠️ 断言必须带 `color: ` 前缀 —— `PlayerUi.chapterTick` 是
      //    `PlayerUi.chapterTickWidth` 的**前缀**，裸串会被另一处满足
      //    （与 AGENTS §8.4② 记的 `§7.1` 吃掉 `§7.10` 是同一类陷阱）。
      expect(bars.contains('color: PlayerUi.chapterTick,'), isTrue,
          reason: '★ 刻度颜色必须用令牌（AGENTS §5.4：颜色只用令牌，'
              '且断言要带 `color: ` 前缀，否则被 chapterTickWidth 满足）');
    });

    test('跳过首尾刻度（端点重合是纯噪声）', () {
      expect(bars.contains('t > 0.002 && t < 0.998'), isTrue,
          reason: '★ 不跳过首尾 ⇒ 左右端点被"加粗"，看起来像进度条坏了');
    });

    test('令牌必须存在（chapterTickWidth / chapterTick）', () {
      expect(tokens.contains('chapterTickWidth'), isTrue,
          reason: '★ 刻度线宽令牌缺失');
      expect(tokens.contains('chapterTick'), isTrue, reason: '★ 刻度颜色令牌缺失');
    });
  });

  group('章节数据流（宿主 → UI → 进度条）', () {
    late String flow;
    late String ui;

    setUpAll(() {
      flow = _readCode('lib/player/player_flow_page.dart');
      ui = _readCode('lib/player/presentation/player_ui_page.dart');
    });

    test('slots 必须承载 chapters（架构约定 §5.1）', () {
      // UI 页不碰 MediaProvider —— 章节只能由宿主经 slots 传入，
      // 与 buffered 同一模式。若有人让 UI 自己去查，就违反了分层。
      expect(ui.contains('this.chapters = const []'), isTrue,
          reason: '★ PlayerPageSlots 缺 chapters ⇒ 数据到不了进度条');
      expect(ui.contains('final List<double> chapters'), isTrue,
          reason: '★ slots 的 chapters 字段缺失');
    });

    test('宿主必须把章节透传（不可断链）', () {
      expect(flow.contains('chapters: [for (final c in _chapters) c.seconds]'),
          isTrue,
          reason: '★ 宿主没把章节传给 slots ⇒ UI 拿不到 ⇒ 刻度消失');
      expect(ui.contains('chapters: widget.slots.chapters'), isTrue,
          reason: '★ UI 页没把 slots.chapters 传给 PlayerBottomBar ⇒ 刻度消失');
    });

    test('章节必须优先读 launch.chapters（省一次请求）', () {
      // 服务端已在 PlaybackInfo 里给了章节，再单独请求是纯浪费。
      expect(flow.contains('if (launch.chapters.isNotEmpty)'), isTrue,
          reason: '★ 未优先用 launch.chapters ⇒ 每次起播多一次网络往返');
    });
  });

  group('跳过片头', () {
    late String flow;

    setUpAll(() {
      flow = _readCode('lib/player/player_flow_page.dart');
    });

    test('★ 必须优先用服务端 MarkerType（不是名称匹配）', () {
      // 实测：本服务器章节 MarkerType 为 Chapter, IntroStart, IntroEnd…
      // 名称匹配的失效场景：叫"主题曲"/"OP"识别不到；
      // 叫"片头曲欣赏"的普通章节会被误跳。
      expect(flow.contains('isIntroStart'), isTrue,
          reason: '★ 缺 IntroStart 判定 ⇒ 退化成猜测章节名，会误跳/漏跳');
      expect(flow.contains('isIntroEnd'), isTrue,
          reason: '★ 缺 IntroEnd 判定 ⇒ 拿不到准确结束时间，可能跳过头');
    });

    test('★ 自动跳过必须"一集只跳一次"（否则反复回跳）', () {
      // 位置是 250ms 推一次的 —— 不加这个门，进区间后会每 250ms 跳一次，
      // 表现为"画面反复向后跳"。
      expect(flow.contains('_introSkipped'), isTrue,
          reason: '★ 缺 _introSkipped 门 ⇒ 片头区间内每 250ms 跳一次');
      expect(flow.contains('if (intro == null || _introSkipped'), isTrue,
          reason: '★ 守卫条件不完整 —— 必须同时判 null 与已跳过');
    });

    test('★ 换集必须重置 _introSkipped（否则第 2 集不再跳）', () {
      // 只写"起播时置 true"而不在换集重置，是最容易漏的一半。
      //
      // ⚠️ 断言必须区分**声明处**与**方法体内那处** —— 二者文本相同
      //    （都是 `_introSkipped = false;`）。反向注入实测：只 `contains()`
      //    时删掉方法体那处仍全绿（声明还在）。
      //    故这里断言**方法体内那处的完整上下文**（紧邻 chunks 判定）。
      expect(
          flow.contains('_introSkipped = false;\n      if (launch.chapters'
              '.isNotEmpty) {'),
          isTrue,
          reason: '★ 换集没重置 ⇒ 只有第 1 集会跳片头（用户会以为坏了）。\n'
              '    断言必须带上下文：`_introSkipped = false;` 在声明处也出现，\n'
              '    裸串断言会被声明满足');
    });

    test('★ 自动跳过挂在 stateStream 上（不能挂在按钮里）', () {
      // 挂到"播放按钮"会漏掉手势、自动连播、媒体键等路径 ——
      // 而那些正是"换个片头"最常发生的时机。
      expect(flow.contains('_checkIntroSkip();'), isTrue,
          reason: '★ 没有调用点 ⇒ 自动跳过根本不会执行');
    });

    test('★ 浮钮必须在区间内才显示，且有 >=48dp 命中区', () {
      // ⚠️ 断言必须落在**判据条件本身**，不是 getter 名。
      //    反向注入实测：只断言 `contains('bool get shouldOfferIntroSkip')` 时，
      //    把首行判据改成 `if (false)`（浮钮永不显示）**仍全绿** ——
      //    getter 依然存在，只是永不返回 true。
      expect(flow.contains('bool get shouldOfferIntroSkip {'), isTrue,
          reason: '★ 缺显示判据 getter');
      expect(flow.contains('final intro = _intro;\n    if (intro == null) '
          'return false;'), isTrue,
          reason: '★ getter 内部必须真的判 `_intro == null`（恒 false 等于浮钮永不显示）');
      // 区间判定：位置必须落在 [start, end-1) 内
      expect(flow.contains('return pos >= intro.\$1 && pos < intro.\$2 - 1;'),
          isTrue,
          reason: '★ 区间判据被删/改恒假 ⇒ 浮钮永不出现');
      expect(flow.contains('_introSkipButton()'), isTrue,
          reason: '★ 浮钮没被挂进 Stack ⇒ 定义了也不会显示');
      // ⚠️ 上面这条同时被**定义处** `Widget _introSkipButton() {` 满足 ——
      //    删掉 Stack 里的**调用点**仍会全绿（反向注入实测）。
      //    故补断言调用点的完整上下文（缩进 + 逗号）。
      expect(flow.contains('            _introSkipButton(),'), isTrue,
          reason: '★ 只有定义、没有调用 ⇒ 浮钮永远不显示。\n'
              '    断言必须带缩进上下文：定义处 `Widget _introSkipButton() {`\n'
              '    会满足裸串断言（与 §8.4② 的前缀陷阱同型）');
      // 命中区：本仓库曾有 5 处 16x16 的裸 GestureDetector（UI-DESIGN §3.3.2）
      expect(flow.contains('EdgeInsets.symmetric(horizontal: 16, vertical: 14)'),
          isTrue,
          reason: '★ 命中区不足 48dp（14+14+内容 ≈48，不可再缩）');
      expect(flow.contains('child: InkWell('), isTrue,
          reason: '★ 用裸 GestureDetector 会没有涟漪反馈（§6.4.1）');
    });

    test('★ 偏好默认必须是"开"（与旧页一致）', () {
      // 旧页是 `autoIntro != '0'`（默认开）。
      // 若写成 `== '1'`，老用户升级后会**突然不再跳片头** —— 静默行为倒退。
      //
      // ⚠️ 断言必须**带上下文**（不能只 `contains("!= '0'")`）：
      //    本文件里 `!= '0'` 在别处也出现过（另一处偏好判据），
      //    用裸串断言时"把偏好改成 == '1'"这个注入仍会全绿 ——
      //    反向注入实测抓到了这个漏洞（7/13 → 修后见注入报告）。
      expect(flow.contains("getPref('skip_intro_auto')) != '0'"), isTrue,
          reason: "★ 判据必须是 `!= '0'`（默认开）—— 写成 `== '1'` 会让"
              '老用户升级后不再跳片头；且断言必须带 `getPref(...)` 上下文，'
              '否则别处的 `!= \'0\'` 会满足它');
      expect(flow.contains('bool _autoIntroSkip = true'), isTrue,
          reason: '★ 字段初值也必须是 true（读偏好前的默认行为）');
    });
  });

  group('★ 默认播放页必须是新页（P0 发布事故的守卫）', () {
    late String flow;
    late String routes;

    setUpAll(() {
      flow = _readCode('lib/player/player_flow_page.dart');
      routes = _readCode('lib/player/player_routes.dart');
    });

    test('★★ useNewPlayerUi 默认值必须是 true', () {
      // ## 这条守的是一个**真实发生过的发布事故**
      // 原先是 `defaultValue: false`，而发布链路（release.yml / ci.yml /
      // tool/build_apk.*）**都没传** `--dart-define=CF_NEW_PLAYER`
      // ⇒ 编译期常量折叠成 false ⇒ 新页被 tree-shaking 删掉 ⇒
      // **v0.3.2 发布包里是旧播放页**，
      // 双内核/会话层/HDR/WakeLock/音量系统通道**全没进用户手里**。
      //
      // 取证：对已发布 APK 的 `libapp.so` 扫 UTF-16LE 指纹 ——
      // 旧页 6/6 命中、新页 0/7。详见 docs/AUDIT-2026-10-09.md。
      //
      // ⇒ 若有人把默认值改回 false，**本测试必须变红**。
      //    （不能只靠"记得给 CI 传 flag"—— 那正是事故的成因）
      expect(
          flow.contains(
              "bool.fromEnvironment('CF_NEW_PLAYER', defaultValue: true);"),
          isTrue,
          reason: '★★ 默认值被改回 false ⇒ 不传 flag 的构建（含发布链路）'
              '会静默编入旧播放页，功能缺失但本地测试全绿。\n'
              '    这是 v0.3.2 发布事故的成因，绝不可回归。');
    });

    test('★ 路由必须按该开关分流（不能把它当死代码）', () {
      expect(routes.contains('if (useNewPlayerUi)'), isTrue,
          reason: '★ 开关没被路由使用 ⇒ 无论默认值如何都走旧页');
    });

    test('★ 旧页必须仍可回退（应急通道不能断）', () {
      // 保留回退能力是**有意的**：若线上发现新页阻塞缺陷，
      // 能一键回退而不必改代码-重新审查-再构建。
      //
      // ⚠️ 断言必须带**所属分支的上下文** —— `return PlayerPage(` 在本文件
      //    出现 **2 次**（另一次在 `_PlayerDeepLink._player` 里）。
      //    裸串断言时把 `playerRoute` 的回退分支换掉**仍全绿**
      //    （反向注入实测抓到）。故用 `PlayerRouteArgs` 那段完整参数块定位。
      expect(
          routes.contains('''if (extra is PlayerRouteArgs) {
          return PlayerPage(
            item: extra.item,
            episodes: extra.episodes,
            index: extra.index,
            mediaSourceId: extra.mediaSourceId,
          );
        }'''),
          isTrue,
          reason: '★ playerRoute 的旧页回退分支被删/改 ⇒ 失去应急回退通道\n'
              '    （新页出问题只能回滚整个版本）。\n'
              '    断言必须带参数块上下文：`return PlayerPage(` 在文件里有 2 处。');
    });
  });

  group('★ 与旧页的能力对齐（防"切默认页倒退"）', () {
    // ⚠️ 本组断言一律**带足够上下文**。
    //
    // 反向注入实测教训（AGENTS §8.4①）：最初这几条只写 `contains('_tapCount')`
    // / `contains('ui.isLocked')` —— 而这些串在文件里**各有 4 处**，
    // 删掉真正的实现后断言**仍然为真**（注入"删掉双击判定" → 测试全绿）。
    // 故改为断言**整行**（含左侧上下文），并落在"必然会变的那一行"。

    test('双击播放/暂停 必须在新页存在', () {
      // ⚠️ 这条是**修正一次误报**：上一轮审计声称"新页缺双击"，
      // 实际它一直在（`player_ui_page.dart`），只是我当时只 grep 了
      // `player_flow_page.dart` 一个文件、漏了 presentation 层。
      // 本测试固化"它必须存在"，避免真的被删掉。
      final ui = _readCode('lib/player/presentation/player_ui_page.dart');
      // 计数字段的**声明**（唯一）
      expect(ui.contains('int _tapCount = 0;'), isTrue,
          reason: '★ 单击/双击判定字段被删 ⇒ 双击播放/暂停失效');
      // 自增这一行（必然会变的那一行）
      expect(ui.contains('_tapCount++;'), isTrue,
          reason: '★ 第一次点击必须计数 —— 不计数则永远进不了双击分支');
      // 双击分支必须真的切播放状态
      expect(ui.contains('widget.callbacks.onTogglePlay();'), isTrue,
          reason: '★ 双击分支必须调 onTogglePlay（否则"双击没反应"）');
      // 判定窗口（原型 §9.4：250ms）
      expect(ui.contains('PlayerGestures.tapDelay'), isTrue,
          reason: '★ 双击窗口常量被删 ⇒ 判定立即失效');
    });

    test('锁屏按钮 必须在新页存在', () {
      // 同上：也是上一轮的误报，实际已有。
      final ui = _readCode('lib/player/presentation/player_ui_page.dart');
      // 图标**三元切换**整行（这一行是"锁定状态可见"的唯一实现点）
      expect(ui.contains('icon: ui.isLocked ? Icons.lock : Icons.lock_open,'),
          isTrue,
          reason: '★ 图标不再随锁定状态切换 ⇒ 用户看不出是否已锁');
      // 语义标签（无障碍 + 自动化测试定位用）
      expect(ui.contains("semanticLabel: ui.isLocked ? '解锁' : '锁定',"), isTrue,
          reason: '★ 语义标签被删 ⇒ 无障碍失效，且真机自动化点不到锁按钮');
      // 点击必须真的切状态
      expect(ui.contains('uiCtl.toggleLock()') || ui.contains('toggleLock()'),
          isTrue,
          reason: '★ 缺切换调用 ⇒ 点锁按钮没反应');
    });
  });
}
