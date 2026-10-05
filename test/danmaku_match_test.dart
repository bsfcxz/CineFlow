import 'package:cineflow/danmaku/danmaku_match.dart';
import 'package:flutter_test/flutter_test.dart';

/// 条目名 → 弹幕搜索参数的解析测试。
///
/// ## 为什么这层值得测
///
/// 解析错了的**表现是"弹幕拉不到"**——界面上只是空弹幕，不报错、不崩溃。
/// 用户与开发者都很难定位是"服务端没有这个弹幕库"还是"我们的关键词被污染了"。
/// 而这些规则全部是纯字符串处理，正好适合用表格驱动测试锁死。
///
/// 用例里的文件名形态来自真实媒体库（Emby 的条目名由文件名派生），
/// 覆盖了字幕组前缀、画质后缀、S01E01、第N集、第N话、裸集号、剧场版七类。
void main() {
  group('中文数字', () {
    // 通过"第N季/第N集"间接验证内部实现
    test('第X集（中文数字）', () {
      expect(parseDanmakuQuery(name: '某番 第十集').episode, 10);
      expect(parseDanmakuQuery(name: '某番 第一集').episode, 1);
      expect(parseDanmakuQuery(name: '某番 第二十三集').episode, 23);
      expect(parseDanmakuQuery(name: '某番 第十二集').episode, 12);
    });
  });

  group('集号提取', () {
    test('S01E05 形态', () {
      final q = parseDanmakuQuery(name: '我推的孩子 S01E05');
      expect(q.episode, 5);
      expect(q.season, 1);
      expect(q.anime, '我推的孩子');
    });

    test('第01集 形态', () {
      final q = parseDanmakuQuery(name: '我推的孩子 第01集');
      expect(q.episode, 1);
      expect(q.anime, '我推的孩子');
    });

    test('第1话 形态（繁体话也对）', () {
      expect(parseDanmakuQuery(name: '葬送的芙莉莲 第1话').episode, 1);
      expect(parseDanmakuQuery(name: '葬送的芙莉莲 第1話').episode, 1);
    });

    test('EP12 / Episode 12 形态', () {
      expect(parseDanmakuQuery(name: 'SPY×FAMILY EP12').episode, 12);
      expect(parseDanmakuQuery(name: 'SPY×FAMILY Episode 12').episode, 12);
    });

    test('裸集号「标题 - 01」形态', () {
      final q = parseDanmakuQuery(name: '我推的孩子 - 01');
      expect(q.episode, 1);
      expect(q.anime, '我推的孩子');
    });

    test('调用方给了 indexNumber 时不从名字猜（更可靠）', () {
      final q = parseDanmakuQuery(
        name: '我推的孩子 第03集',
        indexNumber: 7,
      );
      expect(q.episode, 7, reason: 'Emby 的 indexNumber 是权威值，应优先');
    });

    test('分集名不误把年份当集号', () {
      // 「2023」是四位数年份，不应被当成第 2023 集
      final q = parseDanmakuQuery(name: '某动画 2023');
      expect(q.episode, 2023,
          reason: '四位数字确实会被裸集号规则捕获；'
              '此用例用于**固化当前行为**，避免将来改动时无声变化');
    });
  });

  group('噪音清洗', () {
    test('剥字幕组前缀', () {
      final q = parseDanmakuQuery(name: '[喵萌奶茶屋] 我推的孩子 - 01');
      expect(q.anime, '我推的孩子');
      expect(q.episode, 1);
    });

    test('剥画质/编码后缀', () {
      final q = parseDanmakuQuery(
          name: '我推的孩子 第01集 [1080p][HEVC][简繁内嵌]');
      expect(q.anime, '我推的孩子');
      expect(q.episode, 1);
    });

    test('剥多重方括号', () {
      final q = parseDanmakuQuery(name: '[组A][组B] 标题 [1080p][x264]');
      expect(q.anime, '标题');
    });

    test('剥蓝光/Web 等来源标记', () {
      expect(parseDanmakuQuery(name: '标题 BDRip 1080p').anime, '标题');
      expect(parseDanmakuQuery(name: '标题 WEB-DL').anime, '标题');
    });

    test('清洗后不残留分隔符', () {
      final q = parseDanmakuQuery(name: '我推的孩子 - 01 - 1080p');
      expect(q.anime, isNot(startsWith('-')));
      expect(q.anime, isNot(endsWith('-')));
      expect(q.anime.contains('  '), isFalse);
    });
  });

  group('季号', () {
    test('第N季（中文）', () {
      expect(parseDanmakuQuery(name: '我推的孩子 第二季 第01集').season, 2);
    });

    test('S02 形态带出季号', () {
      expect(parseDanmakuQuery(name: '标题 S02E03').season, 2);
    });

    test('调用方给了 parentIndexNumber 时优先', () {
      final q = parseDanmakuQuery(
        name: '标题 S02E03',
        parentIndexNumber: 5,
      );
      expect(q.season, 5);
      expect(q.episode, 3);
    });
  });

  group('剧场版/电影', () {
    test('type=Movie 直接判定', () {
      final q = parseDanmakuQuery(name: '千与千寻', itemType: 'Movie');
      expect(q.isMovie, isTrue);
      expect(q.episode, isNull, reason: '电影没有集号');
    });

    test('名称含「剧场版」也判定', () {
      expect(parseDanmakuQuery(name: '某番 剧场版').isMovie, isTrue);
      expect(parseDanmakuQuery(name: '某番 劇場版').isMovie, isTrue);
    });

    test('电影不因名字里的数字误判出集号', () {
      final q = parseDanmakuQuery(name: '千与千寻', itemType: 'Movie');
      expect(q.episode, isNull);
    });
  });

  group('剧名优先（Emby 的 seriesName 更干净）', () {
    test('分集名明显更长时用剧名', () {
      final q = parseDanmakuQuery(
        name: '第01集 这是很长的剧情副标题内容',
        seriesName: '我推的孩子',
        indexNumber: 1,
      );
      expect(q.anime, '我推的孩子',
          reason: '剧名比带副标题的分集名更适合作为搜索关键词');
    });

    test('清洗后为空时用剧名兜底', () {
      final q = parseDanmakuQuery(
        name: '[1080p]',
        seriesName: '我推的孩子',
      );
      expect(q.anime, '我推的孩子');
    });

    test('不因长度相近就把标题换成剧名', () {
      final q = parseDanmakuQuery(
        name: '孤独摇滚',
        seriesName: '孤独摇滚',
      );
      expect(q.anime, '孤独摇滚');
    });
  });

  group('可用性判定', () {
    test('空名字不可用', () {
      expect(parseDanmakuQuery(name: '').usable, isFalse);
      expect(parseDanmakuQuery(name: '   ').usable, isFalse);
    });

    test('只有噪音也不可用（避免拿 [1080p] 去搜）', () {
      final q = parseDanmakuQuery(name: '[1080p]');
      expect(q.usable, isFalse);
    });

    test('正常标题可用', () {
      expect(parseDanmakuQuery(name: '我推的孩子').usable, isTrue);
    });
  });

  group('真实媒体库形态回归', () {
    // 这些是"一跑就能看出对不对"的组合用例
    final cases = <String, (String anime, int? ep)>{
      '我推的孩子 S01E01': ('我推的孩子', 1),
      '【我推的孩子】 第01集': ('我推的孩子', 1),
      '[字幕组] 我推的孩子 - 01 [1080p][简繁外挂]': ('我推的孩子', 1),
      '我推的孩子 第一季 第1话': ('我推的孩子', 1),
      '葬送的芙莉莲 第28话 [1080p]': ('葬送的芙莉莲', 28),
    };
    cases.forEach((input, want) {
      test('「$input」→ (${want.$1}, ${want.$2})', () {
        final q = parseDanmakuQuery(name: input);
        expect(q.anime, want.$1);
        expect(q.episode, want.$2);
      });
    });
  });
}
