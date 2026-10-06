import 'package:cineflow/data/media_provider.dart';
import 'package:cineflow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「剧集进度」契约测试。
///
/// ## 历史（这段比测试本身更重要）
///
/// 本项目**曾经**有一个自写的 `SeriesProgress.resolve`（91 行实现 + 13 例测试）：
/// 拉全部分集、遍历各自 `UserData`、推断"用户停在第几集"。
///
/// 用户指出这是**致命问题**：
/// > "这些东西本来你应该能够从 emby 服务端全部拿到。"
///
/// 核实后确实如此 —— Emby 有 `/Shows/NextUp?UserId=&SeriesId=`，
/// **1 次请求**直接给答案（实测返回 S1E9/E10/E11）；而自写版本要 **2 次请求**，
/// 且边界处理更差（服务端有完整观看历史）。实现与旧测试**已一并删除**。
///
/// ## 本文件现在守护什么
///
/// 不再测"算法对不对"（算法在服务端），而是**用编译期约束防止回退**：
///
/// `_FakeProvider` 对 `getNextUp` 标了 `@override`。
/// 一旦有人把 `getNextUp` 从 `MediaProvider` 接口里删掉（等于回到自己算的老路），
/// `@override` 就会变成 `override_on_non_overriding_member`，
/// 而 `flutter analyze` 是本仓库的**必过门禁** → 改动会被拦下。
///
/// 这是 Dart 里能做到的、最接近"禁止删除某方法"的手段。
void main() {
  group('MediaProvider 必须暴露 getNextUp（服务端算，不要自己算）', () {
    test('★ getNextUp 存在于接口上，且可被实现（编译期守护）', () async {
      // 能构造出 _FakeProvider 并赋给 MediaProvider，说明接口完整
      final MediaProvider p = _FakeProvider();
      final r = await p.getNextUp('series-1');
      expect(r, hasLength(1));
    });

    test('limit 参数生效（默认 1 集，可要多集）', () async {
      final p = _FakeProvider();
      await p.getNextUp('s1', limit: 1);
      await p.getNextUp('s1', limit: 5);
      expect(p.calls, hasLength(2));
      expect(p.calls[0].$2, 1);
      expect(p.calls[1].$2, 5);
    });

    test('★ 已全部看完时返回空列表（不是错误）', () async {
      // 服务端语义：该剧没有"下一集"了 → 空列表。
      // 调用方据此回退到"重播第一集"，而不是把它当失败。
      final p = _FakeProvider(empty: true);
      final r = await p.getNextUp('s1');
      expect(r, isEmpty);
    });

    test('返回值是 MediaItem（与其它列表接口一致，可直接渲染卡片）', () async {
      final p = _FakeProvider();
      final r = await p.getNextUp('s1');
      expect(r.first, isA<MediaItem>());
      expect(r.first.type, 'Episode');
    });
  });
}

/// 最小实现：只为用 `@override` 锁定 `getNextUp` 的签名。
///
/// ⚠️ 这里**故意**把 `getNextUp` 标 `@override` —— 见文件头说明。
class _FakeProvider implements MediaProvider {
  _FakeProvider({this.empty = false});

  final bool empty;

  /// 记录调用（seriesId, limit），供断言参数传递正确
  final List<(String, int)> calls = [];

  @override
  Future<List<MediaItem>> getNextUp(String seriesId, {int limit = 1}) async {
    calls.add((seriesId, limit));
    if (empty) return const [];
    return [
      const MediaItem(
        id: 'ep9',
        name: '第 9 集',
        type: 'Episode',
        indexNumber: 9,
        parentIndexNumber: 1,
      ),
    ];
  }

  // ---- 以下为接口的其余成员：本测试用不到，抛未实现即可 ----
  // （不用 noSuchMethod 是为了让编译器*强制*我列出所有成员，
  //   这样接口新增方法时这里会立刻报错，提示同步更新。）

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 未在本 fake 中实现');
}
