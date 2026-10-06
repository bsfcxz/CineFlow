import 'package:cineflow/data/models.dart';
import 'package:cineflow/player/player_facade.dart';
import 'package:cineflow/player/track_aligner.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务端轨道 ↔ 内核轨道的**对齐**测试。
///
/// ## 为什么这是本项目最容易出错的一处
///
/// 两套编号空间不同，而典型片源下数字**碰巧相同**，掩盖了差异：
///
/// | 流 | Emby `Index`（ffmpeg 全局） | mpv `aid`/`sid`（每类型独立） | mpv `ff-index` |
/// |---|---|---|---|
/// | video | 0 | `vid=1` | 0 |
/// | audio#1 | 1 | `aid=1` | 1 |
/// | sub#1 | 2 | **`sid=1`** | 2 |
///
/// → 用 `id`（`sid=1`）去匹配 Emby 的 `Index=2` **永远匹配不上或匹配错**。
/// 只有 `ff-index`（2）才对得上。
///
/// 这类错误**不会崩、不会报错**，只是**切到错误的轨道**（比如想切中文字幕
/// 结果切成了英文）。真机验证成本极高，故必须用单测钉住。
void main() {
  MediaStream srv(String type, int index,
          {String? title, String? lang, String? displayLang}) =>
      MediaStream(
        type: type,
        index: index,
        displayTitle: title,
        displayLanguage: displayLang,
        language: lang,
      );

  group('ffIndex 精确匹配（首选路径）', () {
    test('★ sub 的 sid=1 与 Emby Index=2 靠 ffIndex=2 正确对齐', () {
      // 服务端：video(0) audio(1) sub(2) sub(3)
      final server = [
        srv('Audio', 1, title: 'Chinese TRUEHD 5.1 (默认)'),
        srv('Subtitle', 2, title: 'Chinese Simplified (PGSSUB)'),
        srv('Subtitle', 3, title: 'English (PGSSUB)'),
      ];
      // 内核：aid=1（audio 里第 1 条），sid=1/2（sub 里第 1/2 条）
      // 关键：sub 的 ff-index 是 2 和 3，**不是** 1 和 2
      final kernelSubs = [
        const FacadeSubtitleTrack(id: '1', ffIndex: 2),
        const FacadeSubtitleTrack(id: '2', ffIndex: 3),
      ];
      final aligned = TrackAligner.alignSubtitle(
        server.where((s) => s.type == 'Subtitle').toList(),
        kernelSubs,
      );

      expect(aligned, hasLength(2));
      expect(aligned[0].label, 'Chinese Simplified (PGSSUB)');
      expect(aligned[0].kernelId, '1', reason: '内核用 sid=1 切这条');
      expect(aligned[0].matchedByIndex, isTrue);
      expect(aligned[1].label, 'English (PGSSUB)');
      expect(aligned[1].kernelId, '2');
    });

    test('★ 若用 id 当 Index（旧注释的错误做法）会张冠李戴', () {
      final serverSubs = [
        srv('Subtitle', 2, title: 'Chinese Simplified'),
        srv('Subtitle', 3, title: 'English'),
      ];
      // 模拟"用 id 去匹配 Index"的错误实现
      String wrongLabelFor(String kernelId) {
        final idx = int.parse(kernelId);
        return serverSubs
            .firstWhere((s) => s.index == idx, orElse: () => srv('Subtitle', -1, title: '❌ 匹配不到'))
            .displayTitle!;
      }

      // sid=1 在错误实现下会找到 Index=1 的流 —— 但 Index=1 是 audio！
      expect(wrongLabelFor('1'), '❌ 匹配不到',
          reason: 'sid=1 找不到 Index=1 的字幕（Index=1 其实是音轨）');
      // 而正确实现靠 ffIndex 拿到正确结果
      final right = TrackAligner.alignSubtitle(serverSubs, [
        const FacadeSubtitleTrack(id: '1', ffIndex: 2),
      ]);
      expect(right[0].label, 'Chinese Simplified');
    });

    test('默认轨标记（服务端 DefaultSubtitleStreamIndex）', () {
      final serverSubs = [
        srv('Subtitle', 2, title: '中文'),
        srv('Subtitle', 3, title: 'English'),
      ];
      final aligned = TrackAligner.alignSubtitle(
        serverSubs,
        [
          const FacadeSubtitleTrack(id: '1', ffIndex: 2),
          const FacadeSubtitleTrack(id: '2', ffIndex: 3),
        ],
        defaultIndex: 3,
      );
      expect(aligned[0].isDefault, isFalse);
      expect(aligned[1].isDefault, isTrue, reason: '服务端指定默认是 Index=3');
    });
  });

  group('音轨对齐（服务端名字优先）', () {
    test('★ 用服务端 DisplayTitle 作为展示名（比内核自拼好）', () {
      final serverAudio = [
        srv('Audio', 1, title: 'Chinese TRUEHD 5.1 (默认)'),
        srv('Audio', 2, title: 'Chinese AC3 5.1'),
      ];
      final kernelAudio = [
        // 内核只知道 codec/channels，拼出来是 "立体声 · eac3" 这种
        const FacadeAudioTrack(id: '1', ffIndex: 1, codec: 'truehd', channels: 6),
        const FacadeAudioTrack(id: '2', ffIndex: 2, codec: 'ac3', channels: 6),
      ];
      final aligned = TrackAligner.alignAudio(serverAudio, kernelAudio);

      expect(aligned[0].label, 'Chinese TRUEHD 5.1 (默认)');
      expect(aligned[1].label, 'Chinese AC3 5.1');
      expect(aligned.every((a) => a.matchedByIndex), isTrue);
    });

    test('内核 id 保留给切换用（与服务端 Index 不同也没关系）', () {
      final aligned = TrackAligner.alignAudio(
        [srv('Audio', 5, title: '国语')],
        [const FacadeAudioTrack(id: '1', ffIndex: 5)],
      );
      expect(aligned[0].kernelId, '1', reason: '切轨要用内核的 aid');
      expect(aligned[0].label, '国语', reason: '显示用服务端的名字');
    });
  });

  group('降级：ffIndex 不可用时按顺序匹配', () {
    test('ffIndex 全为 null → 按同类型顺序对应', () {
      final serverAudio = [
        srv('Audio', 1, title: '第一条'),
        srv('Audio', 2, title: '第二条'),
      ];
      final kernelAudio = [
        const FacadeAudioTrack(id: '1'), // 无 ffIndex（非 libavformat 解封装）
        const FacadeAudioTrack(id: '2'),
      ];
      final aligned = TrackAligner.alignAudio(serverAudio, kernelAudio);
      expect(aligned[0].label, '第一条');
      expect(aligned[1].label, '第二条');
      expect(aligned.every((a) => a.matchedByIndex), isFalse,
          reason: '顺序匹配应标记为非精确');
    });

    test('部分有 ffIndex：精确的优先，剩下的顺序补（不重复占用）', () {
      final serverAudio = [
        srv('Audio', 1, title: 'A1'),
        srv('Audio', 2, title: 'A2'),
        srv('Audio', 3, title: 'A3'),
      ];
      final kernelAudio = [
        const FacadeAudioTrack(id: '1', ffIndex: 3), // 精确 → A3
        const FacadeAudioTrack(id: '2'), // 无 → 顺序补第一个未占用
      ];
      final aligned = TrackAligner.alignAudio(serverAudio, kernelAudio);
      expect(aligned[0].label, 'A3', reason: '精确匹配优先');
      expect(aligned[0].matchedByIndex, isTrue);
      expect(aligned[1].label, 'A1', reason: '顺序补未占用的第一条');
      expect(aligned[1].matchedByIndex, isFalse);
    });
  });

  group('兜底：完全对不上时用内核信息（名字差但不崩）', () {
    test('服务端没有该轨道 → 用内核 codec/channels 拼', () {
      final aligned = TrackAligner.alignAudio(
        const [], // 服务端没给
        const [
          FacadeAudioTrack(id: '1', codec: 'eac3', channels: 6),
        ],
      );
      expect(aligned, hasLength(1));
      // 内核兜底会拼出 "6ch · eac3"（声道 + 编解码，足以区分多条轨）
      expect(aligned[0].label, contains('6ch'));
      expect(aligned[0].label, contains('eac3'));
      expect(aligned[0].kernelId, '1');
    });

    test('内核信息也缺失 → 用 id 生成非空标签（绝不空字符串）', () {
      final aligned = TrackAligner.alignAudio(
        const [],
        const [FacadeAudioTrack(id: '7')],
      );
      expect(aligned[0].label.trim().isNotEmpty, isTrue);
      expect(aligned[0].label, contains('7'));
    });
  });

  group('不变量', () {
    test('★ 输出条数 == 内核轨道数（不能丢轨，丢了就无法切换）', () {
      for (final kCount in [0, 1, 3, 8]) {
        final kernel = [
          for (var i = 0; i < kCount; i++)
            FacadeAudioTrack(id: '${i + 1}', ffIndex: i + 1),
        ];
        final server = [
          for (var i = 0; i < 3; i++) srv('Audio', i + 1, title: 'S${i + 1}'),
        ];
        final aligned = TrackAligner.alignAudio(server, kernel);
        expect(aligned, hasLength(kCount),
            reason: '内核有 $kCount 条，对齐后必须还是 $kCount 条');
      }
    });

    test('★ kernelId 唯一（否则 UI 无法区分、切换会选错）', () {
      final aligned = TrackAligner.alignAudio(
        [srv('Audio', 1, title: 'A'), srv('Audio', 2, title: 'B')],
        const [
          FacadeAudioTrack(id: '1', ffIndex: 1),
          FacadeAudioTrack(id: '2', ffIndex: 2),
        ],
      );
      final ids = aligned.map((a) => a.kernelId).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('★ 每条 label 非空（空标签 = 用户看到无字按钮）', () {
      final aligned = TrackAligner.alignAudio(
        [srv('Audio', 1)], // 服务端连 title 都没有
        const [FacadeAudioTrack(id: '1', ffIndex: 1)],
      );
      expect(aligned[0].label.trim().isNotEmpty, isTrue,
          reason: 'MediaStream.label 有兜底（type 名），不应为空');
    });

    test('空内核 → 空结果（不抛异常）', () {
      expect(TrackAligner.alignAudio([srv('Audio', 1)], const []), isEmpty);
      expect(TrackAligner.alignSubtitle([srv('Subtitle', 2)], const []),
          isEmpty);
    });
  });
}
