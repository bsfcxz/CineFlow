// 分类浏览（稿子 180b4d）+ tgmeng 源 + 三项小改进的守卫测试。
//
// ## 为什么这些断言值得写
// 全是"错了不报错、只是静默空"的类型：
// · `with_origin_country` 用逗号（AND）⇒ 0 条，不会抛异常
// · tgmeng 的路径写错 ⇒ `code=666`，我按空处理 ⇒ 用户看到"没内容"
// · "展开全部"按钮不判长度 ⇒ 短简介点了没反应（假按钮）
// ⇒ 只有断言参数拼装与判据本身才能防回归。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String code(String path) {
  final src = File(path).readAsStringSync();
  // 剥注释：断言不得被注释满足（VERIFICATION-DISCIPLINE §1）
  final out = <String>[];
  for (final line in src.split('\n')) {
    final t = line.trim();
    if (t.startsWith('//') || t.startsWith('///') || t.startsWith('*')) {
      continue;
    }
    out.add(line);
  }
  return out.join('\n');
}

/// 剥掉**整行注释**（断言不得被注释满足 —— VERIFICATION-DISCIPLINE §1）。
///
/// ⚠️ `code()` 是"读文件 + 剥注释"二合一；全仓扫描时我已把文件内容读进来了
/// ⇒ 需要这个**纯函数**版本（对已有字符串剥注释）。
String stripComments(String text) => text.split('\n').where((l) {
      final t = l.trim();
      return !t.startsWith('//') && !t.startsWith('*');
    }).join('\n');

/// 取从 `from` 到 `to` 之间的源码切片（**用方法名作双锚**）。
///
/// ## 为什么不拍一个固定长度（实测教训）
/// 我第一版用 `substring(i, i + 3000)` 断言 `_fetchTgmeng` 的内容，
/// 但那个方法有 **5KB+** ⇒ 断言看不全 ⇒ **假失败**。
///
/// 第二版我试图用正则自动找"下一个方法定义" —— 也失败了：
/// 正则的 `String` / `Future<` 分支会命中方法体**内部**的行，
/// 把切片截断在中间（同样是假失败）。
///
/// ⇒ **最终做法**：调用方显式给出结束锚（下一个方法名）。
/// 这最笨但**不会错** —— AGENTS §8.4 第 1 类要求"窗口用下一个方法名作边界"。
String slice(String path, String from, String to) {
  final c = code(path);
  final i = c.indexOf(from);
  expect(i, greaterThan(0), reason: '$from 必须存在');
  final j = c.indexOf(to, i + from.length);
  expect(j, greaterThan(i), reason: '$to 必须出现在 $from 之后');
  return c.substring(i, j);
}

