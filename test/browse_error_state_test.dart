// ══════════════════════════════════════════════════════════════════════
//  ★★★ 守卫测试：「分类浏览」加载失败必须**退出 spinner**
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户报障（2026-10-15）
// > "首页中 6 个类别中点开其实**就在一块**。没有细分类别"
//
// 真机复现（截图 + logcat）：
// ```
// [分类浏览页] 类别 chips ✓ / 地区 chips ✓ / 网格区 **无限转圈**
// 13:45:29  [Calendar] 分类浏览异常: 超时       ← 12 秒后
// ```
// ⇒ 用户以为"没有细分"，实际是**每个类别点开都是空白转圈**。
//
// ## 根因（两条，缺一不可）
// ```
// ① `_load()` **零 try/catch** ⇒ fetchBrowse 抛异常时
//    `setState(() => _loading = false)` **永不执行** ⇒ _loading 恒 true
// ② `_body()` 判定顺序错 ⇒ `if (items == null) return spinner;`
//    **挡在** 错误分支前面（items 只在成功时才有值）⇒ 错误+重试永远摸不到
// ```
//
// ## 为什么必须测（这类 bug 静态分析发现不了）
// · analyze 0 error（try/catch 不是语法要求）
// · 错误分支的**代码写得很好**（图标+文案+重试按钮），但**没有路径能到它**
// ⇒ 只有断言"结构关系"才能防回归。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥注释（§8.4：断言不得被注释满足）。
String _stripComments(String src) {
  var s = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  s = s.replaceAll(RegExp(r'//[^\n]*'), '');
  return s;
}

/// 取方法体（按缩进配对）。
String? _methodBody(String src, String name) {
  final lines = src.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'^\s+(?:Future<[^>]*>|void|Widget)\s+' +
            RegExp.escape(name) +
            r'\s*\(')
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

void main() {
  late String src;

  setUpAll(() async {
    src = _stripComments(
        await File('lib/pages/browse_page.dart').readAsString());
  });

  group('★★★ 分类浏览：加载失败必须退出 spinner（真机无限转圈的根因）', () {
    test('★★★ `_load` 必须有 try/catch（否则异常时 _loading 不复位）', () {
      final body = _methodBody(src, '_load');
      expect(body, isNotNull, reason: '找不到 _load');
      expect(RegExp(r'\btry\s*\{').hasMatch(body!), isTrue,
          reason: '★★★ 零 try/catch ⇒ `fetchBrowse` 抛异常（如"超时"）时\n'
              '    `setState(() => _loading = false)` **永不执行**\n'
              '    ⇒ `_loading` 恒为 true ⇒ 用户看到**无限转圈**');
      expect(RegExp(r'\bcatch\s*\(').hasMatch(body), isTrue,
          reason: '★ 有 try 必须有 catch（或 finally）兜住');
      // 失败分支必须写 _error（AGENTS §7.8：不许把失败伪装成空）
      expect(RegExp(r'_error\s*=').hasMatch(body), isTrue,
          reason: '★ 失败要**说清原因**，不能只复位 loading 不给说明');
    });

    test('★★★ `_load` 的失败分支必须复位 `_loading`', () {
      final body = _methodBody(src, '_load')!;
      final ci = body.indexOf('catch');
      expect(ci, greaterThan(0));
      final catchSeg = body.substring(ci);
      expect(catchSeg.contains('_loading = false'), isTrue,
          reason: '★★★ catch 里不复位 ⇒ 用户永远停在 spinner\n'
              '    （这正是报障现象："点开就在一块/空白"）');
    });

    test('★★★ `_body` 的**错误分支必须在 spinner 之前**', () {
      final body = _methodBody(src, '_body');
      expect(body, isNotNull, reason: '找不到 _body');
      final errIdx = body!.indexOf('_error case final msg?');
      // 找"裸的 items == null ⇒ spinner"那句
      final spinIdx = body.indexOf('if (items == null)');
      expect(errIdx, greaterThan(0), reason: '找不到错误分支');
      expect(spinIdx, greaterThan(0), reason: '找不到 spinner 分支');
      expect(errIdx, lessThan(spinIdx),
          reason: '★★★ 判定顺序错 ⇒ 错误分支被 `items == null` 挡住：\n'
              '    `items` 只在**成功**时写进 _cache ⇒ 失败时恒为 null\n'
              '    ⇒ `if (items == null) return spinner;` 先返回\n'
              '    ⇒ **错误提示与重试按钮永远摸不到**\n'
              '    （代码写得好但没路径能到 —— analyze 发现不了）');
    });

    test('★★ 重试按钮必须先清 `_error` 再 `_load`', () {
      // 否则 _load 早期失败时，_body 会立刻又停在错误态
      expect(
          RegExp(r"setState\(\(\) => _error = null\);\s*\n\s*_load\(\);")
              .hasMatch(src),
          isTrue,
          reason: '★ 重试前清 `_error`：失败可能发生在"参数就绪"之前\n'
              '    ⇒ 只调 `_load()` 会被旧 `_error` 继续挡住');
    });
  });
}
