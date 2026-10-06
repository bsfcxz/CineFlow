import 'package:cineflow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// `isPlayable` 的**口径一致性**测试。
///
/// ## 这个测试针对一个真实缺陷（用户真机报出来的）
///
/// 用户库的"最近添加"几乎全是剧集（`Series`），而 Dart 侧 `isPlayable`
/// 曾经是 `Movie || Episode`（**漏了 `Series`**），
/// 于是 `/Latest` 的 24 条被过滤成 **1 条**，首页出现 940px 空白带（占屏 39%）。
///
/// 更糟的是**同一个概念在 Go 侧有另一套口径**：
/// `go/internal/media/filter.go` 的 `IsPlayable` 是
/// `Movie/Episode/Video/MusicVideo/Trailer/Series`。
/// 两套口径不一致时，"服务端过滤 + 客户端复筛"会**双重削减**结果集。
///
/// ## 为什么必须用单测守
///
/// 这个缺陷**静态分析发现不了**，而且真机上表现为"首页看起来正常但内容很少"——
/// 很容易被当成"这个库东西本来就少"。只有断言类型集合本身才能防回归。
void main() {
  MediaItem item(String type) => MediaItem(id: 'x', name: 'n', type: type);

  group('isPlayable 必须与 Go 侧 media.IsPlayable 同口径', () {
    // 与 go/internal/media/filter.go 的 switch 分支**逐一对齐**。
    // 改任何一侧都必须同步另一侧，否则这个测试会红。
    const goPlayable = {'Movie', 'Episode', 'Video', 'MusicVideo', 'Trailer',
        'Series'};

    test('★ Series 必须可播/可浏览（曾经漏掉，导致首页只剩 1 条）', () {
      expect(item('Series').isPlayable, isTrue,
          reason: 'Series 是合法浏览入口；漏掉它会让"最近添加"里的剧集全部消失');
    });

    test('Go 侧全部 6 种可播类型在 Dart 侧同样为真', () {
      for (final t in goPlayable) {
        expect(item(t).isPlayable, isTrue, reason: '$t 在 Go 侧可播，Dart 侧必须一致');
      }
    });

    test('不可播的浏览容器必须为假', () {
      for (final t in ['BoxSet', 'Folder', 'CollectionFolder', 'Season',
          'Person', 'Genre', 'Studio']) {
        expect(item(t).isPlayable, isFalse, reason: '$t 不是可播条目');
      }
    });

    test('★ 口径集合必须完全相同（防止将来单侧增删类型）', () {
      // 穷举常见 Emby Type，逐一确认两侧判定一致
      const allTypes = [
        'Movie', 'Episode', 'Video', 'MusicVideo', 'Trailer', 'Series',
        'BoxSet', 'Folder', 'CollectionFolder', 'Season', 'Person',
        'Genre', 'Studio', 'PhotoAlbum', 'Audio', 'Book',
      ];
      final dartPlayable = allTypes.where((t) => item(t).isPlayable).toSet();
      expect(dartPlayable, goPlayable,
          reason: '两侧口径必须逐字相同；差异会导致结果集被双重削减');
    });
  });

  group('首页内容量回归线（真实缺陷的量化形态）', () {
    test('★ 全是剧集的 Latest 结果不该被过滤空', () {
      // 复现用户库的真实形态：最近添加全是 Series
      final latest = [
        item('Series'), item('Series'), item('Series'),
        item('Series'), item('Series'),
      ];
      final kept = latest.where((i) => i.isPlayable).toList();
      expect(kept, hasLength(5),
          reason: '改造前这里会变成 0 条（Series 全被滤掉）→ 首页空白 39%');
    });

    test('混合类型时按可播性筛选，不误删电影与单集', () {
      final latest = [
        item('Series'), item('Movie'), item('BoxSet'),
        item('Episode'), item('Folder'),
      ];
      final kept = latest.where((i) => i.isPlayable).toList();
      expect(kept.map((e) => e.type).toList(), ['Series', 'Movie', 'Episode']);
    });
  });
}
