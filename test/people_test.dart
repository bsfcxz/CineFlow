import 'package:cineflow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 演职员筛选/摘要的单元测试（缺陷 §7.14）。
///
/// 实测依据（本机 curl，2026-10）：
/// 该服务器 `People[].Type` 只出现 `Actor`(107) 与 `Director`(14) 两种，
/// 而详情页旧实现只渲染 `Actor` —— **14 条导演数据全部被静默丢弃**。
/// 这类"数据到了但没显示"的缺陷无法被静态分析发现，故用断言锁定。
void main() {
  MediaPerson person(String name, String type, {String id = ''}) =>
      MediaPerson(id: id.isEmpty ? name : id, name: name, type: type);

  group('actors()', () {
    test('只取 Actor，且默认最多 12 位', () {
      final people = [
        for (var i = 0; i < 20; i++) person('演员$i', 'Actor'),
        person('某导演', 'Director'),
      ];
      final a = people.actors();
      expect(a, hasLength(12), reason: '默认截断到 12');
      expect(a.every((p) => p.type == 'Actor'), isTrue);
    });

    test('无 Actor 时返回空', () {
      expect([person('导演', 'Director')].actors(), isEmpty);
    });
  });

  group('directors()（回归线：导演曾被完全丢弃）', () {
    test('能取出导演', () {
      final people = [
        person('演员A', 'Actor'),
        person('五百', 'Director'),
        person('董润年', 'Director'),
      ];
      expect(people.directors().map((p) => p.name), ['五百', '董润年']);
    });

    test('按 id 去重且保序（同一人多段署名只留一次）', () {
      final people = [
        person('五百', 'Director', id: 'd1'),
        person('五百', 'Director', id: 'd1'),
        person('董润年', 'Director', id: 'd2'),
      ];
      expect(people.directors(), hasLength(2));
      expect(people.directors().first.name, '五百');
    });

    test('无导演返回空', () {
      expect([person('演员', 'Actor')].directors(), isEmpty);
    });
  });

  group('crewLine()', () {
    test('优先显示导演', () {
      final people = [
        person('五百', 'Director'),
        person('董润年', 'Director'),
        person('某编剧', 'Writer'),
      ];
      expect(people.crewLine(), '导演 五百 / 董润年');
    });

    test('无导演时回退编剧', () {
      expect([person('某编剧', 'Writer')].crewLine(), '编剧 某编剧');
    });

    test('两者都没有返回 null（UI 据此隐藏摘要行）', () {
      expect([person('演员', 'Actor')].crewLine(), isNull);
      expect(<MediaPerson>[].crewLine(), isNull);
    });
  });

  group('MediaPerson.fromJson 防御式解析', () {
    test('字段缺失不抛异常', () {
      final p = MediaPerson.fromJson(<String, dynamic>{});
      expect(p.id, '');
      expect(p.name, '');
      expect(p.type, '');
      expect(p.role, isNull);
    });

    test('正常字段解析正确', () {
      final p = MediaPerson.fromJson({
        'Id': 'x1',
        'Name': '五百',
        'Role': '导演',
        'Type': 'Director',
        'PrimaryImageTag': 'tag1',
      });
      expect(p.id, 'x1');
      expect(p.type, 'Director');
      expect(p.primaryImageTag, 'tag1');
    });
  });
}
