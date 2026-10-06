/// U2 底部 Tab 的**回归守护**。
///
/// # 这个批次修了什么（三条，都能在这里守住）
///
/// 1. **字缩溢出**：标签原为裸 `fontSize: 10`，在系统 200% 字号下 → 20sp，
///    而栏高固定 58dp（图标 24 + 间距 2 + 文字 20 会挤掉居中余量）
///    → 文字被裁或与图标重叠。改为 `CfText(clamp: true)`。
/// 2. **系统手势条遮挡**：`SafeArea(top: false)` 必须保留 ——
///    Android 15 强制 edge-to-edge 后，自绘 Tab 不加这层会被手势条压住。
/// 3. **无障碍**：自绘 Tab 原先**零语义**，读屏只能念"按钮"。
///    补 `Semantics(button: true, selected: …, label: …)`。
///
/// # 为什么用「源码断言」而不是 widget 测试
/// 这三条里，1 与 2 是**结构性约束**（组件树形状），3 可以用 widget 测试但
/// 意义有限（Semantics 存在 ≠ 读屏体验好）。
/// 用源码断言能覆盖"有人在重构时把 SafeArea 拿掉/把 CfText 换回 Text"——
/// 这类回归**不会报错、只会静默退化**，正是最需要守的。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读源码并**去掉整行注释**。
///
/// ## ⚠️ 这一步是必须的（实测踩过）
///
/// 第一版直接对原始源码做正则，结果**反向注入无效**：
/// 源码 L85 有一行注释 `// SafeArea(top: false) 已把系统手势条高度…`，
/// 于是即使把**代码里**的 `top: false` 删掉，正则仍匹配到**注释** → 测试假绿。
///
/// 这类"注释让断言失效"的坑很隐蔽：测试看起来正确、也一直绿，
/// 但它守的东西**早已被删掉**。凡是基于源码文本的断言，都必须先剥注释。
String _src(String rel) {
  final raw = File(rel).readAsStringSync();
  return raw
      .split('\n')
      .where((l) {
        final s = l.trimLeft();
        return !s.startsWith('//') && !s.startsWith('///') && !s.startsWith('*');
      })
      .join('\n');
}

void main() {
  group('U2 · 底部 Tab', () {
    final src = _src('lib/pages/home_shell.dart');

    test('保持 SafeArea(top: false) —— 防系统手势条遮挡', () {
      // ⚠️ 断言必须**绑定在同一处**（`SafeArea(` 后面紧跟 `top: false`）。
      //
      //    第一版只断言"源码里同时含 SafeArea( 和 top: false" ——
      //    反向注入（把 `top: false` 删掉）**测试仍然通过**，因为
      //    `top: false` 在别处也出现过。那是**假绿**，比没有测试更糟：
      //    它让人以为这条被守住了。
      final m = RegExp(r'SafeArea\(\s*top:\s*false').hasMatch(src);
      expect(
        m,
        isTrue,
        reason: 'Tab 栏丢了 SafeArea(top: false)。\n'
            'Android 15 强制 edge-to-edge 后，自绘 Tab 会被系统手势条压住 ——\n'
            '这不是"看起来有点挤"，而是底部一格点不到。',
      );
    });

    test('标签用 CfText(clamp: true) —— 防 200% 字号溢出', () {
      expect(
        RegExp(r'CfText\([^)]*clamp:\s*true').hasMatch(src),
        isTrue,
        reason: '标签改回了不钳制的 Text。\n'
            '栏高固定 58dp：200% 字号下 10sp→20sp 会让文字与图标重叠或被裁。\n'
            '本栏是**固定高度容器**，所以即使字号只有 10sp（属"正文档"）\n'
            '也必须显式 clamp: true。',
      );
    });

    test('标签不再用裸 fontSize', () {
      expect(
        RegExp(r'fontSize:\s*\d').hasMatch(src),
        isFalse,
        reason: 'Tab 里又出现了裸 fontSize。请用 Cf 排版令牌（如 Cf.micro）。',
      );
    });

    test('自绘 Tab 带无障碍语义（button + selected + label）', () {
      expect(src.contains('Semantics('), isTrue,
          reason: '自绘 Tab 需要显式语义，否则读屏只能念"按钮"');
      expect(src.contains('button: true'), isTrue, reason: '缺 button 角色');
      expect(RegExp(r'selected:\s*i\s*==\s*index').hasMatch(src), isTrue,
          reason: '缺 selected 状态 —— 读屏无法告知"当前在第几个 Tab"');
      expect(RegExp(r'label:\s*_tabItems\[i\]\.label').hasMatch(src), isTrue,
          reason: '缺 label —— 读屏读不出 Tab 名称');
    });

    test('栏高是具名常量（重构时不易被误删/改散）', () {
      expect(
        RegExp(r'static const double barHeight\s*=').hasMatch(src),
        isTrue,
        reason: '栏高又变成裸数字了。具名常量便于说明"为何是定值"（配套字缩钳制）。',
      );
    });
  });
}
