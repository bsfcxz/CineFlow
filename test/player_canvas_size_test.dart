// 渲染画布尺寸（"画面被压扁"根因）的守卫测试。
//
// ## 用户报障原文
// > "竖屏的这个画面窗口你看下都成啥了"
//
// ## 根因链（真机实测 + 数学双验证）
// 1. 画布（Surface）**硬编码 1920×1080（16:9）**，由 `ensureTexture()` 默认值决定
// 2. mpv 的 `keepaspect`（默认 yes）把 2.388:1 的画面 **letterbox 进 16:9 画布**
//    ⇒ 黑边**烘焙进纹理**（内容只占 74.4% 高）
// 3. Dart 的 `AspectVideo` 又按 2.388 内接 ⇒ **非等比缩放**（画布 1.778 ≠ 框 2.389）
//    ⇒ 内容被横向拉伸
//
// ## 实测数据（片源 3840×1608，竖屏 1080×2400）
// | 状态 | 画面高 | 折算比例 | 偏差 |
// |---|---|---|---|
// | 修复前 | 335 px | 3.224 | 35% |
// | **修复后** | **450 px** | **2.400** | **0.5%** |
// | 理论 | 452 px | 2.388 | — |
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
  group('★★ 画布尺寸必须与片源同比例（防"画面被压扁"回归）', () {
    test('★★ 接口必须有 setSurfaceSize（否则画布恒为 16:9）', () {
      final k = code('lib/player/kernel.dart');
      expect(k.contains('Future<void> setSurfaceSize(int width, int height)'),
          isTrue,
          reason: '★★ 没有它 ⇒ 画布恒为 ensureTexture 的 1920x1080（16:9）\n'
              '    ⇒ 宽银幕片源被 mpv 二次 letterbox ⇒ 画面被压扁 35%。');
    });

    test('★★ 接口必须有 recreateTexture（光改尺寸/属性无效）', () {
      final k = code('lib/player/kernel.dart');
      expect(
          k.contains('Future<bool> recreateTexture({') &&
              k.contains('required int width') &&
              k.contains('required int height'),
          isTrue,
          reason: '★★ 真机实测：Surface 的 **buffer 尺寸在创建时固定**；\n'
              '    后续 setSurfaceSize / 改 mpv 属性都**不会**重建 buffer。\n'
              '    ⇒ 必须销毁 + 按正确尺寸重建纹理。');
    });

    test('★★ 两个内核都要实现（否则换内核画面比例跳变）', () {
      for (final f in [
        'lib/player/native/native_kernel.dart',
        'lib/player/media3/media3_kernel.dart',
      ]) {
        final s = code(f);
        expect(s.contains('Future<bool> recreateTexture'), isTrue,
            reason: '$f 缺 recreateTexture ⇒ 该内核下画面比例仍错');
      }
    });

    test('★ 重建必须按尺寸去重（同比例连播不闪）', () {
      for (final f in [
        'lib/player/native/native_kernel.dart',
        'lib/player/media3/media3_kernel.dart',
      ]) {
        final s = code(f);
        final i = s.indexOf('Future<bool> recreateTexture');
        expect(i, greaterThanOrEqualTo(0));
        final seg = s.substring(i, (i + 700).clamp(0, s.length));
        expect(seg.contains('_surfaceW == width && _surfaceH == height'),
            isTrue,
            reason: '$f 的重建没有去重 ⇒ 同比例片源连播会反复重建（闪烁）');
      }
    });

    test('★★ 重建必须**真的调用** createTexture（防退化成空操作）', () {
      // ## 为什么单独守这条（注入实测抓到）
      // 把去重判断改成 `if (true) return false;` ⇒ **从不重建**，
      // 但方法/字段/去重字符串都还在 ⇒ 只查"存在性"的断言全绿。
      // ⇒ 必须断言"方法体内**真的调了** createTexture 通道"。
      for (final f in [
        'lib/player/native/native_kernel.dart',
        'lib/player/media3/media3_kernel.dart',
      ]) {
        final s = code(f);
        final i = s.indexOf('Future<bool> recreateTexture');
        expect(i, greaterThanOrEqualTo(0), reason: '$f 找不到该方法');
        final end = s.indexOf('Future<void> ensureInitialized', i);
        final end2 = s.indexOf('Future<void> open(', i);
        var stop = (end > i) ? end : (end2 > i ? end2 : s.length);
        final seg = s.substring(i, stop);
        expect(seg.contains("invokeMethod<int>('createTexture'"), isTrue,
            reason: '★★ $f 的重建必须真的调 createTexture 通道 ——\n'
                '    否则画布永远停在 16:9（= 原始故障态），\n'
                '    而"存在性"断言会全绿（注入实测抓到）。');
        expect(seg.contains('return true'), isTrue,
            reason: '★ 真重建后要返回 true（宿主据此刷新 _textureId）');
        // ★★ 关键：防"不可达"退化（注入实测抓到）
        //
        // 把首个 guard 改成 `if (true) return false;` ⇒ createTexture
        // **代码还在但永远不执行** ⇒ 纯文本断言全绿。
        // 静态断言无法做可达性分析，但可以断言**首个 return 条件必须是
        // 尺寸去重**（而不是常量）—— 这是能守住的最近似性质。
        final firstIf = seg.indexOf('if (');
        expect(firstIf, greaterThanOrEqualTo(0),
            reason: '$f 的 recreateTexture 应有 guard');
        final firstIfLine =
            seg.substring(firstIf, seg.indexOf(')', firstIf) + 1);
        expect(firstIfLine.contains('width <= 0') ||
                firstIfLine.contains('_surfaceW'),
            isTrue,
            reason: '★★ $f 的**首个 guard 必须是尺寸判断**，不能是常量 ——\n'
                '    `if (true) return false;` 会让重建永远不执行，\n'
                '    而 createTexture 文本仍在（不可达代码）。\n'
                '    实测首个 if: `$firstIfLine`');
      }
    });

    test('★★ 宿主必须在**起播前**用片源尺寸重建画布', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('recreateTexture('), isTrue,
          reason: '★★ 不调它 ⇒ recreateTexture 是死代码，画布仍是 16:9');
      // 必须在 _startEpisode 里（拿到 launch.streams 之后、open 之前）
      final i = p.indexOf('Future<void> _startEpisode');
      expect(i, greaterThanOrEqualTo(0));
      final end = p.indexOf('Future<void> _playEpisode', i);
      final seg = end > i ? p.substring(i, end) : p.substring(i);
      expect(seg.contains('recreateTexture('), isTrue,
          reason: '★★ 必须在 _startEpisode 里 —— 那是"片源尺寸已知且未起播"\n'
              '    的唯一窗口（launch.streams 带 width/height）。');
    });

    test('★★ 尺寸来自 launch.streams（服务端元数据，不用解码）', () {
      final p = code('lib/player/player_flow_page.dart');
      final i = p.indexOf('Future<void> _startEpisode');
      final end = p.indexOf('Future<void> _playEpisode', i);
      final seg = end > i ? p.substring(i, end) : p.substring(i);
      expect(seg.contains("s.type == 'Video'"), isTrue,
          reason: '★ 从视频流取 width/height —— resolvePlayback 已解析，\n'
              '    起播前就有，**不需要等内核解码**（内核要 12.7s 才知道）');
      expect(seg.contains('first.width') && seg.contains('first.height'),
          isTrue);
    });

    test('★ 画布宽固定 1920（够清晰且不过大）', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('const canvasW = 1920;'), isTrue,
          reason: '★ 画布只是中转，最终显示尺寸由视口决定；\n'
              '    4K 画布的 GPU 纹理开销明显更大。');
    });

    test('★ 重建后要刷新 _textureId（否则渲染旧纹理）', () {
      final p = code('lib/player/player_flow_page.dart');
      final i = p.indexOf('recreateTexture(');
      final seg = p.substring(i, (i + 400).clamp(0, p.length));
      expect(seg.contains('_textureId'), isTrue,
          reason: '★ 重建后纹理 id 变了 —— 不刷新就仍渲染旧纹理（画面不变）');
    });

    test('★ 设置失败不得影响播放（非致命）', () {
      // ⚠️ 窗口要够宽：`setSurfaceSize` 的文档 + 实现跨 100+ 行
      final k = code('lib/player/kernel.dart');
      final i = k.indexOf('Future<void> setSurfaceSize');
      expect(i, greaterThanOrEqualTo(0));
      final seg = k.substring(i, (i + 4000).clamp(0, k.length));
      // 实现侧（两个内核）各自有 try/catch 兜底
      final native = code('lib/player/native/native_kernel.dart');
      final media3 = code('lib/player/media3/media3_kernel.dart');
      expect(
          native.contains('设置画布尺寸失败（非致命') ||
              media3.contains('设置画布尺寸失败（非致命'),
          isTrue,
          reason: '★ 画布设置失败时画面仍能看（只是比例不准），\n'
              '    不能因此让起播失败 ⇒ 必须有 try/catch 兜底');
      expect(seg.contains('setSurfaceSize'), isTrue);
    });
  });

  group('★ Kotlin 侧：mpv 必须被告知画布尺寸', () {
    late String kt;

    /// ⚠️ **必须剥注释**（§8.4 第一类陷阱，本轮实测又踩了）
    ///
    /// 用原始源码时，把 `pendingSurfaceSize = w to h` 改成
    /// `// pendingSurfaceSize = w to h` 仍满足 `contains(...)`
    /// ⇒ 注入实测「没抓到」。剥注释后同样注入**正确变红**。
    String ktCode() => File('android/app/src/main/kotlin/com/cineflow/app/'
            'player/PlayerChannel.kt')
        .readAsStringSync()
        .split('\n')
        .where((l) {
          final t = l.trimLeft();
          return !t.startsWith('//') && !t.startsWith('*');
        })
        .join('\n');

    setUpAll(() {
      kt = ktCode();
    });

    test('★★ 必须设 mpv 的 android-surface-size（官方手册要求）', () {
      expect(kt.contains('android-surface-size'), isTrue,
          reason: '★★ mpv 手册 `DOCS/man/options.rst:7206-7209` 原文：\n'
              '    "Needs to be set by the **embedding application** if the\n'
              '     dimensions change during runtime" ——\n'
              '    我们正是 --gpu-context=android ⇒ 必须主动告知 mpv。');
    });

    test('★★ 必须"记账 + initialize 后补发"', () {
      expect(kt.contains('pendingSurfaceSize'), isTrue,
          reason: '★★ 起播前设画布时 mpv **还没 initialize**（真机日志：\n'
              '    "（mpv 未就绪，待补）"）⇒ 只打日志不补 = 属性永远设不上。');
      expect(kt.contains('applySurfaceSizeIfPossible'), isTrue);
      // ⚠️ 只断言"字段存在"太弱：把赋值改成注释仍能通过（注入实测抓到）。
      //    ⇒ 必须断言**真的写了**（赋值语句在代码里）。
      expect(kt.contains('pendingSurfaceSize = w to h'), isTrue,
          reason: '★★ 必须真的**赋值** —— 只留字段声明/注释不算记账');
      // 且 initialize 分支里必须**消费**它（只写不读等于没记）
      final i = kt.indexOf('"initialize" ->');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 initialize 分支');
      final seg = kt.substring(i, (i + 900).clamp(0, kt.length));
      expect(seg.contains('pendingSurfaceSize?.let'), isTrue,
          reason: '★★ initialize 成功后必须**消费记账**补发尺寸 ——\n'
              '    只写不读 = 属性永远设不上（真机实测的漏）。');
    });

    test('★ 建纹理时优先用待设尺寸（避免先建 16:9 再改）', () {
      final i = kt.indexOf('private fun ensureTexture');
      expect(i, greaterThanOrEqualTo(0));
      final seg = kt.substring(i, (i + 400).clamp(0, kt.length));
      expect(seg.contains('pendingSurfaceSize'), isTrue,
          reason: '★ 先建 16:9 再改属性纠正不过来（真机实测仍 334px）');
    });

    test('★ 值格式必须是 WxH（mpv 手册 <WxH>）', () {
      expect(kt.contains(r'"${w}x${h}"'), isTrue,
          reason: r'★ mpv 期望 `WxH` 形式，如 "1920x804"');
    });
  });
}
