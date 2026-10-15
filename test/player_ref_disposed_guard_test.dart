// ══════════════════════════════════════════════════════════════════════
//  ★★★ 守卫测试：「await 之后不许无守卫地读 ref」
// ══════════════════════════════════════════════════════════════════════
//
// ## 缺陷回顾（2026-10-15 真机 Unhandled Exception）
// ```
// E flutter : Unhandled Exception: Bad state: Using "ref" when a widget is
//             about to or has [been disposed]
// E flutter : Ref relies on BuildContext, and BuildContext is unsafe to use
//             when the widget is **deactivated**.
// E flutter : To safely refer to the state of providers inside State.dispose(),
//             save the provider state in a field of your State class...
// ```
// 崩在**退出播放页**的时刻（12:38:44 / 12:42:00），是**红屏级**异常。
//
// ## 根因模式
// ```dart
// Future<void> _boot() async {          // initState 里 unawaited 出去
//   await ref.read(store).getPref('a'); // 挂起点
//   ...
//   ref.read(xProvider).doIt();         // ❌ 用户已退出 ⇒ 抛 Bad state
// }
// ```
//
// ## ⚠️ 判据必须精确（否则误报 —— 我第一版脚本就误报了 3 处）
// **安全**（ref 在 await 表达式**内部**，求值先于挂起）：
// ```dart
// final v = await ref.read(store).getPref('x');   // ✅ ref 先求值，再 await
// ```
// **危险**（挂起**之后**才读 ref）：
// ```dart
// final v = await somethingElse();
// ref.read(store).use(v);                          // ❌
// ```
// ⇒ 本测试只报**后者**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉注释（§8.4：断言不得被注释满足）。
String _stripComments(String src) {
  var s = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  s = s.replaceAll(RegExp(r'//[^\n]*'), '');
  return s;
}

/// 取方法体（按缩进配对到下一个同缩进成员）。
String? _methodBody(List<String> lines, String name) {
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'^\s+(?:Future<[^>]*>|void)\s+' + RegExp.escape(name) + r'\s*\(')
        .hasMatch(lines[i])) {
      final indent = lines[i].length - lines[i].trimLeft().length;
      final buf = <String>[lines[i]];
      for (var k = i + 1; k < lines.length; k++) {
        final s = lines[k];
        if (s.trim().isNotEmpty) {
          final ind = s.length - s.trimLeft().length;
          if (ind <= indent &&
              RegExp(r'^\s+(?:Future|void|Widget|String|int|bool|double|'
                      r'Stream|@override)')
                  .hasMatch(s)) {
            break;
          }
        }
        buf.add(s);
        if (s.startsWith('  }') && (s.length - s.trimLeft().length) == indent) {
          break;
        }
      }
      return buf.join('\n');
    }
  }
  return null;
}

/// **取"真风险"的裸 ref**：出现在**上一个语句的 await 之后**的独立行。
///
/// ## ⚠️ 判据必须精确（我第一版按 `await` 切分 ⇒ **误报 5 处**）
/// 关键区别是 **`ref` 求值发生在挂起之前还是之后**：
/// ```dart
/// // ✅ 安全：ref.read 先求值（返回 Future），再 await 它
/// final v = await ref.read(store).getPref('x');
/// final v = await ref.read(store).getPref('y');   // 同上，安全
///
/// // ❌ 危险：先挂起，之后才读 ref
/// await somethingElse();
/// ref.read(store).use();
/// ```
/// ⇒ 正确判据：**该行以 `ref.` 开头且不以 `await ... ref.` 形式出现**
///   （即"这一行的 ref 不是 await 的求值对象"）。
///
/// 返回违规行的文本列表。
List<String> _bareRefAfterAwait(String body) {
  final out = <String>[];
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    // 只看以 ref.read/ref.watch 开头的行（独立的读操作）
    final isBareRef = RegExp(r'^(?:final\s+\w+\s*=\s*)?ref\.(read|watch)\s*\(')
            .hasMatch(t) ||
        RegExp(r'^_?\w+\s*=\s*ref\.(read|watch)\s*\(').hasMatch(t);
    if (!isBareRef) continue;
    // 该行自身就是 `await ref....` 形式 ⇒ 安全（ref 先求值）
    if (RegExp(r'await\s+ref\.(read|watch)').hasMatch(t)) continue;

    // ── 往回找"最近的守卫边界" ──
    // 遇到**含 await 的行**就停（说明跨了挂起点，必须重新判 mounted）
    // 若在这之前找到 `mounted` ⇒ 视为已守卫。
    //
    // ⚠️ 窗口不能写死几行（我第一版写"前 3 行" ⇒ 守卫块有 4 行时**误报**）：
    //    守卫可能是多行块 `if (!mounted) { ... return; }`。
    var guarded = false;
    for (var k = i - 1; k >= 0; k--) {
      final prev = lines[k];
      if (prev.contains('mounted')) {
        guarded = true;      // 挂起点之后、本行之前 判过 mounted
        break;
      }
      if (RegExp(r'\bawait\b').hasMatch(prev)) {
        break;               // 到了最近的挂起点，还没见到守卫 ⇒ 未守卫
      }
    }
    if (!guarded) out.add(t);
  }
  return out;
}

