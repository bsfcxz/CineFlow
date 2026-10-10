// 公共代理源（内置）的守卫测试。
//
// ## 背景（用户要求）
// "搜寻一下公共的api接入吧，多平台都有的，搜寻一下 GitHub 或者网络上
//  公共的弹幕源代理 **直接内置**，然后自建的保留，给用户多种选择"
//
// ## 为什么这些断言必要
// 公共代理与官方**端点形状不同**（实测）：
//   · 官方：`/api/v2/search/episodes?anime=&episode=` 一步拿 episodeId
//   · 公共代理：**没有那个端点**（实测 404）⇒ 必须两步：
//       `/api/v2/search/anime?keyword=` → animeId
//       `/api/v2/bangumi/{animeId}`     → episodes[] → episodeId
//
// 若把两者统一成一种，**必有一边拿不到 id** ⇒ 现象是"弹幕永远匹配不到"
// ——不报错、不崩溃，正是本仓库反复记录的**静默失败**形态。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/danmaku/danmaku_config.dart';

/// 剥注释读源码（§8.4：断言不得被注释满足）。
String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  group('★ 公共代理：默认与免配置', () {
    test('★ 默认就是公共代理（开箱即用）', () {
      expect(const DanmakuConfig().kind, DanmakuProviderKind.publicProxy,
          reason: '★ 官方源强制签名 ⇒ 普通用户拿不到凭据 ⇒\n'
              '    默认若是 off/official，装上弹幕也永远用不了。');
    });

    test('★ 三种源都保留（给用户选择）', () {
      final names = DanmakuProviderKind.values.map((k) => k.name).toSet();
      expect(names.contains('publicProxy'), isTrue, reason: '★ 公共代理要内置');
      expect(names.contains('official'), isTrue, reason: '★ 官方源要保留');
      expect(names.contains('selfHosted'), isTrue,
          reason: '★ 自建源要保留（用户明确要求"自建的保留"）');
      expect(names.contains('off'), isTrue, reason: '★ 要能关掉');
    });

    test('每个源都有中文标签（UI 直接显示）', () {
      for (final k in DanmakuProviderKind.values) {
        expect(k.label.trim().isNotEmpty, isTrue, reason: '${k.name} 缺标签');
      }
    });

    test('★ 只有公共代理是零配置', () {
      expect(DanmakuProviderKind.publicProxy.isZeroConfig, isTrue);
      for (final k in DanmakuProviderKind.values) {
        if (k == DanmakuProviderKind.publicProxy) continue;
        expect(k.isZeroConfig, isFalse,
            reason: '${k.name} 不该被标成零配置（会误导用户以为不用填）');
      }
    });
  });

  group('★★ 源码结构（防脱钩）', () {
    late String client;

    setUpAll(() {
      client = code('lib/danmaku/danmaku_client.dart');
    });

    test('★★ 公共代理必须走**两步搜索**（官方端点它没有）', () {
      // 断言具体路径存在，而不是"有分支"这种弱断言
      expect(client.contains("'/api/v2/search/anime'"), isTrue,
          reason: '★★ 公共代理没有 /api/v2/search/episodes（实测 404），\n'
              '    必须用 search/anime 起步');
      expect(client.contains("'/api/v2/bangumi/\$animeId'"), isTrue,
          reason: '★ 第二步取集列表（episodes[] → episodeId）');
      expect(client.contains('_findEpisodeIdViaProxy'), isTrue);
    });

    test('★★ 搜索路径必须**按源分支**（不能统一）', () {
      final i = client.indexOf('Future<int?> findEpisodeId({');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 findEpisodeId');
      final end = client.indexOf('Future<int?> _findEpisodeIdViaProxy', i);
      expect(end, greaterThan(i), reason: '找不到方法边界');
      final seg = client.substring(i, end);
      expect(seg.contains('DanmakuProviderKind.publicProxy'), isTrue,
          reason: '★★ 必须按源类型分派搜索路径 ——\n'
              '    统一成一种必有一边拿不到 episodeId（静默无弹幕）');
      expect(seg.contains("'/api/v2/search/episodes'"), isTrue,
          reason: '★ 官方/自建仍走一步端点（不能为了公共代理把它删了）');
    });

    test('★ 公共代理不带任何签名头（免注册）', () {
      final i = client.indexOf('Future<String> _get(');
      expect(i, greaterThanOrEqualTo(0));
      final seg = client.substring(i, i + 1400);
      expect(seg.contains('_isOfficial'), isTrue,
          reason: '签名头必须只对官方源生效');
    });

    test('★ base 地址是内置常量（用户不用填）', () {
      expect(client.contains('kPublicProxyBase'), isTrue);
      expect(client.contains('danmaku-api.152468.xyz'), isTrue,
          reason: '★ 内置的公共代理地址');
    });

    test('★★ 公共代理**绝不能**发 `async` 参数（真机 400 的根因）', () {
      // ## 真机 + 实测双重取证
      // 真机：`[PlayerFlow] 弹幕：弹幕服务返回 HTTP 400`
      // 实测（逐参数二分）：
      //   ?async=1  → 400 "Invalid query parameters"
      //   ?async=0  → 400（同样）
      //   ?withRelated=true&chConvert=1 → 200 ✅
      //   ?withRelated=true&chConvert=1&async=1 → 400 ❌（=App 的实际请求）
      // ⇒ 该代理**严格校验参数白名单**，不是本仓库注释里写的"静默忽略"。
      final i = client.indexOf('final query = {');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 comment 的查询参数构造');
      final seg = client.substring(i, i + 400);
      expect(seg.contains('kind != DanmakuProviderKind.publicProxy'), isTrue,
          reason: '★★ `async` 必须**排除公共代理** ——\n'
              '    否则该源返回 400，弹幕永远出不来（不影响播放，很难发现）。');
    });

    test('★ 未知 kind 回退用**默认值**而非写死 off', () {
      // 两处默认值必须一致：改了 DanmakuConfig 的默认，
      // 存储层的"未知回退"要跟着走，否则升级路径上两者不一致
      final store = code('lib/data/session_store.dart');
      expect(store.contains('orElse: () => const DanmakuConfig().kind'), isTrue,
          reason: '★ 读存储时未知 kind 必须回退到"默认值"本身 ——\n'
              '    写死 off 会让两处默认值分叉（测试已抓到过）');
    });
  });
}
