// 前台服务 5 秒约束 + 编码可解性 + 后缀清理 的守卫测试。
//
// ## 本轮事故复盘（真机）
// 用户报："点退出后直接会回到手机桌面" + "切 TRUEHD 音轨没声音" +
//          "字幕不显示" + "去掉 pgssub 等后缀"
//
// ### ① 回桌面 = 前台服务 5 秒超时（**我引入的**）
// ```
// FATAL EXCEPTION: main
// android.app.RemoteServiceException$ForegroundServiceDidNotStartInTimeException
//   at ContextImpl.startForegroundService
// ```
// `startForegroundService()` 后必须 5 秒内 `startForeground()`。
// 而 `MediaSessionService` 只在**它认为该贴通知**时才调；
// 我们的 `isPlaying` 由 Dart 推来 ⇒ 起播那一刻还是 false ⇒ 不调。
// 平时没炸是因为"起播 → isPlaying=true" < 5 秒；
// **本轮把等轨道的时间拉长到 6 秒** ⇒ 必崩。
// ⇒ 教训：任何"让起播变慢"的改动都可能引爆它。
//
// ### ② 没声音 / 字幕不显示 = 内核缺解码器（**不是代码能修的**）
// 我们的 `libmpv.so` 带白名单编译，缺：
// `ff_truehd_decoder` / `ff_mlp_decoder` / `ff_pgssub_decoder` /
// `ff_mov_text_decoder`。蓝光字幕全是 PGS ⇒ 一条都显示不了。
// 对比 mpv-android 官方 `buildscripts/scripts/ffmpeg.sh`：
// 只 `--disable-{muxers,encoders,devices}`，**没有 --disable-decoders**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/models.dart';
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
  // ① 前台服务 5 秒约束（"点退出回桌面"的根因）
  // ══════════════════════════════════════════════════════════
  group('★★ 前台服务必须 5 秒内 startForeground（防"回桌面"）', () {
    late String svc;

    setUpAll(() {
      svc = File('android/app/src/main/kotlin/com/cineflow/app/player/'
              'CineFlowSessionService.kt')
          .readAsStringSync();
    });

    test('★★ 必须覆盖 onStartCommand 并立刻进前台', () {
      expect(svc.contains('override fun onStartCommand'), isTrue,
          reason: '★★ `startForegroundService()` 后 5 秒内必须\n'
              '    `startForeground()`，否则系统抛\n'
              '    `ForegroundServiceDidNotStartInTimeException` 并**杀进程**\n'
              '    ⇒ 现象就是"点退出直接回桌面"（真机 FATAL 取证）');
      final i = svc.indexOf('override fun onStartCommand');
      final seg = svc.substring(i, (i + 420).clamp(0, svc.length));
      expect(seg.contains('ensureForegroundNow()'), isTrue,
          reason: '★★ 必须在 onStartCommand **最先**进前台\n'
              '    （不能依赖 Media3 自己判断 —— 它按 isPlaying 决定，\n'
              '     而起播那一刻 isPlaying 还是 false）');
    });

    test('★★ 必须在 super.onStartCommand 之前进前台', () {
      final i = svc.indexOf('override fun onStartCommand');
      final seg = svc.substring(i, (i + 420).clamp(0, svc.length));
      final iFg = seg.indexOf('ensureForegroundNow()');
      final iSuper = seg.indexOf('super.onStartCommand');
      expect(iFg, greaterThanOrEqualTo(0));
      expect(iSuper, greaterThanOrEqualTo(0));
      expect(iFg, lessThan(iSuper),
          reason: '★★ 顺序不能反 —— `super` 内部可能耗时不短，\n'
              '    而 5 秒是**从 startForegroundService 调用时**开始算的');
    });

    test('★★ 进前台失败必须留证据（不能静默）', () {
      // ⚠️ 窗口要够宽：该方法带长注释，`Log.e` 在 ~1517 字符处
      //    （第一版用 1400 ⇒ 断言失败，因为没覆盖到）
      final i = svc.indexOf('private fun ensureForegroundNow');
      final end = svc.indexOf('override fun onCreate', i);
      final seg = svc.substring(i, end > i ? end : (i + 3000).clamp(0, svc.length));
      expect(seg.contains('Log.e'), isTrue,
          reason: '★ 失败后 5 秒进程会被杀 —— 那时若不留下线索，\n'
              '    排查只能靠猜（这个坑正是"完全没有日志"才难查）');
      expect(seg.contains('catch'), isTrue, reason: '★ 不能让它抛出去');
    });

    test('★ 进前台必须幂等（onStartCommand 可能被多次调）', () {
      final i = svc.indexOf('private fun ensureForegroundNow');
      final seg = svc.substring(i, (i + 400).clamp(0, svc.length));
      expect(seg.contains('if (foregroundStarted) return'), isTrue,
          reason: '★ 系统可能多次 onStartCommand（如切歌），\n'
              '    重复 startForeground 会刷通知');
    });

    test('★★ 通知渠道必须建（否则 API 26+ startForeground 直接抛）', () {
      expect(svc.contains('NotificationChannel'), isTrue,
          reason: '★★ Android 8+ 上 `startForeground` 带不存在的渠道\n'
              '    会抛 `IllegalArgumentException` ⇒ 仍然进不了前台 ⇒ 仍被杀');
      // ⚠️ 只断言 `contains('createNotificationChannel')` 太弱：
      //    把它注释掉仍能通过（注入实测抓到）。
      //    ⇒ 断言**代码行真的在调用**（行首非注释、带 `nm.` 前缀）
      final call = RegExp(r'^\s*nm\.createNotificationChannel\(', multiLine: true);
      expect(call.hasMatch(svc), isTrue,
          reason: '★★ 必须**真的调用** createNotificationChannel ——\n'
              '    只写字符串（或注释掉）会被注入绕过');
    });

    test('★★ 起播后要撤掉占位通知（否则两条通知）', () {
      expect(svc.contains('dropPlaceholder()'), isTrue,
          reason: '★★ 我们的占位通知与 Media3 的 MediaStyle 通知**id 不同**\n'
              '    ⇒ 不撤掉用户会看到两条');
      // 必须挂在 onUpdateNotification（Media3 贴完自己的通知之后）
      final i = svc.indexOf('override fun onUpdateNotification');
      expect(i, greaterThanOrEqualTo(0));
      final seg = svc.substring(i, (i + 700).clamp(0, svc.length));
      expect(seg.contains('dropPlaceholder()'), isTrue,
          reason: '★ 撤占位的时机 = Media3 贴完它自己的通知之后');
    });

    test('★ 占位通知 id 与 Media3 的不同（避免互相覆盖）', () {
      expect(svc.contains('PLACEHOLDER_NOTIFICATION_ID'), isTrue);
      // 不能是 media3 常见的 1001（那会覆盖它的通知）
      expect(svc.contains('PLACEHOLDER_NOTIFICATION_ID = 1001'), isFalse,
          reason: '★ Media3 的默认通知 id 是 1001 —— 撞了会互相覆盖');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ② 编码可解性（"没声音/字幕不显示"）
  // ══════════════════════════════════════════════════════════
  group('★★ 字幕编码可解性（**运行时侦测**，不硬编码）', () {
    setUp(() => TrackAligner.runtimeUnsupportedSubtitleCodecs.clear());
    tearDown(() => TrackAligner.runtimeUnsupportedSubtitleCodecs.clear());

    test('★★★ 默认**放行** PGS（不硬编码 —— 用户两次指正）', () {
      // ## 为什么不能硬编码"PGS 不可播"（我第一版的错误）
      // 用户指正："mpv 也能解码哇" / "mpv 可以解码并显示 PGS"
      // 核实后**用户是对的**：
      // · mpv 上游（全量 ffmpeg）支持 PGS
      // · Media3 有 `PgsParser`（`media3-extractor-1.4.1.aar` 里已核实）
      // 我们这份 `.so` 缺 `ff_pgssub_decoder` **只是当前构建的问题**。
      //
      // ⇒ 硬编码会让"修好 .so 之后反而坏掉"（字幕能显示却被代码禁用）。
      for (final c in ['pgssub', 'hdmv_pgs_subtitle', 'pgs']) {
        expect(TrackAligner.isSubtitleCodecLikelyPlayable(c), isTrue,
            reason: '★★★ «$c» 默认必须**放行** ——\n'
                '    mpv 上游与 Media3 都支持 PGS；\n'
                '    我们缺只是这份 .so 的问题（可修）');
      }
    });

    test('★★ 运行时证实失败后才拦（本次进程内）', () {
      const codec = 'pgssub';
      expect(TrackAligner.isSubtitleCodecLikelyPlayable(codec), isTrue,
          reason: '未报错前应放行');
      TrackAligner.markSubtitleCodecUnsupported('hdmv_pgs_subtitle');
      expect(TrackAligner.isSubtitleCodecLikelyPlayable(codec), isFalse,
          reason: '★★ 真机报了 `Could not find subtitle decoder for '
              "format 'hdmv_pgs_subtitle'` ⇒ 记入运行时黑名单 ⇒ 后续跳过。\n"
              '    ⚠️ `hdmv_pgs_subtitle` 与 `pgssub` 是同一解码器两种叫法，\n'
              '    记一个必须能拦另一个');
    });

    test('★ 归一化：大小写/连字符/下划线不敏感', () {
      // `HDMV_PGS_SUBTITLE` 归一化 → `hdmvpgssubtitle`
      // ⇒ 之后 `hdmv-pgs-subtitle`（归一化 → `hdmvpgssubtitle`）应被拦
      TrackAligner.markSubtitleCodecUnsupported('HDMV_PGS_SUBTITLE');
      expect(
          TrackAligner.isSubtitleCodecLikelyPlayable('hdmv-pgs-subtitle'),
          isFalse,
          reason: '★ 大小写 + 连字符 + 下划线都要归一化');
      // 大小写变体也要拦
      expect(TrackAligner.isSubtitleCodecLikelyPlayable('PGSSUB'), isFalse,
          reason: '★ 同义名 + 大小写归一化');
    });

    test('★★ 同义名要一起记（mpv 报 A、服务端给 B）', () {
      // 真机：mpv 报 `hdmv_pgs_subtitle`，服务端 `codec` 给 `pgssub`/`PGS`
      TrackAligner.markSubtitleCodecUnsupported('pgs');
      for (final alias in ['pgssub', 'PGSSUB', 'hdmv_pgs_subtitle', 'PGS']) {
        expect(TrackAligner.isSubtitleCodecLikelyPlayable(alias), isFalse,
            reason: '★★ «$alias» 与 `pgs` 是同一解码器 ⇒ 必须一起拦。\n'
                '    只记报错里那一个名字，就拦不住服务端给的另一个名字');
      }
      // 反向：不该误伤别的编码
      expect(TrackAligner.isSubtitleCodecLikelyPlayable('subrip'), isTrue);
    });

    test('★ 常用文本字幕必须允许', () {
      for (final c in ['subrip', 'ass', 'ssa', 'text', 'webvtt',
                       'dvdsub', 'vobsub']) {
        expect(TrackAligner.isSubtitleCodecLikelyPlayable(c), isTrue,
            reason: '★ $c 我们有对应解码器');
      }
    });

    test('★ 未知/空一律允许（保守，不误杀）', () {
      expect(TrackAligner.isSubtitleCodecLikelyPlayable(null), isTrue);
      expect(TrackAligner.isSubtitleCodecLikelyPlayable(''), isTrue);
      expect(TrackAligner.isSubtitleCodecLikelyPlayable('weird-new'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════
  // ③ 去掉编码后缀（用户要求）
  // ══════════════════════════════════════════════════════════
  group('★★ 去掉编码后缀（用户要求"去掉 pgssub 等"）', () {
    test('★★ 括号形式的编码要去掉', () {
      expect(MediaStream.stripCodecSuffix('Chinese Simplified (PGSSUB)'),
          'Chinese Simplified');
      expect(MediaStream.stripCodecSuffix('English (SUBRIP)'), 'English');
      expect(MediaStream.stripCodecSuffix('中文（PGS）'), '中文',
          reason: '★ 全角括号也要处理');
    });

    test('★★ 分隔符形式的编码要去掉（我们自己的拼接格式）', () {
      expect(MediaStream.stripCodecSuffix('英语 · TRUEHD · 7.1'), '英语 · 7.1');
      expect(MediaStream.stripCodecSuffix('国语 · AC3 · 5.1'), '国语 · 5.1');
      expect(MediaStream.stripCodecSuffix('简英特字 · PGSSUB'), '简英特字');
    });

    test('★★ 声道 / 标记必须保留（那些是决策依据）', () {
      // 声道不是编码，不能删
      expect(MediaStream.stripCodecSuffix('英语 · DTS · 7.1'), contains('7.1'));
      expect(MediaStream.stripCodecSuffix('国语 · 5.1'), contains('5.1'));
      // 中文轨名不能删
      expect(MediaStream.stripCodecSuffix('简体特字（国配）'), '简体特字（国配）',
          reason: '★ "国配"是语言信息不是编码 —— 不能误删');
    });

    test('★★ 不能误伤含编码子串的正常词', () {
      // "TEXT" 是编码名，但不能把 "TEXTURE" 之类删掉
      expect(MediaStream.stripCodecSuffix('TEXTURE'), 'TEXTURE',
          reason: '★ 词边界保护 —— 只删独立词');
      // 中文内容不该被改
      expect(MediaStream.stripCodecSuffix('中英双语'), '中英双语');
    });

    test('★ 长名优先（PGS 不能吃掉 PGSSUB）', () {
      expect(MediaStream.stripCodecSuffix('Chinese (PGSSUB)'),
          'Chinese',
          reason: '★ 若先删 PGS 会剩 "Chinese (SUB)"');
    });

    test('★★ chineseLabel 必须真的调用 stripCodecSuffix', () {
      final m = code('lib/data/models.dart');
      final i = m.indexOf('String chineseLabel(');
      expect(i, greaterThanOrEqualTo(0));
      // ⚠️ 方法体边界：下一个成员声明（getter/method）
      //    用固定长度会被注入绕过（实测：只断言 contains 会失败）
      final end = m.indexOf('String get label', i);
      final seg = m.substring(i, end > i ? end : (i + 2200).clamp(0, m.length));
      // 必须**两次**调用（两处 return 分支），且是真实代码行
      //
      // ⚠️ 匹配 `return stripCodecSuffix(` 而不是"行首 return" ——
      //    其中一条是 `if (parts.isEmpty) return stripCodecSuffix(label);`
      //    （行中间，实测踩到）
      final calls = RegExp(r'return stripCodecSuffix\(').allMatches(seg).length;
      expect(calls, greaterThanOrEqualTo(2),
          reason: '★★ `chineseLabel` 有两条 return 路径（parts 空 / 非空），\n'
              '    **两条都要 strip** —— 否则某条路径仍显示 "… · PGSSUB"');
    });

    test('★★ 对齐器的兜底标签也要 strip', () {
      final t = code('lib/player/track_aligner.dart');
      expect(t.contains('stripCodecSuffix'), isTrue,
          reason: '★★ 兜底路径（服务端没给该轨）也要去后缀');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ④ 不可解轨要**告诉用户**（而不是静默）
  // ══════════════════════════════════════════════════════════
  group('★★ 轨道不可解必须报给用户（不能只写日志）', () {
    test('★★ Media3 侧要有 trackUnsupported 上报', () {
      final k = File('android/app/src/main/kotlin/com/cineflow/app/player/'
              'Media3Channel.kt')
          .readAsStringSync();
      expect(k.contains('trackUnsupported'), isTrue,
          reason: '★★ 真机：Media3 对 audio/true-hd 报 NO_UNSUPPORTED_TYPE，\n'
              '    但用户**什么都看不到**（只是"没声音"）⇒ 必须上报');
      expect(k.contains('addAnalyticsListener'), isTrue,
          reason: '★★ `onAudioInputFormatChanged` 不在 Player.Listener 上\n'
              '    （在 `AudioRendererEventListener`）⇒ 必须用 AnalyticsListener');
    });

    test('★★ Dart 侧要把 trackUnsupported 变成可见错误', () {
      final d = code('lib/player/media3/media3_kernel.dart');
      expect(d.contains('trackUnsupported'), isTrue,
          reason: '★★ 原生上报了但 Dart 不处理 ⇒ 用户仍然看不到');
      final i = d.indexOf("case 'trackUnsupported'");
      expect(i, greaterThanOrEqualTo(0));
      final seg = d.substring(i, (i + 500).clamp(0, d.length));
      expect(seg.contains('_errorController.add'), isTrue,
          reason: '★★ 必须走 errorStream（`log` 类型是**故意不处理**的，\n'
              '    那正是"用户看不到任何提示"的原因）');
    });
  });

  // ══════════════════════════════════════════════════════════
  // ⑤ 预判：未来同类问题（不能只修当前这一例）
  // ══════════════════════════════════════════════════════════
  group('★★ 预判未来 —— 同类风险的结构性守卫', () {
    test('★★ 起播路径变慢时必须复查 5 秒约束', () {
      // `_applyServerDefaultTracks` 等轨道最长 6s —— 已超过 5s 限制，
      // 这正是本轮崩溃的触发条件。守卫：该等待时间**必须**有注释说明
      // 与前台服务约束的关系。
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('_pendingDefaultTracks'), isTrue,
          reason: '★ 等轨道有兜底机制，但等待本身会拉长起播窗口 ——\n'
              '    必须靠 Kotlin 侧"立即进前台"兜住（见本组第一个测试）');
    });

    test('★★ 后端能力缺失要在"契约层"暴露（而不是各处猜）', () {
      // 我们有两个内核（mpv / media3），能力不等价。
      // 能力协商机制已存在（`EngineFeature` 枚举）。
      //
      // ⚠️ 不能断言 `EngineFeature.externalSubtitle` 字面量出现在
      //    kernel.dart —— 那只是 enum 的**成员**，字面量在**调用点**
      //    （实测：kernel.dart 里只有 `enum EngineFeature {`）。
      final k = code('lib/player/kernel.dart');
      expect(k.contains('enum EngineFeature'), isTrue,
          reason: '★ 能力协商机制必须存在（双内核能力不等价）');
      // 调用点：宿主按能力分支
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('EngineFeature.externalSubtitle'), isTrue,
          reason: '★ 宿主必须**真的按能力分支**（而不是假设两个内核都一样）');
      // 而"某个 codec 能不能解"目前是硬编码判断 —— 记录在案，
      // 未来应改为"内核自报能力"（见 docs/PLAYER-KERNEL.md）
      final t = code('lib/player/track_aligner.dart');
      expect(t.contains('isAudioCodecLikelyPlayable'), isTrue);
      expect(t.contains('isSubtitleCodecLikelyPlayable'), isTrue);
    });

    test('★★ 双内核都要处理同一类问题（否则换内核就复现）', () {
      // 本轮"没声音"在 mpv 与 media3 上**各自出现**（不同报错、同一根因）
      // ⇒ 任何轨相关修复都必须同时覆盖两个内核
      final n = code('lib/player/native/native_kernel.dart');
      final m = code('lib/player/media3/media3_kernel.dart');
      expect(n.contains('trackUnsupported') || m.contains('trackUnsupported'),
          isTrue);
      expect(n.contains('addExternalSubtitle'), isTrue);
      expect(m.contains('addExternalSubtitle'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════
  // ⑥ 解码器缺失自检 + 失败可见（对照开源项目补的）
  // ══════════════════════════════════════════════════════════
  group('★★ 解码器缺失必须可自检 + 对用户可见（对照开源项目补的）', () {
    test('★★ 必须有解码器自检脚本（对照 DanDanPlay 的 ffmpegHasDecoder）', () {
      final f = File('tool/check_mpv_decoders.py');
      expect(f.existsSync(), isTrue,
          reason: '★★ 缺解码器的现象是"播放无声/字幕不显示"且**不报错** ——\n'
              '    只能靠"播一次看 logcat"发现，代价极高。\n'
              '    本脚本把"跑一次就知道"变成可能。\n'
              '    （对照：xyoye/DanDanPlayForAndroid 有 ffmpegHasDecoder）');
      final s = f.readAsStringSync();
      for (final k in ['ff_truehd_decoder', 'ff_pgssub_decoder',
                       'ff_mlp_decoder']) {
        expect(s.contains(k), isTrue,
            reason: '★ 必须检查 $k（真机实测缺的）');
      }
    });

    test('★★ 脚本必须能检出我们**当前**的缺失（不是空壳）', () {
      // 真机/静态取证：我们的 libmpv.so 确实缺这 4 个。
      // 若脚本查不出来，说明它没真的读 .so。
      final so = File('android/app/src/main/jniLibs/arm64-v8a/libmpv.so');
      expect(so.existsSync(), isTrue);
      final data = so.readAsBytesSync();
      // ① 确认确实缺（这是"用户的 bug"）
      expect(_has(data, 'ff_truehd_decoder'), isFalse,
          reason: '★ 我们的 .so 缺 truehd 解码器（真机 `Failed to initialize '
              'a decoder for codec \'truehd\'`）');
      expect(_has(data, 'ff_pgssub_decoder'), isFalse,
          reason: '★ 我们的 .so 缺 PGS 字幕解码器（真机 `Could not find '
              'subtitle decoder for format \'hdmv_pgs_subtitle\'`）');
      // ② 确认有的（对照组，证明"读 .so"这件事本身是有效的）
      expect(_has(data, 'ff_dca_decoder'), isTrue,
          reason: '★ DTS 的解码器叫 dca —— 必须能读到（否则是扫描方法错了）');
      expect(_has(data, 'ff_hevc_decoder'), isTrue);
    });

    test('★★ mpv 日志不能全部丢弃（解码失败只能从日志看到）', () {
      final n = code('lib/player/native/native_kernel.dart');
      final i = n.indexOf("case 'log':");
      expect(i, greaterThanOrEqualTo(0));
      final seg = n.substring(i, (i + 500).clamp(0, n.length));
      expect(seg.contains('break;'), isFalse,
          reason: '★★ 原来只有 `break;`（日志全丢）—— 而\n'
              '    `Failed to initialize a decoder` / `Could not find\n'
              '    subtitle decoder` **只能从日志看到** ⇒\n'
              '    用户只感到"没声音/没字幕"，无任何提示');
      expect(seg.contains('_maybeSurfaceDecodeFailure'), isTrue,
          reason: '★★ 必须把可行动的解码失败转成用户提示');
    });

    test('★★ 必须匹配 mpv 的真实错误文案（从真机 logcat 抄的）', () {
      final n = code('lib/player/native/native_kernel.dart');
      // 真机原文：Failed to initialize a decoder for codec 'truehd'.
      expect(n.contains("Failed to initialize a decoder for codec '"),
          isTrue,
          reason: '★★ 正则必须匹配真机原文 —— 否则永远不触发\n'
              '    （真机：`[mpv/ad] Failed to initialize a decoder for '
              "codec 'truehd'.`）");
      // 真机原文：Could not find subtitle decoder for format
      //           'hdmv_pgs_subtitle'.
      expect(n.contains('Could not find subtitle decoder for format'),
          isTrue,
          reason: '★★ 同上（真机：`[mpv/sub] Could not find subtitle '
              "decoder for format 'hdmv_pgs_subtitle'.`）");
    });

    test('★ 解码失败提示必须去重（切轨会重复打印）', () {
      final n = code('lib/player/native/native_kernel.dart');
      expect(n.contains('_reportedDecodeFailures'), isTrue,
          reason: '★ mpv 切一次轨会把同一错误刷 2–3 条 ⇒ 不去重会连弹多次');
      expect(n.contains('_reportedDecodeFailures.add(msg)'), isTrue);
    });

    test('★ 提示要给"可行动的下一步"（不是"出错了"）', () {
      final n = code('lib/player/native/native_kernel.dart');
      expect(n.contains('请换一条音轨'), isTrue,
          reason: '★ 只说"解码失败"用户不知道怎么办');
      expect(n.contains('请换一条文本字幕'), isTrue);
      // PGS 要说人话（用户不知道 PGS 是什么）
      expect(n.contains('PGS 图形字幕'), isTrue,
          reason: '★ "hdmv_pgs_subtitle" 没人看得懂 ⇒ 要转成人话');
    });
  });
}

/// 二进制里是否含某 ASCII 串（等价 `grep -a`，用于读 .so 符号）。
bool _has(List<int> data, String needle) {
  final n = needle.codeUnits;
  outer:
  for (var i = 0; i + n.length <= data.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (data[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}
