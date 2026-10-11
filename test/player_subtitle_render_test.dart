// 字幕显示通路守卫（真机报障："字幕还是没有显示出在画面中"）。
//
// ## 守护的完整链路（任一环断裂 = 用户看不到字幕）
// ```
//  [1] Media3 有 PgsParser（依赖齐）
//  [2] setSubtitleParserFactory 开启了内嵌字幕解析
//  [3] onCues 把 cue 上报原生 → Dart（emitCues）
//  [4] Dart 侧 kernel.cuesStream 暴露 cue
//  [5] 宿主订阅 + setState（带指纹去重）
//  [6] subtitleLayer 传进 PlayerPageSlots
//  [7] PlayerUiPage 真的把它叠进 Stack（且在弹幕之下）
//  [8] SubtitleOverlay 限制在**画面矩形**内（不能铺满屏）
//  [9] mpv 内核**不**走这条（否则画两遍）
// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cineflow/player/kernel.dart';

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
  group('★★★ 字幕显示链路（九个环节，缺一用户就看不到）', () {
    test('★★★ [1] 必须引 media3-exoplayer-hls（否则 Media3 打不开文件）', () {
      final g = File('android/app/build.gradle.kts').readAsStringSync();
      expect(g.contains('media3-exoplayer-hls'), isTrue,
          reason: '★★★ 真机取证：`ClassNotFoundException: '
              r'HlsMediaSource$Factory` at Media3Channel.open'
              '\n    ⇒ 切 Media3 后**黑屏 + 时长 00:00**。\n'
              '    `DefaultMediaSourceFactory` 按 MIME **反射**建 source，\n'
              '    编译期不报错、运行期才炸');
    });

    test('★★★ [2] 必须显式开启内嵌字幕解析', () {
      final k = code('android/app/src/main/kotlin/com/cineflow/app/'
          'player/Media3Channel.kt');
      expect(k.contains('setSubtitleParserFactory'), isTrue,
          reason: '★★★ Media3 1.4 起字幕处理**延迟到 SubtitleParser**；\n'
              '    不设 ⇒ 字幕轨**列得出来但不产出 cue**\n'
              '    （真机：面板 8 条字幕都在，画面里一条都没有）');
      // ⚠️ API 名不带 experimental 前缀（我按记忆写错过）
      expect(k.contains('experimentalSetSubtitleParserFactory'), isFalse,
          reason: '★★ 真实签名是 `setSubtitleParserFactory`（已用 javap\n'
              '    从 media3-exoplayer-1.4.1.aar 核实）——\n'
              '    `experimental` 前缀是我按记忆写错的，编译直接 Unresolved');
      expect(k.contains('DefaultSubtitleParserFactory'), isTrue,
          reason: '★ 用总厂（按 MIME 分派 PgsParser/SubripParser/…）');
    });

    test('★★★ [3] onCues 必须上报（否则 cue 烂在原生侧）', () {
      final k = code('android/app/src/main/kotlin/com/cineflow/app/'
          'player/Media3Channel.kt');
      expect(k.contains('override fun onCues('), isTrue,
          reason: '★★★ Media3 解析出 cue 后**等外部绘制**；\n'
              '    本项目不引 media3-ui（视频走 Flutter 纹理）⇒\n'
              '    不上报的话 cue 就烂在原生侧，画面永远空白');
      // 位图必须转 PNG（Cue.bitmap 是 android.graphics.Bitmap）
      expect(k.contains('CompressFormat.PNG'), isTrue,
          reason: '★ 跨 MethodChannel 只能传字节 ⇒ 位图转 base64 PNG');
      // 空 cue 也要发（清屏信号）
      expect(k.contains("put(\"type\", \"cues\")"), isTrue);
    });

    test('★★★ [4] Dart 侧必须暴露 cuesStream 并解析', () {
      final m = code('lib/player/media3/media3_kernel.dart');
      expect(m.contains("case 'cues':"), isTrue,
          reason: '★★★ 原生发了 cues 事件，Dart 不接就等于没发');
      expect(m.contains('Stream<List<SubtitleCue>> get cuesStream'), isTrue);
      expect(m.contains('base64Decode'), isTrue,
          reason: '★ 位图是 base64 PNG');
    });

    test('★★★ [5] 宿主必须订阅 + 去重', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('kernel.cuesStream.listen'), isTrue,
          reason: '★★★ 订了才有数据；不订则整条链路到此为止');
      expect(p.contains('_fingerprintOf'), isTrue,
          reason: '★★ PGS 逐帧发 cue，连续帧常相同 ——\n'
              '    不去重会每帧 setState 整页（控制层/面板全重算）');
    });

    test('★★★ [6][7] 层必须传进 slots 且真的叠进 Stack', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('subtitleLayer:'), isTrue,
          reason: '★★★ 传了宿主才画得出来');
      final ui = code('lib/player/presentation/player_ui_page.dart');
      expect(ui.contains('widget.slots.subtitleLayer'), isTrue,
          reason: '★★★ **slots 里定义了但没渲染 = 等于没做**\n'
              '    （本项目反复踩过"定义了不接线"的坑）');
    });

    test('★★★ [7b] 字幕必须在弹幕**之下**（次序）', () {
      final ui = code('lib/player/presentation/player_ui_page.dart');
      final iSub = ui.indexOf('widget.slots.subtitleLayer');
      final iDm = ui.indexOf('widget.slots.danmakuLayer');
      expect(iSub, greaterThanOrEqualTo(0));
      expect(iDm, greaterThanOrEqualTo(0));
      expect(iSub, lessThan(iDm),
          reason: '★★ Stack 中**后者在上** ⇒ 字幕必须先出现。\n'
              '    弹幕压字幕符合 B 站观感（且弹幕层已按 safeArea 避让字幕行）');
    });

    test('★★★ [8] 字幕层必须限制在**画面矩形**内', () {
      final s = code('lib/player/presentation/subtitle_overlay.dart');
      expect(s.contains('LayoutBuilder'), isTrue,
          reason: '★★★ 若铺满整屏，竖屏看 16:9 时字幕会飘在**上下黑边**上\n'
              '    （与弹幕层踩过的同一个坑）');
      expect(s.contains('IgnorePointer'), isTrue,
          reason: '★ 字幕层不能吃手势（否则挡掉控制层点击）');
    });

    test('★★★ [8b] 图形字幕尺寸必须按**官方比例字段**（不能按位图像素拉伸）', () {
      final s = code('lib/player/presentation/subtitle_overlay.dart');
      // ## 这条断言在真机取证后被改写（原断言是错的）
      // 原断言：`s.contains('vr.width / img.width')` —— 我当时以为
      // "按视频区宽度缩放 + 保持位图宽高比"是对的。
      //
      // **真机截图证明它错了**：实测 PGS 位图是 `484x113`（已被裁切），
      // 按 `vr.width / img.width` 会**放大 3.97 倍** ⇒ 高度 449px
      // ⇒ 超出画面底部**被裁**（用户报"字幕的大小也有问题"）。
      //
      // ⇒ 正确做法：用 `Cue.size` / `Cue.bitmapHeight`（**视口比例**），
      //   这是 Media3 官方 `SubtitlePainter.setupBitmapLayout` 的公式。
      expect(s.contains('vr.width * sizeRatio'), isTrue,
          reason: '★★★ 宽度 = `parentWidth * cue.size`（官方公式）');
      expect(s.contains('vr.height * bh'), isTrue,
          reason: '★★★ 高度 = `parentHeight * cue.bitmapHeight`（官方公式）');
      expect(s.contains('vr.width / img.width'), isFalse,
          reason: '★★★ 这就是被裁的根因（484px 拉到 1920px，放大 3.97 倍）\n'
              '    真机截图：英文行下缘被画面底边切掉');
    });

    test('★★★ [9] mpv 内核**不能**走这条路（否则画两遍）', () {
      final n = code('lib/player/native/native_kernel.dart');
      expect(n.contains('Stream<List<SubtitleCue>> get cuesStream'), isTrue);
      // mpv 的 cuesStream 必须是空流
      final i = n.indexOf('cuesStream');
      final seg = n.substring(i, (i + 200).clamp(0, n.length));
      expect(seg.contains('Stream.empty'), isTrue,
          reason: '★★★ mpv 把字幕画进**视频帧**（vo=gpu 的 OSD）⇒\n'
              '    纹理像素里已含字幕。再叠一层会**画两遍**（且有重影）');
    });
  });

  group('★★★ 字幕尺寸：必须用官方公式（真机截图取证：被放大裁切）', () {
    test('★★★ PGS 位图是**裁切后的小图**，不能按"铺满画面宽"缩放', () {
      // ## 真机取证（用户报"字幕的大小也有问题"）
      // 实测 cue 位图尺寸：`484x113` / `351x104` / `1281x113`
      // —— **不是**整幅构图平面（1920×1080），而是 Media3 的
      // `PgsParser` 按需**裁掉透明边**后的小图。
      //
      // ## 我第一版的错误
      // `scale = 视频宽 / 位图宽` ⇒ 484px 的图被拉伸 **3.97 倍**到整屏宽
      // ⇒ 高度变成 449px ⇒ **超出画面底部被裁**（截图确认英文行被切）。
      //
      // ⇒ 必须用 cue 自带的**视口比例**字段（`size`/`bitmapHeight`）。
      final s = File('lib/player/presentation/subtitle_overlay.dart')
          .readAsStringSync();
      final code = s
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      // 官方公式：parentWidth * size
      expect(code.contains('vr.width * sizeRatio'), isTrue,
          reason: '★★★ 宽度必须按官方 `parentWidth * cue.size`，\n'
              '    而不是 `vr.width / img.width` 那种"铺满"式缩放');
      expect(code.contains('vr.height * bh'), isTrue,
          reason: '★★★ 高度必须按官方 `parentHeight * cue.bitmapHeight`');
      // 绝不能再用"位图铺满宽"
      expect(code.contains('vr.width / img.width'), isFalse,
          reason: '★★★ 这就是被裁的根因（484px → 1920px，放大 3.97 倍）');
    });

    test('★★★ 必须有夹取（任何情况下不得超出画面）', () {
      final s = File('lib/player/presentation/subtitle_overlay.dart')
          .readAsStringSync();
      final code = s
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains('if (top + height > vr.bottom) top = vr.bottom - height;'),
          isTrue,
          reason: '★★★ 兜底夹取：字段缺失/异常时也不能让字幕被裁 ——\n'
              '    这是用户实际看到的症状');
      expect(code.contains('if (left + width > vr.right) left = vr.right - width;'),
          isTrue);
    });

    test('★★★ [8c] Stack 必须 `expand`（否则整体不显示，真机回归）', () {
      final s = code('lib/player/presentation/subtitle_overlay.dart');
      // ## 真机回归（用户报"字幕显示还是有问题"，截图里完全没有字幕）
      // 我把渲染层从 `SizedBox.expand` 改成 `LayoutBuilder + Stack` 后
      // 字幕**整体消失**。
      //
      // 根因（Flutter 布局语义）：只含 `Positioned` 子项的 `Stack`
      // **没有非定位子项**，尺寸会**塌成 0×0**
      //（`StackFit.loose` 下按子项算，而 `Positioned` 不参与尺寸计算）
      // ⇒ Stack 高宽为 0 ⇒ **所有子项被裁掉**。
      //
      // ⚠️ 这个 bug **不报错、不崩溃**，只是"什么都没有" —— 极难排查。
      //    反向注入自查时也没抓到（因为没有断言）。
      expect(s.contains('fit: StackFit.expand'), isTrue,
          reason: '★★★ 少了它 ⇒ Stack 塌成 0×0 ⇒ 字幕全被裁\n'
              '    （真机表现：cue 日志正常但画面里一条字幕都没有）');
    });

    test('★★★ [8d] 字幕必须贴**底部中间**（用户明确要求）', () {
      final s = code('lib/player/presentation/subtitle_overlay.dart');
      // 用户原话："字幕应该放置底部的中间"
      expect(s.contains('left = vr.left + (vr.width - width) / 2;'), isTrue,
          reason: '★★★ 水平必须居中');
      expect(s.contains('top = vr.bottom - height - bottomPad;'), isTrue,
          reason: '★★★ 垂直必须贴底部（留一点边距）');
      expect(s.contains('final bottomPad = vr.height * 0.03;'), isTrue,
          reason: '★ 底部留 3% 边距（与主流播放器一致）');
    });

    test('★★ 降级链必须存在（缺 bitmapHeight 时仍能画）', () {
      final s = File('lib/player/presentation/subtitle_overlay.dart')
          .readAsStringSync();
      final code = s
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      // 官方兜底分支：`width * (bitmap.h / bitmap.w)`
      expect(code.contains('width * (img.height / img.width)'), isTrue,
          reason: '★★ 缺 `bitmapHeight` 时按位图宽高比等比\n'
              '    （与官方 `SubtitlePainter` 的兜底分支一致）');
    });
  });

  group('★★★ cue 必须带视口比例字段（否则尺寸不可知）', () {
    test('★★★ SubtitleCue 必须有 size / bitmapHeight', () {
      // 只有位图像素时，"该画多大"是**不可知**的
      //（PGS 位图已被裁切，像素尺寸 ≠ 显示尺寸）
      const c = SubtitleCue();
      expect(c.size, isNull);
      expect(c.bitmapHeight, isNull);
      // 构造时必须能带上
      const c2 = SubtitleCue(size: 0.67, bitmapHeight: 0.1);
      expect(c2.size, 0.67);
      expect(c2.bitmapHeight, 0.1);
    });

    test('★★★ Kotlin 必须上报 size / bitmapHeight', () {
      final k = File('android/app/src/main/kotlin/com/cineflow/app/player/'
          'Media3Channel.kt').readAsStringSync();
      final code = k
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains('put("size", cue.size.toDouble())'), isTrue,
          reason: '★★★ 不上报 size ⇒ Dart 侧不知道"该画多宽"');
      expect(code.contains('put("bitmapHeight", cue.bitmapHeight.toDouble())'),
          isTrue,
          reason: '★★★ 不上报 bitmapHeight ⇒ 高度只能靠位图像素猜');
    });

    test('★★★ Kotlin 必须把 DIMEN_UNSET 转成"不发送"', () {
      // ⚠️ `DIMEN_UNSET` 是 `Float.MIN_VALUE`（≈1.4e-45）；
      //    直接传给 Dart 会被当成"极小比例" ⇒ 尺寸算成 0（字幕消失）
      final k = File('android/app/src/main/kotlin/com/cineflow/app/player/'
          'Media3Channel.kt').readAsStringSync();
      final code = k
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains('Cue.DIMEN_UNSET'), isTrue,
          reason: '★★★ 必须判断 DIMEN_UNSET —— 否则传过去的是 1.4e-45，\n'
              '    Dart 侧算出 0 尺寸，字幕直接看不见');
    });

    test('★★ Dart 侧必须解析这些字段', () {
      final m = File('lib/player/media3/media3_kernel.dart')
          .readAsStringSync();
      final code = m
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains("size: (m['size'] as num?)?.toDouble()"), isTrue);
      expect(code.contains("bitmapHeight: (m['bitmapHeight'] as num?)?.toDouble()"),
          isTrue);
    });
  });

  group('★ 中立模型 SubtitleCue', () {
    test('★ isEmpty 的语义（既无文本也无位图）', () {
      expect(const SubtitleCue().isEmpty, isTrue);
      expect(const SubtitleCue(text: '你好').isEmpty, isFalse);
      expect(const SubtitleCue(text: '').isEmpty, isTrue,
          reason: '★ 空串等于没内容（解析侧会过滤）');
    });
  });
}