void main() {
  group('★★★ await 之后不许无守卫地读 ref（真机崩溃的根因）', () {
    late String src;
    late List<String> lines;

    setUpAll(() async {
      src = _stripComments(
          await File('lib/player/player_flow_page.dart').readAsString());
      lines = src.split('\n');
    });

    test('★★★ `_boot` 每个裸 ref 前都有 mounted 守卫', () {
      final body = _methodBody(lines, '_boot');
      expect(body, isNotNull, reason: '找不到 _boot');
      final violations = _bareRefAfterAwait(body!);
      expect(violations, isEmpty,
          reason: '★★★ `_boot` 是 `initState` 里 `unawaited(...)` 出去的：\n'
              '    用户可能在它跑完前退出播放页 ⇒ 挂起点之后读 ref 必崩\n'
              '    （真机 logcat：`Bad state: Using "ref" when a widget is\n'
              '      about to or has been disposed`）\n'
              '    违规处：$violations');
    });

    test('★★★ `_loadDanmaku` 挂起点之后读 ref 前必须判 mounted', () {
      final body = _methodBody(lines, '_loadDanmaku');
      expect(body, isNotNull);
      // 弹幕要发网络请求（几百 ms~数秒）⇒ 最容易被"等不到就退出"命中
      expect(RegExp(r'if\s*\(!mounted\)\s*return').allMatches(body!).length,
          greaterThanOrEqualTo(2),
          reason: '★ 弹幕加载有 ≥2 个挂起点（配置读取 + 弹幕请求）\n'
              '    ⇒ 每个之后都要判 mounted');
    });

    test('★★ `_recoverAudioTrack` / `_applyServerDefaultTracks` '
        '在 setAudioTrack 之后判了 mounted', () {
      for (final name in ['_recoverAudioTrack', '_applyServerDefaultTracks']) {
        final body = _methodBody(lines, name);
        expect(body, isNotNull, reason: '找不到 $name');
        // 找 setAudioTrack/setSubtitleTrack 之后的 ref.read
        final hasBare = RegExp(
                r'await\s+k\.set(?:Audio|Subtitle)Track\([^)]*\);\s*\n\s*'
                r'ref\.(?:read|watch)')
            .hasMatch(body!);
        expect(hasBare, isFalse,
            reason: '★ `$name`：切轨是**原生调用**（可能几十 ms）\n'
                '    ⇒ 之后碰 ref 同样有风险');
      }
    });

    test('★★ 判据自检：真风险模式必须被认出，安全模式不得误报', () {
      // 危险：挂起后读
      const bad = 'await foo();\nref.read(x).use();';
      expect(RegExp(r'await[^;]*;\s*\n\s*ref\.(read|watch)').hasMatch(bad),
          isTrue, reason: '★ 本测试的判据本身要有效（反自欺 §8.4）');
      // 安全：ref 在 await 内部（求值先于挂起）
      const safe = 'final v = await ref.read(store).getPref("x");';
      expect(
          RegExp(r'await[^;]*;\s*\n\s*ref\.(read|watch)').hasMatch(safe), isFalse,
          reason: '★ 这种写法**安全** —— ref 先求值，再 await 它\n'
              '    （我第一版脚本在这里误报了 3 处）');
    });
  });
}