void main() {
  group('★★★ 分类浏览：类别与地区（稿子 180b4d）', () {
    test('★★★ 六个类别都在（剧集/电影/动漫/综艺/纪录片/儿童）', () {
      final c = code('lib/data/calendar_client.dart');
      for (final label in ['剧集', '电影', '动漫', '综艺', '纪录片', '儿童']) {
        expect(c.contains("'$label'"), isTrue,
            reason: '★★★ 稿子的 CATEGORIES 有 6 类，缺「$label」');
      }
    });

    test('★★★ 多值 genre 必须用 `|`（逗号是 AND ⇒ 0 条）', () {
      final c = code('lib/data/calendar_client.dart');
      // 综艺 = Reality(10764) | Talk(10767)
      // 实测：10764 → 8 条、10764,10767 → 1 条、10764|10767 → 8 条
      expect(c.contains('10764|10767'), isTrue,
          reason: '★★★ 用逗号会让"综艺"几乎为空（且不报错）');
      expect(c.contains('10764,10767'), isFalse,
          reason: '★★★ 逗号是 AND，是错误的写法');
    });

    test('★★★ 地区多值也必须用 `|`（同一个坑）', () {
      final c = code('lib/data/calendar_client.dart');
      // 港台 = HK|TW（逗号会要求"同时属于 HK 和 TW" ⇒ 0 条）
      expect(c.contains("c.join('|')"), isTrue,
          reason: '★★★ `with_origin_country` 与 `with_genres` 同一个坑');
    });

    test('★★★ 「国产/国漫」必须额外加 `with_original_language=zh`', () {
      final c = code('lib/data/calendar_client.dart');
      // 实测：只用 origin_country=CN 会混入合拍片/港剧
      //（"剧集/全部"第一条是《爱·回家之开心速递》，那是港剧）
      expect(c.contains('with_original_language'), isTrue,
          reason: '★★★ 不加会混入非国产内容');
      expect(c.contains('forceChinese'), isTrue,
          reason: '★ 用显式开关表达，而不是散落的 if');
    });

    test('★★ 参数用 Map（不是字符串拼接）', () {
      final c = code('lib/data/calendar_client.dart');
      // 我上一版在 Python 里拼 query 时用三元表达式造出**重复的 sort_by**
      // ⇒ TMDB 全回 400（且不说是哪个参数）。Dart 侧用 Map 天然不会重复。
      expect(c.contains('queryParameters: params'), isTrue,
          reason: '★★ 用 Map 拼参数才不会出现重复键');
      expect(c.contains('<String, dynamic>{'), isTrue);
    });

    test('★★ 六类各自的地区列表要与稿子一致', () {
      final c = code('lib/data/calendar_client.dart');
      // 动漫用「国漫/日番」（动漫圈的叫法），不是「国产/日韩」
      expect(c.contains('国漫'), isTrue, reason: '★★ 动画地区名与稿子一致');
      expect(c.contains('日番'), isTrue);
      // 剧集/电影有港台
      expect(c.contains('港台'), isTrue);
    });

    test('★★ 类别的 kind 要区分 tv / movie（TMDB 两个命名空间）', () {
      final c = code('lib/data/calendar_client.dart');
      expect(c.contains("'movie'"), isTrue,
          reason: '★★ 电影走 discover/movie，其余走 discover/tv');
      expect(c.contains("'tv'"), isTrue);
    });

    test('★★ 浏览结果不要伪造 weekday', () {
      // 浏览面板没有"周几更新"语义；硬塞会让"按周几"排序把它算错
      // 双锚：下一个方法名作边界（不拍长度）
      final seg = slice('lib/data/calendar_client.dart',
          'Future<List<CalendarEntry>> fetchBrowse',
          'CalendarCategory _categoryOfBrowse');
      expect(seg.contains('weekday: null'), isTrue,
          reason: '★★ 浏览条目必须留 null weekday（不冒充"今天更新"）');
    });
  });

  group('★★★ 详情页 UI 规格（用户逐条给出，必须守住）', () {
    test('★★★ 状态/平台标签必须是**公共组件**（两处共用，不能各写一套）', () {
      // ## 真实教训
      // 用户 2026-10-12："上面这些我给你的 ui 设计你没有遵守哇"。
      // 根因：我把 `_StatusTag` / `_PlatformTag` 写成详情页的**私有类**，
      // 首页 hero 只能自己另写灰色 chip ⇒ 同一个 App 两套标签样式。
      final t = code('lib/widgets/media_tags.dart');
      expect(t.contains('class CfStatusTag'), isTrue,
          reason: '★★★ 公共状态标签');
      expect(t.contains('class CfPlatformTag'), isTrue,
          reason: '★★★ 公共平台标签');
      // 详情页与首页都必须 import 它
      for (final f in ['lib/widgets/calendar_detail_sheet.dart',
                       'lib/pages/home_page.dart']) {
        final c = code(f);
        expect(c.contains("import 'media_tags.dart'") ||
            c.contains('widgets/media_tags.dart'), isTrue,
            reason: '★★★ $f 必须用公共组件（不能各写一套）');
      }
      // 详情页不该再有私有版本
      final d = code('lib/widgets/calendar_detail_sheet.dart');
      expect(d.contains('class _StatusTag'), isFalse,
          reason: '★★★ 私有版本已删（否则会与公共组件漂移）');
      expect(d.contains('class _PlatformTag'), isFalse);
    });

    test('★★★ 状态三色 + 连载中闪烁（用户规格）', () {
      final c = code('lib/widgets/media_tags.dart');
      // 连载中绿 / 已完结灰 / 已上映橙（稿子的三对色）
      expect(c.contains('0xFF22C55E'), isTrue, reason: '★★ 连载中绿');
      expect(c.contains('0xFF64748B'), isTrue, reason: '★★ 已完结灰');
      expect(c.contains('0xFFF59E0B'), isTrue, reason: '★★ 已上映橙');
      // 闪烁必须真的动（用户："闪烁点（动态）"）
      expect(c.contains('AnimationController'), isTrue,
          reason: '★★★ 静态点不算"闪烁（动态）"');
      expect(c.contains('_c.repeat()'), isTrue);
    });

    test('★★★ 平台品牌色（腾讯蓝/爱奇艺绿/优酷青/芒果橙/B站粉/Netflix红）', () {
      final c = code('lib/widgets/media_tags.dart');
      for (final name in ['腾讯', '爱奇艺', '优酷', '芒果', 'B站', 'Netflix']) {
        expect(c.contains("'$name'"), isTrue, reason: '★★ 缺平台 $name');
      }
      // ⚠️ 未收录的平台必须用中性灰（**不编造品牌色**）
      expect(c.contains('0xFF475569'), isTrue,
          reason: '★ 兜底色（编造品牌色会误导用户）');
    });

    test('★★★ 电影：隐藏"下次更新"与"选集"（用户规格表）', () {
      final c = code('lib/widgets/calendar_detail_sheet.dart');
      expect(c.contains('final isMovie ='), isTrue);
      expect(c.contains('if (!isMovie)'), isTrue,
          reason: '★★★ 电影要隐藏下次更新与选集');
      // 信息栏是**全类型显示**（用户规格：信息栏一列全是"全"）
      expect(c.contains('_InfoSection('), isTrue);
    });

    test('★★★ 两个操作按钮**等宽**（用户："大小可以优化一下，很突兀"）', () {
      final seg = slice('lib/widgets/calendar_detail_sheet.dart',
          'class _ActionRow', 'class _NextUpdate');
      // 稿子 `.btn-primary` 与 `.btn-secondary` 都是 `flex: 1` ⇒ 两个 Expanded
      final n = RegExp(r'Expanded\(').allMatches(seg).length;
      expect(n, greaterThanOrEqualTo(2),
          reason: '★★★ 两个按钮都要 Expanded（等宽）——\n'
              '    我第一版一个 Expanded 一个按内容挤 ⇒ 一大一小很突兀');
      // 高度 46 + 圆角用令牌（稿子 .btn-primary { height:46px; border-radius:12px }）
      expect(seg.contains('46'), isTrue, reason: '★ 稿子高度 46');
      expect(seg.contains('Cf.radiusMd'), isTrue, reason: '★ 稿子圆角 12');
    });

    test('★★★ 选集默认 3 行 + 展开全部（用户要求"和简介一样"）', () {
      final c = code('lib/widgets/calendar_detail_sheet.dart');
      expect(c.contains('_collapsedRows = 3'), isTrue,
          reason: '★★★ 用户："选集也整成和简介一样只展示3行"');
      expect(c.contains('_epExpanded'), isTrue,
          reason: '★★ 要有展开状态');
      expect(c.contains("'展开全部（共 \$total 集）'"), isTrue);
      // ⚠️ 展开也要有上限（2868 集不能真铺 717 行）
      expect(c.contains('_expandedMax'), isTrue,
          reason: '★★ 展开上限（防止超长剧集卡顿）');
    });

    test('★★ 简介与选集都不留假按钮（只在真被截断时显示）', () {
      final c = code('lib/widgets/calendar_detail_sheet.dart');
      expect(c.contains('offerExpand'), isTrue,
          reason: '★★ 短内容不该显示"展开全部"（点了没反应）');
      expect(c.contains('_shouldOfferExpand'), isTrue);
    });

    test('★★★ 首页 hero 的 meta 行用同一套标签（不能再是灰 chip）', () {
      // 边界用**后面**的类（_Slide 在 _Carousel 之后）
      final seg = slice('lib/pages/home_page.dart', 'class _Slide',
          'class _CategoryBrowseSection');
      expect(seg.contains('CfStatusTag('), isTrue,
          reason: '★★★ 首页 hero 也要状态标签（用户指出过）');
      expect(seg.contains('CfScoreText('), isTrue,
          reason: '★★ 评分用金色（稿子 .score 是 #f5c518）');
      // 旧的灰 chip 写法必须消失
      expect(seg.contains("'⭐ "), isFalse,
          reason: '★★ 旧的灰色 ⭐ 已被 CfScoreText 取代');
    });

    test('★★ 首页 section 标题按稿子（点击查看全部 / 最近更新 · 新入库）', () {
      final c = code('lib/pages/home_page.dart');
      expect(c.contains("trailing: '点击查看全部 ›'"), isTrue,
          reason: '★★ 稿子：<h2>分类浏览 <em>点击查看全部</em></h2>');
      expect(c.contains("title: '最近更新'"), isTrue,
          reason: '★★ 稿子：<h2>最近更新 <em>新入库 / 新集数</em></h2>');
      expect(c.contains("trailing: '新入库 / 新集数'"), isTrue);
    });
  });

  group('★★★ 两处详情页的按钮必须同一套（用户两次报"追剧按钮没了"）', () {
    test('★★★ 两个详情页都要有"两个等宽按钮"（播放 + 追剧）', () {
      // ## 真实教训
      // 我改了日历详情页的按钮，但 Emby 详情页还是"圆形星标图标
      // + 占满整行的主按钮" ⇒ 用户看到的就是"没有追剧按钮"
      //（那颗圆星上**没有"追剧"两个字**）。
      for (final f in ['lib/pages/detail_page.dart',
                       'lib/widgets/calendar_detail_sheet.dart']) {
        final c = code(f);
        expect(c.contains("'追剧'"), isTrue,
            reason: '★★★ $f 必须有带"追剧"字样的按钮');
        expect(c.contains("'已追'"), isTrue,
            reason: '★★★ $f 必须支持已追态');
        // 高度 46 + 圆角 radiusMd（稿子 .btn-primary/.btn-secondary）
        expect(c.contains('46'), isTrue,
            reason: '★★ $f 按钮高度按稿子 46');
      }
    });

    test('★★★ Emby 详情页不再是"圆形星标图标"（那是造成误认的根因）', () {
      final c = code('lib/pages/detail_page.dart');
      // `_roundBtn` 是旧的 38×38 圆形按钮 —— 已删
      expect(c.contains('_roundBtn'), isFalse,
          reason: '★★★ 圆形图标不像按钮（用户看不出那是追剧）');
      // ⚠️ 断言范围必须**限定在按钮行**，不能全文搜 `BoxShape.circle` ——
      //    演职员的圆形头像（62×62）合法地用了它
      //    （我第一版全文搜，把头像误判成按钮 ⇒ 假失败）。
      final btn = slice('lib/pages/detail_page.dart',
          'Widget _actionButtons', '_hdTags');
      expect(btn.contains('BoxShape.circle'), isFalse,
          reason: '★ 按钮不该是圆形（稿子是圆角矩形）');
    });

    test('★★★ Emby 详情页的追剧 = 本地订阅 + Emby 收藏（写两边）', () {
      final c = code('lib/pages/detail_page.dart');
      expect(c.contains('toggleCalendarSubscription('), isTrue,
          reason: '★★★ 写本地订阅表');
      expect(c.contains('toggleFavorite('), isTrue,
          reason: '★★★ 同步 Emby 收藏（用户："这个会同步的"）');
      // 顺序：先本地后服务端（服务器不可达时本地仍要成功）
      final iLocal = c.indexOf('toggleCalendarSubscription(');
      final iServer = c.indexOf('toggleFavorite(');
      expect(iLocal, lessThan(iServer),
          reason: '★★ 先写本地（主行为）再同步服务端');
    });

    test('★★ 预告片功能没被按钮改造顺手砍掉', () {
      final c = code('lib/pages/detail_page.dart');
      // ⚠️ 我覆盖按钮行时把 TrailerButton 一起删了 ——
      //    那是**已交付的功能**，砍掉比没做更糟。
      expect(c.contains('TrailerButton('), isTrue,
          reason: '★★ 预告片是已实现功能，不能顺手删');
    });

    // ✅ 已实现（2026-10-12）。
    //
    // 历史：我第一版写成 `skip: '待实现…'` 保住待办（不写会遗忘、
    // 直接断言会常红被当噪音）。实现后**取消 skip** —— 现在它是真守卫。
    test('★★★ 豆瓣排行榜的详情也需要订阅入口（用户要求）', () {
      final c = code('lib/widgets/douban_detail_sheet.dart');
      expect(c.contains('追剧') || c.contains('toggleCalendarSubscription'),
          isTrue,
          reason: '★★★ 用户明确要求豆瓣排行榜也有订阅按钮');
    });
  });

  group('★★★ 订阅流程：先搜本地库，命中才写（用户明确要求）', () {
    test('★★★ 未入库时**什么都不写**（否则「我的追剧」会有播不了的剧）', () {
      // 用户原话：
      // > "先搜索本地库是否有，存在的话直接从 emby 服务端收藏 = 订阅，
      // >  没有的话提示，订阅暂未入库。"
      final seg = slice('lib/state/providers.dart',
          'Future<SubscribeResult> subscribeExternal',
          'CalendarCategory _categoryFor(');
      // 未命中就 return（**在写任何东西之前**）
      expect(seg.contains('SubscribeOutcome.notInLibrary'), isTrue,
          reason: '★★★ 要有"未入库"分支');
      //
      // ⚠️ 断言方式（我第一版写错过，记录在此）：
      //    原写法 `expect(seg.indexOf('notInLibrary'),
      //                  lessThan(seg.indexOf('toggleCalendarSubscription')))`
      //    在我加了 `unsubscribe` 取消分支后**失效** ——
      //    取消分支合法地**靠前**调用了 `toggleCalendarSubscription`，
      //    于是 `indexOf` 找到的是**取消**那次，不是"命中后写入"那次。
      //    ⇒ 断言退化成"验证巧合"。
      //
      //    **正确做法**：从"未命中 return"的位置**往后**找写入
      //    （即验证"未命中之后才有写入"，这才是我要守的语义）。
      final iSearch = seg.indexOf('aggregatedSearchProvider');
      final iNotFound = seg.indexOf('SubscribeOutcome.notInLibrary');
      final iWrite = seg.indexOf('toggleCalendarSubscription', iNotFound);
      expect(iSearch, greaterThan(-1), reason: '★★ 要先搜库');
      expect(iNotFound, greaterThan(iSearch),
          reason: '★★★ 搜库之后才判断"未命中"');
      expect(iWrite, greaterThan(iNotFound),
          reason: '★★★ 写入必须在"未命中 return"**之后**\n'
              '    （否则库里没有的剧也会进「我的追剧」，点进去"找不到"）');
    });

    test('★★★ 命中后要写两边：本地订阅表 + Emby 收藏', () {
      final seg = slice('lib/state/providers.dart',
          'Future<SubscribeResult> subscribeExternal',
          'CalendarCategory _categoryFor(');
      expect(seg.contains('toggleCalendarSubscription'), isTrue,
          reason: '★★★ 写本地订阅表（首页「我的追剧」/ 追剧日历共用）');
      expect(seg.contains('toggleFavorite'), isTrue,
          reason: '★★★ 写 Emby 收藏（用户："= emby 服务端的收藏，这个会同步的"）');
      // 顺序：先本地后服务端（服务器不可达时本地仍要成功）
      expect(seg.indexOf('toggleCalendarSubscription'),
          lessThan(seg.indexOf('toggleFavorite')),
          reason: '★★ 先本地（主行为）再服务端');
    });

    test('★★★ 四种结果都要有 UI 提示（用户要"提示"而非静默）', () {
      final c = code('lib/widgets/douban_detail_sheet.dart');
      // 未入库必须**明确提示**（用户要求"提示，订阅暂未入库"）
      expect(c.contains('订阅暂未入库'), isTrue,
          reason: '★★★ 用户明确要求这句提示');
      expect(c.contains('已加入追剧'), isTrue);
      expect(c.contains('操作失败'), isTrue);
    });

    test('★★ 豆瓣详情页的订阅按钮与其它两处同规格（等宽 46）', () {
      final c = code('lib/widgets/douban_detail_sheet.dart');
      expect(c.contains("'追剧'"), isTrue, reason: '★★ 带字样的按钮');
      expect(c.contains('46'), isTrue, reason: '★ 稿子高度 46');
      expect(c.contains('Cf.radiusMd'), isTrue, reason: '★ 稿子圆角 12');
    });

    test('★★ 订阅走**聚合搜索**（多台服务器都要搜）', () {
      final c = code('lib/state/providers.dart');
      expect(c.contains('aggregatedSearchProvider'), isTrue,
          reason: '★★ 用户有多台服务器 ⇒ 只搜一台会误报"未入库"');
    });
  });

  group('★★★ 异步 provider 禁止读 .value（本轮真 bug）', () {
    test('★★★ `_loadAll` 必须 await `subscriptionsProvider.future`', () {
      // ## 用户报障
      // > "追剧这个底栏中的内容怎么没有了"
      //
      // ## 根因
      // ```dart
      // final subs = ref.read(subscriptionsProvider).value ?? const [];
      // ```
      // `subscriptionsProvider` 是 **FutureProvider**（异步查 drift），
      // 而 `_loadAll` 在 `addPostFrameCallback` 里跑 ⇒ 那一刻查询还没回来
      // ⇒ `.value` 是 null ⇒ `?? const []` ⇒ **直接 return**。
      // ⇒ `_weeks`/`_progress` 永远空 ⇒ 周历恒 0、列表恒空。
      //
      // ## 为什么统计卡看着正常（掩盖了 bug）
      // 统计卡走 `build` 里的 `ref.watch(...)`（会等、会重建）；
      // 而这里用 `ref.read`（一次性、不等）⇒ **两条路径不一致**。
      final c = code('lib/pages/tracking_page.dart');
      expect(c.contains('await ref.read(subscriptionsProvider.future)'), isTrue,
          reason: '★★★ 必须等 Future 完成');
      expect(c.contains('ref.read(subscriptionsProvider).value'), isFalse,
          reason: '★★★ 这是那个 bug 的写法');
    });

    test('★★★ 弹幕配置必须 await（否则用户配置被显示成默认值）', () {
      // `danmakuConfigProvider` 是 AsyncNotifierProvider（异步读 secure_storage）
      // ⇒ 读 `.value` 未就绪时是 null ⇒ `?? 默认值` ⇒
      //   **设置页把用户已保存的配置显示成默认**（保存后会真覆盖回去）。
      final c = code('lib/danmaku/danmaku_settings_page.dart');
      expect(c.contains('await ref.read(danmakuConfigProvider.future)'), isTrue,
          reason: '★★★ _save 里必须等（否则 kind 判错、走错分支）');
      // initState 不能 await ⇒ 用"先空后回填"
      expect(c.contains('danmakuConfigProvider.future).then'), isTrue,
          reason: '★★ initState 用 then 回填（不能 await）');
    });

    test('★★★ 播放器加载弹幕必须 await（否则静默不加载）', () {
      final c = code('lib/player/player_page.dart');
      expect(c.contains('await ref.read(danmakuConfigProvider.future)'), isTrue,
          reason: '★★★ `.value` 为 null 会 return ⇒ 用户以为"这片没弹幕"');
    });

    test('★★ 全仓不得再有"在异步 provider 上 read(...).value"', () {
      // 扫描 lib/ 全部 dart（**排除注释**，避免被说明文字误伤）
      final dir = Directory('lib');
      final bad = <String>[];
      final asyncProvs = [
        'subscriptionsProvider', 'subscribedKeysProvider',
        'calendarWeekProvider', 'homeProvider', 'accountsProvider',
        'accountApisProvider', 'sessionProvider', 'hotBoardProvider',
        'hotHeroProvider', 'doubanRankingsProvider', 'doubanDetailProvider',
      ];
      for (final f in dir.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = stripComments(f.readAsStringSync()).split('\n');
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          for (final pv in asyncProvs) {
            if (l.contains('ref.read($pv)') && l.contains('.value')) {
              bad.add('${f.path}:${i + 1}');
            }
          }
        }
      }
      expect(bad, isEmpty,
          reason: '★★★ 异步 provider 上读 .value 拿到的是 null（未就绪），\n'
              '    `?? 默认值` 会把"还没加载"伪装成"空结果" ⇒ **静默失效**。\n'
              '    请用 `await ref.read(p.future)`。越界处：\n${bad.join('\n')}');
    });
  });

  group('★★★ 「热播」Tab（用户：豆瓣保持现状 + 新增 TMDB）', () {
    test('★★★ 底栏是「热播」而非「排行榜」', () {
      final c = code('lib/pages/home_shell.dart');
      expect(c.contains("'热播'"), isTrue,
          reason: '★★★ 用户 2026-10-12："底栏排行榜改为热播"');
      expect(c.contains("'排行榜'"), isFalse,
          reason: '★★★ 旧名不该残留');
    });

    test('★★★ 两个来源都在（豆瓣保持现状 + TMDB 新增）', () {
      final c = code('lib/pages/rank_page.dart');
      // 用户："豆瓣的还是保持现状分类…新增一个 tmdb 的"
      expect(c.contains('enum _Source'), isTrue, reason: '★★★ 来源切换');
      expect(c.contains("douban('豆瓣')"), isTrue);
      expect(c.contains("tmdb('TMDB')"), isTrue);
      // 豆瓣那栏仍走 DoubanGroup + DoubanCatalog（**没被改动**）
      expect(c.contains('DoubanGroup.values'), isTrue,
          reason: '★★★ 豆瓣分类保持现状（三组）');
      expect(c.contains('DoubanCatalog.categories'), isTrue,
          reason: '★★★ 豆瓣的 20 个榜单原样');
      // TMDB 那栏走 hotBoardProvider
      expect(c.contains('hotBoardProvider'), isTrue);
    });

    test('★★★ 电影与剧集的状态榜单**必须不同**（真实差异）', () {
      final c = code('lib/pages/rank_page.dart');
      // 电影没有"在播/完结"（TMDB 的 with_status 是剧集专有）
      // ⇒ 电影只能 [正在上映][即将上映]
      expect(c.contains('_boardsFor'), isTrue, reason: '★★★ 榜单按类别区分');
      expect(c.contains('HotBoard.showing'), isTrue, reason: '★ 电影的"正在上映"');
      expect(c.contains('HotBoard.recentEnded'), isTrue,
          reason: '★ 剧集的"刚完结"');
    });

    test('★★ TMDB 栏的 hotBoardProvider 要按 (类别, 状态) 缓存', () {
      final c = code('lib/state/providers.dart');
      expect(c.contains('hotBoardProvider'), isTrue);
      // family 键是 (BrowseCategory, HotBoard) record
      expect(c.contains('(BrowseCategory, HotBoard)'), isTrue,
          reason: '★★ 两个维度都要进键，否则切状态拿到旧数据');
    });
  });

  group('★★★ 追剧页按稿子重做（用户截图指出"没按 UI 改"）', () {
    test('★★★ 三个统计卡（连载中/已完结/继续观看）', () {
      final c = code('lib/pages/tracking_page.dart');
      // 稿子 `.top-seg-btn` × 3
      expect(c.contains('class _StatCard'), isTrue,
          reason: '★★★ 稿子的统计卡（旧实现只有一行文字）');
      expect(c.contains('enum _StatKind'), isTrue);
      for (final k in ["'连载中'", "'已完结'", "'继续观看'"]) {
        expect(c.contains(k), isTrue, reason: '★★ 缺统计卡 $k');
      }
      expect(c.contains('_StatKind.cont'), isTrue);
    });

    test('★★★ 统计卡的圆点三色（稿子 .live/.end/.cont）', () {
      final c = code('lib/pages/tracking_page.dart');
      expect(c.contains('0xFF22C55E'), isTrue, reason: '★ live 绿');
      expect(c.contains('0xFF64748B'), isTrue, reason: '★ end 灰');
      // cont 用主题色（粉）
      expect(c.contains('_StatKind.cont => (Cf.accent'), isTrue);
    });

    test('★★★ 周历每格显示**集数数字**（稿子 .wd-count）', () {
      final c = code('lib/pages/tracking_page.dart');
      // ⚠️ 锚点**不能是注释** —— code() 会剥注释（我踩过两次）。
      //    用**代码锚**：稿子 .wd-count 渲染的是数字（不是小红点）。
      expect(c.contains('countOn(wd)'), isTrue,
          reason: '★★★ 稿子用 countOn(wd) 取该天更新数');
      expect(c.contains('fontWeight: FontWeight.w800'),
          isTrue, reason: '★ 数字用粗体（稿子 .wd-count 视觉权重高）');
      // 旧的小红点（danger 色的圆点）必须已消失
      expect(c.contains('Cf.danger,\n                            shape'), isFalse,
          reason: '★★ 小红点写法应已删除');
      expect(
          c.contains('color: on ? Cf.ink : Cf.danger'), isFalse,
          reason: '★★ 小红点的颜色表达式应已删除');
    });

    test('★★ 三个统计卡是**按状态过滤**同一份数据（不是三套列表）', () {
      final c = code('lib/pages/tracking_page.dart');
      expect(c.contains('enum _Only'), isTrue);
      expect(c.contains('widget.only == _Only.live'), isTrue,
          reason: '★★ 过滤而不是各写一套（避免漂移）');
    });

    test('★★★ 标题 26px 用**令牌**（不是裸值）', () {
      final t = code('lib/core/theme.dart');
      expect(t.contains('static final headline = TextStyle('), isTrue,
          reason: '★★★ 稿子 `.track-title { font-size:26px }` ⇒ 加令牌');
      final c = code('lib/pages/tracking_page.dart');
      expect(c.contains('Cf.headline'), isTrue, reason: '★★ 页面用令牌');
    });
  });

  group('★★★ 三处详情页的订阅都走"先搜库"（用户明确要求）', () {
    test('★★★ 日历/TMDB 详情页也走 subscribeExternal（不再直接写）', () {
      // ## 为什么这条重要
      // 原来日历详情页**直接** `toggleCalendarSubscription`
      // ⇒ 库里**没有**的剧也能订阅 ⇒ 首页「我的追剧」点进去"找不到"。
      // 用户要求："先搜索本地库是否有…没有的话提示，订阅暂未入库。"
      final c = code('lib/widgets/calendar_detail_sheet.dart');
      expect(c.contains('subscribeExternal('), isTrue,
          reason: '★★★ 必须走公共订阅函数（内含"先搜库"）');
      // 取消路径不搜库（`unsubscribe: wasFollowing`）
      expect(c.contains('unsubscribe:'), isTrue,
          reason: '★★ 已追的必须能取消（取消不需要先搜库）');
      // 未入库要回滚乐观更新（按钮不能停在"已追"）
      expect(c.contains('SubscribeOutcome.notInLibrary'), isTrue);
    });

    test('★★★ 三处详情页都用同一个订阅函数（不能各写一套）', () {
      // 用户两次报"按钮没了/样式不一样"的根因就是"各写一套"。
      // ⇒ 订阅逻辑同理：三处都必须走 `subscribeExternal`。
      for (final f in ['lib/pages/detail_page.dart',
                       'lib/widgets/calendar_detail_sheet.dart',
                       'lib/widgets/douban_detail_sheet.dart']) {
        final c = code(f);
        final uses = c.contains('subscribeExternal(');
        // Emby 详情页走的是"本地订阅 + toggleFavorite"（条目已在库里，
        // 无需搜库）；豆瓣与日历页走 subscribeExternal。
        final isEmbyPage = f.contains('detail_page.dart');
        expect(uses || isEmbyPage, isTrue,
            reason: '★★★ $f 必须走统一订阅路径');
      }
    });

    test('★★ 取消订阅不搜库（否则用户会卡在"已追")', () {
      final seg = slice('lib/state/providers.dart',
          'Future<SubscribeResult> subscribeExternal',
          'CalendarCategory _categoryFor(');
      expect(seg.contains('unsubscribe'), isTrue,
          reason: '★★ 要有取消开关');
      // 取消分支必须在"搜库"之前
      final iCancel = seg.indexOf('if (unsubscribe');
      final iSearch = seg.indexOf('aggregatedSearchProvider');
      expect(iCancel, lessThan(iSearch),
          reason: '★★ 取消要在搜库**之前**返回（不然库里没有就取消不了）');
    });
  });

  group('★★★ 平台标签的服务端数据链（用户："先从服务端获取"）', () {
    test('★★★ getLatest 必须请求 Studios 字段', () {
      // ## 真实缺口
      // 首页 hero 一直没有平台标签。我误判成"MediaItem 不带 Studios"，
      // 实际是 `Fields` **没请求它** —— 字段与服务端都支持。
      //
      // 实测（2026-10-12，两台服务器）：
      //   /Items/Latest?Fields=...Studios  填充率 **88% / 92%**
      //   内容就是播出平台：兰香如故→Tencent Video / 蒸蒸日上→iQiyi
      final seg = slice('lib/data/emby_provider.dart',
          'Future<List<MediaItem>> getLatest', 'Future<List<MediaItem>> getResume');
      expect(seg.contains('Studios'), isTrue,
          reason: '★★★ 不请求该字段 ⇒ 首页 hero 永远没有平台标签');
    });

    test('★★★ MediaItem 必须解析 Studios（防御式）', () {
      final c = code('lib/data/models.dart');
      // 找 MediaItem 类（不是 MediaItemDetail）
      final i = c.indexOf('class MediaItem {');
      final j = c.indexOf('class MediaItemDetail');
      expect(i, greaterThan(0));
      expect(j, greaterThan(i));
      final item = c.substring(i, j);
      expect(item.contains('final List<String> studios'), isTrue,
          reason: '★★★ 列表项也要有 studios（首页 hero 用它）');
      expect(item.contains("j['Studios']"), isTrue);
      // ⚠️ 防御式：AGENTS §5.3 不允许对服务器字段做非空断言
      expect(item.contains('whereType<Map<String, dynamic>>'), isTrue,
          reason: '★★ 一条脏数据不该炸掉整个列表');
    });

    test('★★★ 首页 hero 用服务端平台名 + 中文映射', () {
      final seg = slice('lib/pages/home_page.dart', 'class _Slide',
          'class _CategoryBrowseSection');
      expect(seg.contains('item.studios'), isTrue,
          reason: '★★★ 从服务端取');
      expect(seg.contains('CalendarClient.cnPlatformName'), isTrue,
          reason: '★★★ 服务端给的是英文（Tencent Video）⇒ 要转中文');
      expect(seg.contains('CfPlatformTag('), isTrue,
          reason: '★★★ 用公共平台标签组件（品牌色）');
    });

    test('★★ 中文映射是 static（无需实例，可直接调）', () {
      final c = code('lib/data/calendar_client.dart');
      // ⚠️ 我一度试图把它"抽成顶层函数"，其实它本来就是 static
      //    ⇒ 直接 `CalendarClient.cnPlatformName(...)` 即可。
      expect(c.contains('static String cnPlatformName('), isTrue,
          reason: '★ 是 static ⇒ 首页无需 new 一个 CalendarClient');
    });
  });

  group('★★★ 分类浏览的竞态与超时（真机暴露的真实缺陷）', () {
    test('★★★ 缓存键必须在 await **之前**固定（不是用 getter）', () {
      // ## 真实 bug（真机截图暴露）
      // 原实现：
      //   String get _key => '${_cat.name}:${_region.label}';   // 读当前状态
      //   ...
      //   await fetchBrowse(category: _cat, ...);
      //   _cache[_key] = list;   // ← await **之后**求值 = **新**类别
      // ⇒ 请求飞行中切类别 + 返回顺序颠倒 ⇒
      //   **旧类别的数据被写进新类别的缓存键**（缓存污染且不自愈）
      final seg = slice('lib/pages/browse_page.dart',
          'Future<void> _load()', 'void _pick(');
      expect(seg.contains('final tag = _key;'), isTrue,
          reason: '★★★ 必须在发起前固定 key');
      expect(seg.contains('_cache[tag] = list;'), isTrue,
          reason: '★★★ 写缓存要用固定的 tag，不是 `_key`（getter）');
      expect(seg.contains('_cache[_key] = list;'), isFalse,
          reason: '★★★ 这就是那个 bug 的写法');
    });

    test('★★★ 过期响应必须被丢弃（请求序号）', () {
      final seg = slice('lib/pages/browse_page.dart',
          'Future<void> _load()', 'void _pick(');
      // 领号 → 每个 await 后校验 → 过期就 return
      expect(seg.contains('++_reqId'), isTrue,
          reason: '★★★ 要有请求序号');
      expect(seg.contains('myReq != _reqId'), isTrue,
          reason: '★★★ 每个 await 之后都要校验，否则旧响应会覆盖新状态');
      // 至少要校验两次（loadTmdbKey 之后、fetchBrowse 之后）
      expect(RegExp(r'myReq != _reqId').allMatches(seg).length,
          greaterThanOrEqualTo(2),
          reason: '★★ 两处 await 都要校验');
    });

    test('★★★ 网络请求必须有超时（否则无限转圈）', () {
      // 真机截图：切到「综艺」后 spinner 一直转，而同一次运行的日历页
      // 已明确报 "TMDB 国产剧集…暂不可用" ⇒ TMDB 此刻不稳定。
      // dio **默认不超时** ⇒ 请求挂住 = spinner 永远转 = 用户无法自救。
      final seg = slice('lib/data/calendar_client.dart',
          'Future<List<CalendarEntry>> fetchBrowse', 'CalendarCategory _categoryOfBrowse');
      expect(seg.contains('receiveTimeout'), isTrue,
          reason: '★★★ 没超时会让 spinner 永远转（且无任何提示）');
      expect(seg.contains('sendTimeout'), isTrue);
    });

    test('★★ 失败要说清是失败（不是伪装成空）', () {
      // AGENTS §7.8：不许把「加载失败」伪装成「暂无内容」
      final c = code('lib/pages/browse_page.dart');
      expect(c.contains('String? _error'), isTrue,
          reason: '★★ 要有错误态字段');
      expect(c.contains("'重试'"), isTrue,
          reason: '★★ 错误态要给可行动的出口');
      expect(c.contains('未填 TMDB API Key'), isTrue,
          reason: '★★ 最常见的失败原因要明确说出来');
    });
  });

  group('★★★ tgmeng 源（用户要求接入的公益 API）', () {
    test('★★★ 域名必须是 trendapi（api.tgmeng.com 全部超时）', () {
      final c = code('lib/data/calendar_client.dart');
      expect(c.contains('trendapi.tgmeng.com'), isTrue,
          reason: '★★★ 实测 api.tgmeng.com 全超时；真域名是 trendapi');
      expect(c.contains("'https://api.tgmeng.com"), isFalse,
          reason: '★★★ 那个域名调不通');
    });

    test('★★★ 8 个实测有数据的端点都要在', () {
      final c = code('lib/data/calendar_client.dart');
      for (final p in [
        'youku/dianshiju', 'aiqiyi/dianshiju', 'aiqiyi/zongyi',
        'aiqiyi/dongman', 'mangguo/dianshiju', 'cctv/8',
        'baidu/duanju', 'dianshimao',
      ]) {
        expect(c.contains(p), isTrue, reason: '★★★ 缺端点 $p');
      }
    });

    test('★★★ 不能收录腾讯视频的剧集端点（实测全空）', () {
      // ⚠️ 断言必须落在**端点列表**上，不能全文搜 "tencent" ——
      //    注释里解释"为什么不收腾讯"是**应该**存在的
      //    （我第一版全文搜 `'tencent'` ⇒ 被注释满足 ⇒ 假失败）。
      //    这是 §8.4 第 1 类"断言不得被注释满足"的变体。
      final c = code('lib/data/calendar_client.dart');
      final i = c.indexOf('const endpoints = <');
      expect(i, greaterThan(0), reason: '端点是常量列表');
      final j = c.indexOf('];', i);
      expect(j, greaterThan(i));
      final list = c.substring(i, j);
      expect(list.contains('tencent'), isFalse,
          reason: '★★★ 腾讯的 5 个端点实测全空（上游未抓）');
      expect(list.contains('youku/dianshiju'), isTrue,
          reason: '★ 反向确认我切到的确实是端点列表');
    });

    test('★★ 必须带 Referer（防盗链）', () {
      // ⚠️ 用**下一个方法名**作边界（不是拍一个长度 —— 我第一版用 3000，
      //    而方法有 5KB+ ⇒ 断言看不全 ⇒ 假失败）
      // 结束锚用下一个方法名（不拍长度）
      final seg = slice('lib/data/calendar_client.dart',
          'Future<CalendarSourceResult> _fetchTgmeng()',
          'Future<CalendarSourceResult> _fetchBangumi()');
      expect(seg.length, greaterThan(2000), reason: '★ 确认切到了方法体');
      expect(seg.contains("'Referer': 'https://tgmeng.com/'"), isTrue,
          reason: '★★ 实测不带 Referer 拿不到数据');
    });

    test('★★ code=200 但 dataInfo 为空要记为**失败**（不是成功但 0 条）', () {
      final seg = slice('lib/data/calendar_client.dart',
          'Future<CalendarSourceResult> _fetchTgmeng()',
          'Future<CalendarSourceResult> _fetchBangumi()');
      // 腾讯的 5 个端点就是这个形态；记成失败才能让 UI 如实提示
      expect(seg.contains('无数据'), isTrue,
          reason: '★★ 否则用户看到"空"而不知道为什么');
    });

    test('★★ 精确播放页 jumpUrl 要优先于搜索页', () {
      final c = code('lib/widgets/calendar_detail_sheet.dart');
      // tgmeng 给的是该剧在平台的**具体页面** ⇒ 一步到位
      expect(c.contains('e.jumpUrl'), isTrue,
          reason: '★★ 详情弹层要优先用它');
      expect(c.contains('launchUrl'), isTrue);
      final p = code('lib/pages/calendar_page.dart');
      expect(p.contains('jumpUrl: entry.jumpUrl'), isTrue,
          reason: '★★ 卡片上的平台 chip 也要优先用它');
    });
  });

  group('★★ 三项小改进（稿子 180b4d）', () {
    test('★★ 追剧统计条「共 N 部 · 连载 N · 已完结 N」', () {
      final c = code('lib/pages/tracking_page.dart');
      // ⚠️ 统计条从"一条纯灰文字"改成了 **RichText**（稿子 `.track-sub`
      //    的数字要**粉色高亮**）⇒ 断言写法跟着改，但**语义不放松**：
      //    仍然要报"总数 / 连载 / 已完结"三个数字。
      expect(c.contains("TextSpan(text: '\${list.length}', style: num)"),
          isTrue, reason: '★★ 稿子的统计条（数字粉色高亮）');
      expect(c.contains("TextSpan(text: '\$live', style: num)"), isTrue);
      expect(c.contains("TextSpan(text: '\$ended', style: num)"), isTrue);
      // ⚠️ 状态未知时**不编造**（否则会显示"连载 0 · 已完结 0"误导）
      expect(c.contains('if (live + ended == 0)'), isTrue,
          reason: '★★ 状态未知时只报总数');
    });

    test('★★★ 「展开全部」只在真的被截断时才显示（不是假按钮）', () {
      final c = code('lib/widgets/calendar_detail_sheet.dart');
      expect(c.contains('_shouldOfferExpand'), isTrue,
          reason: '★★★ 短简介也显示按钮 ⇒ 点了没反应 = 假按钮');
      // ⚠️ 详情页重写后，简介搬进了 `_Overview` 组件（写法随之改变）
      //    ⇒ 断言**目标位置**要跟着改，但**语义不能放松**：
      //    仍然是"默认 3 行 + 可展开"。
      expect(c.contains('maxLines: expanded ? null : 3'), isTrue,
          reason: '★ 稿子规定默认 3 行');
    });

    test('★★ 简介默认折叠的状态字段存在', () {
      final c = code('lib/widgets/calendar_detail_sheet.dart');
      expect(c.contains('bool _descExpanded = false'), isTrue);
    });
  });

  group('★★★ 配色换肤（第 5 套·霓虹粉）', () {
    test('★★★ 5 套预设都在，含用户规格的色值', () {
      final c = code('lib/core/theme.dart');
      for (final name in ["'青'", "'绿'", "'紫'", "'橙'", "'粉'"]) {
        expect(c.contains(name), isTrue, reason: '★★★ 缺预设 $name');
      }
      // 用户规格：主色 #FF4D8D / 副色 #A855F7 / 背景 #0B0D12 / 卡片 #151922
      expect(c.contains('0xFFFF4D8D'), isTrue);
      expect(c.contains('0xFFA855F7'), isTrue);
      expect(c.contains('0xFF0B0D12'), isTrue);
      expect(c.contains('0xFF151922'), isTrue);
    });

    test('★★★ 结构色必须随主题变（不能是 const）', () {
      final c = code('lib/core/theme.dart');
      // 用户规格包含 bg/surface/text ⇒ 它们必须可赋值
      for (final t in ['bg', 'surface', 'text', 'text2', 'text3']) {
        expect(c.contains('static const $t ='), isFalse,
            reason: '★★★ `$t` 若是 const 就换不了肤');
      }
      expect(c.contains('bg = p.\$5'), isTrue,
          reason: '★ applyTheme 里要赋结构色');
    });

    test('★★ 派生色用 _lighten/_darken（避免手写不协调的组合）', () {
      final c = code('lib/core/theme.dart');
      expect(c.contains('_lighten'), isTrue);
      expect(c.contains('_darken'), isTrue);
    });
  });
}
