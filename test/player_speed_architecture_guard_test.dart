/// **5 条禁令的静态守卫** —— 让规则可被机器强制，而不只是写在文档里。
///
/// 用户 2026-10-09 给出的 5 条禁令：
/// ```
/// ① 禁止用同一个变量同时表示"用户倍速"和"实际倍速"
/// ② 禁止在长按相关代码里出现 userSpeed = ...
/// ③ 禁止在倍速循环代码里出现 isLongPressing = ...
/// ④ 禁止在 UI 层把 effectiveSpeed 显示给用户当"当前倍速"
/// ⑤ 如果需要展示"当前实际倍速"，必须单独设计一个只读字段，不能复用 userSpeed
/// ```
///
/// ## 为什么用"读源码"的测试而不是行为测试
/// 这 5 条是**结构约束**，不是行为约束：
/// · 行为测试只能证明"我试的那条路径没污染"
/// · 而"有人在长按代码里写了 `userSpeed = ...`"这种问题，
///   **可能在任何我没想到的路径上**产生污染
///
/// 所以本文件**直接断言源码文本**，在**编译前**就拦住违反。
/// 这与 `player_bar_transparency_test.dart` 的思路一致
/// （"加个模糊更好看"很容易无意识加回来，只能靠文本断言拦）。
///
/// ## ⚠️ 剥注释再断言（本项目踩过的坑）
/// `player_longpress_speed_spec_test.dart` 的兄弟文件里记录过：
/// 源码断言**必须先把注释剥掉**，否则注释里提一句 `userSpeed = ...`
/// 就会让测试假红；反过来，把代码写进注释里也会让测试假绿。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读取源码并**剥掉注释**（// 行注释与 /* */ 块注释）。
String stripComments(String src) {
  // 先剥块注释（非贪婪，跨行）
  var s = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  // 再剥行注释（保留行结构，便于报行号）
  s = s.split('\n').map((l) {
    final i = l.indexOf('//');
    return i >= 0 ? l.substring(0, i) : l;
  }).join('\n');
  return s;
}

String read(String rel) => File(rel).readAsStringSync();

