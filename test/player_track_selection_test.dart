// "没声音 / 字幕不显示 / 中文轨道名" 三项修复的守卫测试。
//
// ## 事故复盘（本轮的真实教训）
// 上一轮修好 `parseTracks`（逐条兜底）后，**三个隐藏问题同时显形**：
//
// ① **`id` 是 "1.0" 不是 "1"**
//    cpp 把 `MPV_FORMAT_INT64` 交给 `%.6f` ⇒ `1.000000` ⇒ Dart `"1.0"`
//    ⇒ `mpv_setPropertyString("aid", "1.0")` 是**非法值**
//
// ② **服务端默认音轨是内核解不了的编码**
//    服务端 `DefaultAudioStreamIndex=1` = English **TRUEHD** 7.1
//    ⇒ `[mpv/ad] Failed to initialize a decoder for codec 'truehd'`
//    ⇒ `Audio: no audio`（播放无声）
//    **为什么以前有声**：解析 bug 让轨道恒为空 ⇒ 选轨逻辑从不执行
//    ⇒ mpv 用自己的策略（跳过了 truehd）⇒ 恰好有声。
//
// ③ **服务端 `DefaultSubtitleStreamIndex = null` ⇒ 字幕完全不选**
//    ⇒ 画面里没有任何字幕（用户报"字幕没有显示在画面中"）
//
// ④ **轨道名是英文**（服务端 `DisplayTitle` 给 `English TRUEHD 7.1`）
//    而 mpv 侧有更好的中文名（`国语`/`简英特字`）却没被用上
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/language_names.dart';
import 'package:cineflow/data/models.dart';
import 'package:cineflow/player/kernel_event_parser.dart';
import 'package:cineflow/player/player_facade.dart';
import 'package:cineflow/player/track_aligner.dart';

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
  // ══════════════════════════════════════════════════════════
  // ① 轨道 id 必须是整数字符串（"没声音"的直接原因）
  // ══════════════════════════════════════════════════════════
  group('★★ 轨道 id 必须是整数（防"aid 非法 ⇒ 没声音"）', () {
    test('★★ "1.0"（浮点形状）必须归一化成 "1"', () {
      final r = KernelEventParser.parseTracks(<Map<String, dynamic>>[
        {'id': 1.0, 'type': 'audio', 'ff-index': 1.0},
        {'id': 2.000000, 'type': 'audio', 'ff-index': 2.0},
      ]);
      expect(r.audio.length, 2);
      expect(r.audio[0].id, '1',
          reason: '★★ cpp 的 `%.6f` 会把 INT64 变成 `1.000000` ⇒ Dart 得到\n'
              '    "1.0"。而 mpv 的 aid 只接受整数 ⇒ 传 "1.0" 会让音频被关\n'
              '    （真机：`Audio: no audio`）。');
      expect(r.audio[1].id, '2');
    });

    test('★★ 整数入参保持原样（不能引入 "1.0"）', () {
      final r = KernelEventParser.parseTracks(<Map<String, dynamic>>[
        {'id': 3, 'type': 'sub', 'ff-index': 3},
      ]);
      expect(r.subtitle.first.id, '3');
    });

    test('★ 字符串数字也归一化（"1.0" → "1"）', () {
      final r = KernelEventParser.parseTracks(<Map<String, dynamic>>[
        {'id': '1.0', 'type': 'audio'},
        {'id': '7', 'type': 'audio'},
      ]);
      expect(r.audio[0].id, '1');
      expect(r.audio[1].id, '7');
    });

    test('★ 非数字 id 不被破坏（Media3 可能给自定义串）', () {
      final r = KernelEventParser.parseTracks(<Map<String, dynamic>>[
        {'id': 'track-a', 'type': 'audio'},
      ]);
      expect(r.audio.first.id, 'track-a',
          reason: '★ 只在"确实能解析成整数"时才归一化');
    });

    test('★★ 内核侧也要校验（最后一道防御）', () {
      final n = code('lib/player/native/native_kernel.dart');
      expect(n.contains('_safeTrackId'), isTrue,
          reason: '★★ mpv 的 aid/sid 只接受整数/auto/no ——\n'
              '    内核必须自己校验，不能信任上游（"没声音"比"没切轨"严重）');
      expect(n.contains('拒绝非法 aid'), isTrue);
      expect(n.contains('拒绝非法 sid'), isTrue);
    });

    test('★★ cpp 的 INT64 必须走整数序列化', () {
      final c = File('android/app/src/main/cpp/cineflow_mpv.c')
          .readAsStringSync();
      expect(c.contains('sb_json_int'), isTrue,
          reason: '★★ 新增了整数序列化函数');
      // 关键：INT64 分支不能再调 sb_json_number
      final i = c.indexOf('case MPV_FORMAT_INT64:');
      expect(i, greaterThanOrEqualTo(0));
      final seg = c.substring(i, (i + 260).clamp(0, c.length));
      expect(seg.contains('sb_json_int('), isTrue,
          reason: '★★ INT64 必须用 sb_json_int —— 走 %.6f 会造出 "1.0"');
      expect(seg.contains('sb_json_number(sb, (double)'),
          isFalse,
          reason: '★★ 旧的 `sb_json_number((double)node->u.int64)` 必须已删除');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ② 音频编码可解码性（"没声音"的根因）
  // ══════════════════════════════════════════════════════════
  group('★★ 选音轨必须跳过内核解不了的编码', () {
    test('★★ TRUEHD 必须判为不可解（真机实测）', () {
      expect(TrackAligner.isAudioCodecLikelyPlayable('truehd'), isFalse,
          reason: '★★ 真机日志：\n'
              '    `[mpv/ad] Failed to initialize a decoder for codec \'truehd\'.`\n'
              '    ⇒ Android 上 TRUEHD 解不了');
      expect(TrackAligner.isAudioCodecLikelyPlayable('mlp'), isFalse);
    });

    test('★ 常用编码必须允许', () {
      for (final c in ['aac', 'ac3', 'eac3', 'mp3', 'opus', 'flac', 'dts']) {
        expect(TrackAligner.isAudioCodecLikelyPlayable(c), isTrue,
            reason: '★ $c 应允许（Android 可解）');
      }
    });

    test('★ 未知/空编码一律允许（保守，不误杀）', () {
      expect(TrackAligner.isAudioCodecLikelyPlayable(null), isTrue);
      expect(TrackAligner.isAudioCodecLikelyPlayable(''), isTrue);
      expect(TrackAligner.isAudioCodecLikelyPlayable('something-new'), isTrue,
          reason: '★ 宁可让内核试，也不要因误判挡掉用户能播的轨');
    });

    test('★ 大小写与连字符不敏感', () {
      expect(TrackAligner.isAudioCodecLikelyPlayable('TRUEHD'), isFalse);
      expect(TrackAligner.isAudioCodecLikelyPlayable('DTS-HD'), isFalse);
      expect(TrackAligner.isAudioCodecLikelyPlayable('E-AC3'), isTrue);
    });

    test('★★ 首选轨不可解时要退到**同语言**可解轨', () {
      // 真机场景：服务端默认 = English TRUEHD（不可解）
      //           ⇒ 应退到 English DTS（同语言、可解）
      final aligned = [
        const AlignedTrack(
            kernelId: '1', label: '英语 · TRUEHD', isDefault: true,
            language: 'eng', codec: 'truehd'),
        const AlignedTrack(
            kernelId: '3', label: '英语 · DTS', language: 'eng', codec: 'dts'),
        const AlignedTrack(
            kernelId: '4', label: '国语 · DTS', language: 'chi', codec: 'dts'),
      ];
      final pick = TrackAligner.pickPlayableAudio(
        aligned,
        preferred: aligned.first,
        codecOf: (t) => t.codec,
      );
      expect(pick?.kernelId, '3',
          reason: '★★ 保住"想听英语"的意图：退到**同语言**的可解轨');
    });

    test('★ 首选可解时不动它（尊重服务端/用户选择）', () {
      final aligned = [
        const AlignedTrack(
            kernelId: '5', label: '英语 · AC3', isDefault: true,
            language: 'eng', codec: 'ac3'),
        const AlignedTrack(
            kernelId: '6', label: '国语 · AC3', language: 'chi', codec: 'ac3'),
      ];
      final pick = TrackAligner.pickPlayableAudio(
        aligned, preferred: aligned.first, codecOf: (t) => t.codec);
      expect(pick?.kernelId, '5');
    });

    test('★★ 全部不可解 ⇒ 返回 null（不设 aid，交给 mpv）', () {
      final aligned = [
        const AlignedTrack(kernelId: '1', label: 'a', codec: 'truehd'),
        const AlignedTrack(kernelId: '2', label: 'b', codec: 'mlp'),
      ];
      final pick = TrackAligner.pickPlayableAudio(
        aligned, preferred: aligned.first, codecOf: (t) => t.codec);
      expect(pick, isNull,
          reason: '★★ 硬设一条解不了的 aid 会直接导致"没声音"；\n'
              '    不设则 mpv 自己会试（比我们瞎设强）');
    });

    test('★★ 宿主必须真的用这个过滤（否则是死代码）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('pickPlayableAudio'), isTrue,
          reason: '★★ 定义了不用 ⇒ 仍然会选 TRUEHD ⇒ 仍然没声音');
      expect(p.contains('不可解'), isTrue, reason: '★ 要有可查日志');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ③ 字幕自动选中（"字幕没显示在画面中"的根因）
  // ══════════════════════════════════════════════════════════
  group('★★ 服务端没默认字幕时要自动选（防"字幕不显示"）', () {
    test('★★ 中文轨优先（用户是中文用户）', () {
      final aligned = [
        const AlignedTrack(kernelId: '1', label: '英字 · PGSSUB'),
        const AlignedTrack(kernelId: '2', label: '简英特字 · PGSSUB'),
        const AlignedTrack(kernelId: '3', label: '繁體中字 · PGSSUB'),
      ];
      final pick = TrackAligner.autoPickSubtitle(aligned);
      expect(pick?.kernelId, '2',
          reason: '★★ 应选中文轨（第一条命中的），不是第一条英文字幕');
    });

    test('★ forced 中文排在非 forced 之后', () {
      final aligned = [
        const AlignedTrack(kernelId: '1', label: '简体中字', isForced: true),
        const AlignedTrack(kernelId: '2', label: '繁體中字'),
      ];
      expect(TrackAligner.autoPickSubtitle(aligned)?.kernelId, '2',
          reason: '★ forced 通常只有外语对白（信息不全）⇒ 非 forced 优先');
    });

    test('★ 没有中文轨时选第一条非 forced', () {
      final aligned = [
        const AlignedTrack(kernelId: '1', label: 'English', isForced: true),
        const AlignedTrack(kernelId: '2', label: 'Twi'),
      ];
      expect(TrackAligner.autoPickSubtitle(aligned)?.kernelId, '2');
    });

    test('★ 空列表安全', () {
      expect(TrackAligner.autoPickSubtitle(const []), isNull);
    });

    test('★★ 识别中文的判据要够宽（label 可能全是中文别名）', () {
      for (final label in ['简体中字', '繁體中字', '简英特字', '繁英特字',
                           '简体特字（国配）', '中文', 'chi', 'CHS']) {
        final pick = TrackAligner.autoPickSubtitle([
          const AlignedTrack(kernelId: '9', label: 'English'),
          AlignedTrack(kernelId: '1', label: label),
        ]);
        expect(pick?.kernelId, '1', reason: '★ «$label» 应被识别为中文轨');
      }
    });

    test('★★ 宿主必须真的调用（否则字幕永远不选）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('autoPickSubtitle'), isTrue,
          reason: '★★ 服务端 `DefaultSubtitleStreamIndex` 常为 null\n'
              '    （真机实测《复仇者联盟》）⇒ 不自动选就**一条字幕都不显示**');
    });

    test('★★ 早退判断不能把字幕逻辑挡掉', () {
      final p = code('lib/player/player_flow_page.dart');
      final i = p.indexOf('Future<void> _applyServerDefaultTracks');
      expect(i, greaterThanOrEqualTo(0));
      final seg = p.substring(i, (i + 900).clamp(0, p.length));
      // 旧的早退：`if (wantAudio == null && wantSub == null) return;`
      // 会把"只有字幕没默认音频"的片源直接跳过
      expect(
          seg.contains('if (wantAudio == null && wantSub == null) return;'),
          isFalse,
          reason: '★★ 这个早退必须删掉 —— 它会让"没默认音频但有字幕"的片源\n'
              '    完全不选字幕');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ④ 轨道名中文化
  // ══════════════════════════════════════════════════════════
  group('★★ 轨道名必须是中文（用户明确要求）', () {
    test('★★ 语言码 → 中文（覆盖实测出现的那些）', () {
      expect(languageToChinese('chi'), '国语');
      expect(languageToChinese('zho'), '国语');
      expect(languageToChinese('eng'), '英语');
      expect(languageToChinese('chs'), '简体中文');
      expect(languageToChinese('cht'), '繁体中文');
      expect(languageToChinese('yue'), '粤语');
      expect(languageToChinese('twi'), '契维语',
          reason: '★ 真机实测出现过 Twi（繁体中字被误标成 twi）');
      // 大小写不敏感
      expect(languageToChinese('CHI'), '国语');
      expect(languageToChinese('English'), '英语');
    });

    test('★ 翻不出来时返回 null（不猜、不乱翻）', () {
      expect(languageToChinese(null), isNull);
      expect(languageToChinese(''), isNull);
      expect(languageToChinese('xyz-unknown'), isNull,
          reason: '★ 宁可显示原文，也不要假装是某种语言');
    });

    test('★★ 内核的中文名优先于语言码翻译', () {
      // 真机：内核给 `简英特字`，服务端给 `Chinese (PGSSUB)`
      // ⇒ 内核的名字更精确（压制组写的），必须优先
      final s = MediaStream(
        type: 'Subtitle',
        displayTitle: 'Chinese (PGSSUB)',
        language: 'chi',
      );
      expect(s.chineseLabel(kernelTitle: '简英特字'),
          contains('简英特字'),
          reason: '★★ 内核标题（`简英特字`）比语言码翻译（`国语`）精确得多');
    });

    test('★ 没有内核标题时用语言码翻译', () {
      final s = MediaStream(
        type: 'Audio',
        displayTitle: 'Chinese TRUEHD 7.1',
        language: 'chi',
        codec: 'truehd',
      );
      final l = s.chineseLabel();
      expect(l, contains('国语'), reason: '★ 英文语言名要换成中文');
      // ★ 2026-10-10 用户要求"音轨后缀也去除" ⇒ 编码不再出现在名字里
      expect(l, isNot(contains('TRUEHD')),
          reason: '★ 编码后缀要去掉（用户要求）—— 见 stripCodecSuffix');
    });

    test('★ 服务端独有的细节（编码/声道）要保留', () {
      final s = MediaStream(
        type: 'Audio',
        displayTitle: 'English AC3 5.1',
        language: 'eng',
        codec: 'ac3',
        channels: 6,
      );
      final l = s.chineseLabel();
      expect(l, contains('英语'));
      // ★ 编码去掉、**声道保留**（后者是用户能理解的音质信息）
      expect(l, isNot(contains('AC3')), reason: '★ 编码后缀要去掉');
      expect(l, contains('6ch'),
          reason: '★ 声道保留 —— "5.1/7.1" 是选轨决策依据');
    });

    test('★★ 对齐器必须用 chineseLabel（不是裸 label）', () {
      final t = code('lib/player/track_aligner.dart');
      expect(t.contains('chineseLabel'), isTrue,
          reason: '★★ 用裸 `label` ⇒ 面板显示 `English TRUEHD 7.1`（英文）');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ⑤ 时序兜底（轨道晚到时补做选轨）
  // ══════════════════════════════════════════════════════════
  group('★★ 轨道晚到时必须补做默认轨选择（时序兜底）', () {
    test('★★ 必须有 pending 机制', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('_pendingDefaultTracks'), isTrue,
          reason: '★★ 真机实测：`_applyServerDefaultTracks` 可能在内核上报\n'
              '    轨道**之前**跑（4K 片源 demuxer 分析要 3–5s）\n'
              '    ⇒ 它看到空列表、逻辑空转 ⇒ **没声音 + 没字幕**');
    });

    test('★★ tracksStream 回调里要补做', () {
      final p = code('lib/player/player_flow_page.dart');
      final i = p.indexOf('kernel.tracksStream.listen');
      expect(i, greaterThanOrEqualTo(0));
      final seg = p.substring(i, (i + 1200).clamp(0, p.length));
      expect(seg.contains('_pendingDefaultTracks'), isTrue,
          reason: '★★ 补做必须挂在 `tracksStream` 回调里 ——\n'
              '    那是**唯一保证"轨道已到达"**的时机');
    });

    test('★★ 换集时必须清掉 pending（防串轨）', () {
      final p = code('lib/player/player_flow_page.dart');
      final re = RegExp(r'_launch = launch;\s*'
          r'(?://[^\n]*\n\s*)*_pendingDefaultTracks = null;');
      expect(re.hasMatch(p), isTrue,
          reason: '★★ 换集后旧 launch 的默认轨编号已失效 ——\n'
              '    不清会用它去选**这一集**的轨道（选错轨）');
    });

    test('★ 过期的 launch 要被拒绝', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('identical(launch, _launch)'), isTrue,
          reason: '★ 换集后旧 launch 的异步任务可能才跑到 ⇒ 要校验');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ⑥ 对齐后要带上 language/codec（可解码性判断的前提）
  // ══════════════════════════════════════════════════════════
  group('★ 对齐结果必须带 language / codec', () {
    test('★★ 否则"跳过不可解编码"无从判断', () {
      final server = [
        MediaStream(
            type: 'Audio', displayTitle: 'English TRUEHD',
            language: 'eng', codec: 'truehd', index: 1),
        MediaStream(
            type: 'Audio', displayTitle: 'English DTS',
            language: 'eng', codec: 'dts', index: 3),
      ];
      final kernel = [
        const FacadeAudioTrack(id: '1', ffIndex: 1, codec: 'truehd'),
        const FacadeAudioTrack(id: '3', ffIndex: 3, codec: 'dts'),
      ];
      final aligned =
          TrackAligner.alignAudio(server, kernel, defaultIndex: 1);
      expect(aligned.length, 2);
      expect(aligned[0].codec, 'truehd',
          reason: '★★ 没有 codec 就无法判断"能不能解" ⇒ 会选到 TRUEHD');
      expect(aligned[0].language, 'eng',
          reason: '★ 没有 language 就无法"退到同语言可解轨"');
      expect(aligned[0].serverIndex, 1);
    });
  });
}
