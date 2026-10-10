// 画面比例（A+C 方案）的守卫测试。
//
// ## 用户要求原文
// > "播放画面我感觉可以优化一下比例，上下增加点黑边，你看下 GitHub 上
// >  或者网络上或者其他主流的播放器是怎么处理这个的呢"
// 选定方案：**A（auto 忠于片源）+ C（用户选的档位被记住）**
//
// ## 为什么这些断言必要
// · **A**：改前 auto 在横屏强制 16:9 ⇒ 2.388:1 宽银幕被**纵向拉伸 34.3%**
//   （真机实测《伟大的长征》3840x1608）。这类"变形"是感知问题，
//   **静态分析发现不了**，只能靠断言数学本身。
// · **C**：比例档位选项**早就存在**，但 `VideoState` 每次新建都是 auto、
//   且全仓库没有任何 `aspect` pref 读写 ⇒ 用户设一次只管一集
//   （"配了没记住"，与"配了没接线"同类）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/domain/player_constants.dart';

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
  group('★★ A：auto 忠于片源（主流播放器一致默认）', () {
    test('★★ 宽银幕电影横屏**不得**被强制 16:9', () {
      // 真机实测片源：《伟大的长征》3840x1608 = 2.388:1
      // 旧行为：横屏视口 2400x1080 ⇒ 强制 16:9 ⇒ 显示高 1350
      //         正确应为 1005 ⇒ **纵向拉伸 34.3%**
      final m = AspectMode.resolveAuto(
          width: 2400, height: 1080, videoRatio: 2.388);
      expect(m, AspectMode.contain,
          reason: '★★ 这条断言的含义：auto **绝不**返回固定比例档。\n'
              '    返回 ratio16x9 会把 2.39:1 的宽银幕拉成 16:9（人变胖）。');
    });

    test('★★ 四种方向组合都忠于片源', () {
      const cases = [
        (2400.0, 1080.0, 16 / 9), // 横屏 + 横片
        (1080.0, 2400.0, 16 / 9), // 竖屏 + 横片
        (2400.0, 1080.0, 9 / 16), // 横屏 + 竖片
        (1080.0, 2400.0, 9 / 16), // 竖屏 + 竖片
      ];
      for (final c in cases) {
        expect(AspectMode.resolveAuto(
                width: c.$1, height: c.$2, videoRatio: c.$3),
            AspectMode.contain,
            reason: '屏幕方向只决定"黑边留在上下还是左右"，'
                '**不该改变画面比例**（${c.$1}x${c.$2}）');
      }
    });

    test('★ 比例未知/非法也回 contain（不猜）', () {
      for (final bad in [null, 0.0, -1.0]) {
        expect(
            AspectMode.resolveAuto(
                width: 2400, height: 1080, videoRatio: bad),
            AspectMode.contain,
            reason: '猜横竖都可能变形 ⇒ 保守 contain');
      }
    });

    test('★ 显示矩形的宽高比 === 片源比例（"不变形"的定义）', () {
      for (final ratio in [16 / 9, 4 / 3, 2.388, 1.333, 9 / 16]) {
        final m = AspectMode.resolveAuto(
            width: 2400, height: 1080, videoRatio: ratio);
        final r = AspectMode.pictureSize(
            mode: m, viewportW: 2400, viewportH: 1080, videoRatio: ratio);
        expect(r.width / r.height, closeTo(ratio, 0.001),
            reason: '★ 这是"不变形"的数学定义');
      }
    });

    test('★ 显式档位语义不变（它们本来就是"忽略片源比例"）', () {
      // 固定比例档 & fill/cover 不受本次改动影响
      expect(AspectMode.ratio16x9.ratio, closeTo(16 / 9, 0.001));
      expect(AspectMode.ratio4x3.ratio, closeTo(4 / 3, 0.001));
      expect(AspectMode.ratio9x16.ratio, closeTo(9 / 16, 0.001));
      expect(AspectMode.auto.ratio, isNull);
      expect(AspectMode.contain.ratio, isNull);
    });

    test('★ auto 仍是默认档（用户不选也有正确行为）', () {
      final p = code('lib/player/domain/models/media_state.dart');
      expect(p.contains('this.aspectMode = AspectMode.auto'), isTrue,
          reason: '★ 默认 auto ⇒ 走"忠于片源"⇒ 不选也是对的');
    });
  });

  group('★★ C：比例档位持久化（"配了要记住"）', () {
    late String page;

    setUpAll(() {
      page = code('lib/player/player_flow_page.dart');
    });

    test('★★ 必须**写入**偏好（否则每集都要重设）', () {
      expect(page.contains("setPref('aspect_mode'"), isTrue,
          reason: '★★ 选项早就存在但没存 ⇒ 用户选了"16:9 满屏"，\n'
              '    下一集又回 auto，得每集重设（"配了没记住"）。');
    });

    test('★★ 必须**读取**偏好（写而不读等于没存）', () {
      expect(page.contains("getPref('aspect_mode')"), isTrue,
          reason: '★★ 只写不读 ⇒ 存储里的值永远不被使用');
    });

    test('★ 读取在 `_boot` 里（与其它偏好同处，且早于起播）', () {
      final i = page.indexOf('Future<void> _boot()');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 _boot');
      final end = page.indexOf('Future<void> _startEpisode', i);
      expect(end, greaterThan(i), reason: '找不到 _boot 边界');
      final seg = page.substring(i, end);
      expect(seg.contains("getPref('aspect_mode')"), isTrue,
          reason: '★ 必须与 default_rate / skip_intro_auto 同一处读取 ——\n'
              '    放到别处容易漏（且要在起播前生效）');
    });

    test('★★ 写入必须在**用户改档**的回调里', () {
      // 若写在"播放页初始化"里，用户改档不会被记住
      final i = page.indexOf('onAspectModeChanged: (m)');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 onAspectModeChanged');
      final seg = page.substring(i, (i + 700).clamp(0, page.length));
      expect(seg.contains("setPref('aspect_mode'"), isTrue,
          reason: '★★ 必须挂在"用户改档"的回调上 ——\n'
              '    写在初始化里 ⇒ 改档不会被记住');
      expect(seg.contains('m.name'), isTrue,
          reason: '★ 存 name（可读、可降级），不存 index');
    });

    test('★ 未知值回退 auto（默认值只在 AspectMode 一处）', () {
      expect(page.contains('orElse: () => AspectMode.auto'), isTrue,
          reason: '★ 读到未知档位不能崩，也不能写死别的值');
    });

    test('★ 写偏好是 fire-and-forget（不阻塞 UI 切换）', () {
      final i = page.indexOf('onAspectModeChanged: (m)');
      final seg = page.substring(i, (i + 700).clamp(0, page.length));
      expect(seg.contains('unawaited('), isTrue,
          reason: '★ 写偏好走 Keystore 加解密，不该阻塞 ——\n'
              '    用户已经看到画面变了，不需要等落盘');
    });
  });
}