void main() {
  group('★ 倍速模型 5 条禁令（用户 2026-10-09）', () {
    // ---------------------------------------------------------------
    // 禁令①：禁止同一个变量兼表两者
    // ---------------------------------------------------------------
    test('① `userSpeed` 只能被"用户操作"写入（不得被内核回报写入）', () {
      final ctl = stripComments(
          read('lib/player/application/controllers/playback_controller.dart'));

      // 找出所有对 userSpeed 的**赋值**位置（copyWith(userSpeed: ...)）
      final writes = RegExp(r'copyWith\([^)]*userSpeed\s*:')
          .allMatches(ctl)
          .map((m) => m.group(0))
          .toList();

      // 允许的写入者只有两个：cycleSpeed 与 setUserSpeed。
      // 用"每个写入点所属的方法"来判断，比数字符更稳。
      var cycleHas = false;
      var setHas = false;
      var syncHas = false;
      for (final m in RegExp(r'void (\w+)\([^)]*\)[^{]*\{([^}]*(?:\{[^}]*\})?[^}]*)\}')
          .allMatches(ctl)) {
        final name = m.group(1)!;
        final body = m.group(2)!;
        if (!body.contains('userSpeed:')) continue;
        if (name == 'cycleSpeed') cycleHas = true;
        if (name == 'setUserSpeed') setHas = true;
        if (name == 'syncSpeed') syncHas = true;
      }

      expect(syncHas, isFalse,
          reason: '★ 禁令①：`syncSpeed` 里出现了对 `userSpeed` 的写入。\n'
              '    `syncSpeed` 的入参是**内核回报的实际速率**，把它写进\n'
              '    `userSpeed`（= 用户偏好）就是"一个变量兼表两者"——\n'
              '    这正是长按倍速被污染两次的根因。\n'
              '    正确做法：写 `engineSpeed`。');
      expect(cycleHas, isTrue,
          reason: '规格③：倍速循环**应该**写 userSpeed（它是用户操作）');
      expect(setHas, isTrue,
          reason: 'setUserSpeed 应该写 userSpeed（负载用户偏好）');
      expect(writes.isNotEmpty, isTrue);
    });

    test('① `userSpeed` 与 `engineSpeed` 是两个独立字段', () {
      final state = stripComments(
          read('lib/player/domain/models/playback_state.dart'));
      expect(state.contains('final double userSpeed'), isTrue);
      expect(state.contains('final double engineSpeed'), isTrue,
          reason: '★ 禁令⑤：必须有独立的只读字段承载"实际倍速"。\n'
              '    若这条红 → 有人把 engineSpeed 删了、又复用 userSpeed 表示两者。');
    });

    // ---------------------------------------------------------------
    // 禁令②：长按代码里不得出现 userSpeed =
    // ---------------------------------------------------------------
    test('② 长按相关方法里不得出现对 userSpeed 的赋值', () {
      final ctl = stripComments(
          read('lib/player/application/controllers/playback_controller.dart'));

      for (final fn in ['startLongPress', 'endLongPress']) {
        final m = RegExp('void ' + fn + r'\(\)[^{]*\{([^}]*)\}').firstMatch(ctl);
        expect(m, isNotNull, reason: '找不到方法 $fn（重命名了？同步改本测试）');
        final body = m!.group(1)!;
        expect(body.contains('userSpeed'), isFalse,
            reason: '★ 禁令②：`$fn` 里出现了 `userSpeed`。\n'
                '    长按只应翻 `isLongPressing`，不得触碰用户偏好。');
      }
    });

    // ---------------------------------------------------------------
    // 禁令③：倍速循环里不得出现 isLongPressing =
    // ---------------------------------------------------------------
    test('③ 倍速循环方法里不得出现 isLongPressing 赋值', () {
      final ctl = stripComments(
          read('lib/player/application/controllers/playback_controller.dart'));

      final m = RegExp(r'void cycleSpeed\(\)[^{]*\{([^}]*)\}').firstMatch(ctl);
      expect(m, isNotNull, reason: '找不到 cycleSpeed');
      final body = m!.group(1)!;
      expect(body.contains('isLongPressing'), isFalse,
          reason: '★ 禁令③：`cycleSpeed` 里出现了 `isLongPressing`。\n'
              '    倍速循环是**纯用户操作**，与长按状态无关 ——\n'
              '    不要把两者耦合（例如"长按期间禁用按钮"）。');
    });

    // ---------------------------------------------------------------
    // 禁令④：UI 层不得把 effectiveSpeed 当"当前倍速"显示
    // ---------------------------------------------------------------
    test('④ UI 层不得把 effectiveSpeed 用作展示文案', () {
      // 扫描所有 presentation 层文件
      final dir = Directory('lib/player/presentation');
      final offenders = <String>[];
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = stripComments(f.readAsStringSync());
        for (final line in src.split('\n')) {
          if (!line.contains('effectiveSpeed')) continue;

          // ---- 区分"显示给用户"与"引擎线"（第一版守卫误报过）----
          //
          // ## 合法（引擎线）
          // · `onSpeedChanged(next.effectiveSpeed)` —— **下发给引擎**
          // · `if (prev?.effectiveSpeed != next.effectiveSpeed)` —— **变化检测**
          //
          // ## 违规（展示给用户）
          // · 出现在 Text / style / 字符串插值里
          // · 赋给 label / text / title 之类的展示变量
          //
          // 我第一版只放行了含 `onSpeedChanged` 的行，
          // 于是**变化检测**那行被误判 ⇒ 守卫自己报假警。
          final trimmed = line.trim();
          final isCompare = RegExp(r'[!=]=\s*\S*\.?effectiveSpeed')
                  .hasMatch(trimmed) ||
              RegExp(r'effectiveSpeed\s*[!=]=').hasMatch(trimmed);
          final isDispatch = trimmed.contains('onSpeedChanged');
          final isShow = RegExp(r'''Text\(|style:|'\$\{|"\$\{''')
                  .hasMatch(trimmed) ||
              RegExp(r'\b(label|text|title|display)\s*[:=]').hasMatch(trimmed);

          if (isShow && !isDispatch && !isCompare) {
            offenders.add('${f.path}: ${trimmed}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '★ 禁令④：UI 层把 `effectiveSpeed` 用在了非"下发引擎"的地方。\n'
              '    `effectiveSpeed` 是"**应该**给引擎什么"（长按期间=3.0），\n'
              '    拿它当"当前倍速"显示，长按期间用户就会看到 3.0x，\n'
              '    误以为自己的倍速被改了。\n'
              '    展示"实际倍速"请用 `engineSpeed`（禁令⑤）。\n'
              '违规处：\n${offenders.join('\n')}');
    });

    // ---------------------------------------------------------------
    // 禁令⑤：engineSpeed 的写入者只能是 syncSpeed（内核回报）
    // ---------------------------------------------------------------
    test('⑤ `engineSpeed` 只由内核回报写入，不由用户操作写入', () {
      final ctl = stripComments(
          read('lib/player/application/controllers/playback_controller.dart'));

      var syncHas = false;
      var cycleHas = false;
      var setHas = false;
      for (final m in RegExp(r'void (\w+)\([^)]*\)[^{]*\{([^}]*)\}')
          .allMatches(ctl)) {
        final name = m.group(1)!;
        final body = m.group(2)!;
        if (!body.contains('engineSpeed:')) continue;
        if (name == 'syncSpeed') syncHas = true;
        if (name == 'cycleSpeed') cycleHas = true;
        if (name == 'setUserSpeed') setHas = true;
      }
      expect(syncHas, isTrue,
          reason: '引擎回报应写 engineSpeed（这是它的唯一来源）');
      expect(cycleHas, isFalse,
          reason: '★ 禁令⑤：用户点倍速按钮**不得**改 engineSpeed ——\n'
              '    那是内核的实际状态，只能由内核回报更新。');
      expect(setHas, isFalse, reason: '同上：setUserSpeed 不得改 engineSpeed');
    });

    // ---------------------------------------------------------------
    // 禁令⑤的补充：effectiveSpeed 是**派生**的，不得成为存储字段
    // ---------------------------------------------------------------
    test('⑤ `effectiveSpeed` 必须是派生 getter，不得是存储字段', () {
      final state = stripComments(
          read('lib/player/domain/models/playback_state.dart'));
      expect(state.contains('double get effectiveSpeed'), isTrue,
          reason: 'effectiveSpeed 应为 getter（派生值，不占存储）');
      expect(state.contains('final double effectiveSpeed'), isFalse,
          reason: '★ 若 effectiveSpeed 变成存储字段，就会出现第三份"倍速"状态，\n'
              '    三者同步必然出错（这正是本项目反复踩的坑）。');
    });
  });
}
