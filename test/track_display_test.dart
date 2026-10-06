import 'package:cineflow/player/kernel.dart';
import 'package:flutter_test/flutter_test.dart';

/// 轨道名称拼装测试。
///
/// ## 用户原话
/// > "而且向多音轨多字幕这种，我在选择的时候你显示出名称，
/// >  像字幕的话 有中字、双语、繁体等"
///
/// ## 为什么必须单测
///
/// 改造前的实现只显示 `title ?? language ?? id`。而**实测真实片源**里：
///   · 多音轨经常 **title 全为空**（只有 codec/声道不同）→ 界面上出现几条
///     一模一样的"音轨 开"，用户根本分不清
///   · 字幕常只有 `lang=chi` → 显示"字幕 chi"，对用户毫无意义
///
/// 这些在真机上要"恰好遇到多轨片源"才看得到，且**看起来只是"名字不好看"**，
/// 很容易被当成小问题放过。只有断言拼装结果才能防回归。
void main() {
  group('语言码归一化（用户看不懂 chi/zho/eng）', () {
    test('★ 中文字幕的三个常见码都归一到"中文"', () {
      for (final code in ['chi', 'zho', 'zh', 'chs', 'cht']) {
        final t = KernelTrack(id: '1', language: code);
        expect(t.displayName, '中文', reason: '$code 应显示为中文');
      }
    });

    test('常见外语归一化', () {
      expect(KernelTrack(id: '1', language: 'eng').displayName, '英语');
      expect(KernelTrack(id: '1', language: 'jpn').displayName, '日语');
      expect(KernelTrack(id: '1', language: 'kor').displayName, '韩语');
    });

    test('未知语言显示大写码（至少能区分，不显示空）', () {
      final t = KernelTrack(id: '1', language: 'xyz');
      expect(t.displayName, 'XYZ');
    });

    test('大小写不敏感（mpv 可能给 CHI / Eng）', () {
      expect(KernelTrack(id: '1', language: 'CHI').displayName, '中文');
      expect(KernelTrack(id: '1', language: 'Eng').displayName, '英语');
    });
  });

  group('多音轨区分（title 为空时靠声道/编解码）', () {
    test('★ 实测场景：两条音轨 title 都为空，靠声道+编解码区分', () {
      // 真机实测：Audio --aid=1 (aac 2ch) vs Audio --aid=3 (eac3 6ch)
      final a = KernelTrack(id: '1', codec: 'aac', channels: 2);
      final b = KernelTrack(id: '3', codec: 'eac3', channels: 6);
      expect(a.displayName, '立体声 · aac');
      expect(b.displayName, '5.1 声道 · eac3');
      expect(a.displayName, isNot(b.displayName),
          reason: '两条轨必须显示不同，否则用户无法选择');
    });

    test('★ 声道相同但编解码不同 → 仍能区分', () {
      // 实测存在：两条都是 2ch，但一条 aac 一条 eac3（音质不同）
      final a = KernelTrack(id: '1', codec: 'aac', channels: 2);
      final b = KernelTrack(id: '2', codec: 'eac3', channels: 2);
      expect(a.displayName, isNot(b.displayName),
          reason: 'codec 必须是区分点之一，否则这两条完全同名');
    });

    test('title + 语言 + 声道 + 编解码 全有值时按序拼装', () {
      final t = KernelTrack(
          id: '1', title: '国语', language: 'chi', codec: 'eac3', channels: 6);
      // title 已含"国"→ 不重复显示"中文"
      expect(t.displayName, '国语 · 5.1 声道 · eac3');
    });

    test('声道数映射到人话', () {
      expect(KernelTrack(id: '1', channels: 1).displayName, '单声道');
      expect(KernelTrack(id: '1', channels: 2).displayName, '立体声');
      expect(KernelTrack(id: '1', channels: 6).displayName, '5.1 声道');
      expect(KernelTrack(id: '1', channels: 8).displayName, '7.1 声道');
      expect(KernelTrack(id: '1', channels: 4).displayName, '4 声道');
    });

    test('声道缺失时不显示该段（不留空 · ）', () {
      final t = KernelTrack(id: '1', language: 'chi');
      expect(t.displayName, '中文');
      expect(t.displayName.contains('·'), isFalse,
          reason: '只有一段时不应出现分隔符');
    });
  });

  group('避免重复（title 已含语言时不再叠加）', () {
    test('★ title="简体中文" + lang=chi → 不出现"简体中文 · 中文"', () {
      final t = KernelTrack(id: '1', title: '简体中文', language: 'chi');
      expect(t.displayName, '简体中文');
    });

    test('title="繁体中文" 同理', () {
      final t = KernelTrack(id: '1', title: '繁体中文', language: 'zho');
      expect(t.displayName, '繁体中文');
    });

    test('title="双语" 保留（这是用户要看到的信息）', () {
      final t = KernelTrack(id: '1', title: '双语', language: 'chi');
      // "双语"不含"中/国/汉"，故仍会补上语言段
      expect(t.displayName, contains('双语'));
    });

    test('title 与语言无关时两段都显示', () {
      final t = KernelTrack(id: '1', title: '评论音轨', language: 'eng');
      expect(t.displayName, '评论音轨 · 英语');
    });
  });

  group('标记与兜底', () {
    test('外挂字幕标注"外挂"', () {
      final t = KernelTrack(id: '1', language: 'chi', isExternal: true);
      expect(t.displayName, '中文 · 外挂');
    });

    test('强制字幕标注"强制"', () {
      final t = KernelTrack(id: '1', language: 'eng', isForced: true);
      expect(t.displayName, '英语 · 强制');
    });

    test('全空时用轨道 id 兜底（绝不显示空字符串）', () {
      final t = KernelTrack(id: '7');
      expect(t.displayName, '轨道 7');
      expect(t.displayName.isNotEmpty, isTrue);
    });

    test('只有 codec 时用 codec 兜底', () {
      final t = KernelTrack(id: '1', codec: 'mov_text');
      expect(t.displayName, 'mov_text');
    });
  });

  group('不变量', () {
    test('★ displayName 永远非空（空标签会让用户看到无字按钮）', () {
      final cases = [
        const KernelTrack(id: '1'),
        const KernelTrack(id: '2', title: ''),
        const KernelTrack(id: '3', language: ''),
        const KernelTrack(id: '4', title: '', language: ''),
      ];
      for (final t in cases) {
        expect(t.displayName.trim().isNotEmpty, isTrue,
            reason: 'id=${t.id} 的显示名不能为空');
      }
    });

    test('★ 不同轨道在"实测常见差异"下都能区分开', () {
      // 模拟一条真实的多轨片源
      final tracks = [
        KernelTrack(id: '1', codec: 'aac', channels: 2),
        KernelTrack(id: '2', codec: 'eac3', channels: 6),
        KernelTrack(id: '3', language: 'jpn', codec: 'aac', channels: 2),
      ];
      final names = tracks.map((t) => t.displayName).toList();
      expect(names.toSet().length, names.length,
          reason: '三条轨必须得到三个不同的名字：$names');
    });
  });
}
