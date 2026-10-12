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
      expect(c.contains(r'共 $' + '{list.length} 部'), isTrue,
          reason: '★★ 稿子的统计条');
      expect(c.contains('连载 \$live'), isTrue);
      expect(c.contains('已完结 \$ended'), isTrue);
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
