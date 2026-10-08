/// **退出卡死 + 立即隐藏 + 方向策略** 的回归防线（用户 2026-10-09 反馈）。
///
/// 用户原话：
/// ```
/// 播放页不锁横屏横屏，我是手机使用，点击全屏时变成横屏，
/// 点击屏幕没有及时隐藏，我希望点击后马上就能隐藏，
/// 点左侧的退出箭头直接卡朱（卡住），而且左侧的退出箭头应该防止（放在）左上角。
/// ```
///
/// ## ★ 退出卡死：`PopScope(canPop:false)` + `maybePop()` = 无限递归
/// ```
/// maybePop() → canPop=false ⇒ 被拒 → onPopInvokedWithResult(didPop:false)
///            → _finalizeAndExit() → maybePop() → …… 同步死循环
/// ```
/// `maybePop()` **会再次触发** `onPopInvokedWithResult`，而 `canPop` 恒为 false
/// ⇒ **同步无限递归** ⇒ UI 线程卡死。
///
/// 这个 bug 的可怕之处：**静态分析完全看不出来** ——
/// 两处代码单独看都合理，只有把两者放在一起推演才暴露。
///
/// ## 为什么用"读源码"的断言而不是行为测试
/// 无限递归会让行为测试**直接挂死**（跑不完、超时），不是"变红" ——
/// 那样的测试无法留在套件里。故这类结构约束只能读源码断言。
///
/// ## ⚠️ 断言写法（我在这里栽过）
/// 第一版用 `RegExp(r'void _handleTap\(\)\{([\s\S]*?)\n  \}')` 提取方法体 ——
/// 会在**第一个内层 `}`** 处截断（方法里有嵌套 `if`），导致断言误报。
/// 改用**索引区间**（同一文件内两个锚点的位置差）判定，
/// 逻辑简单、不依赖正则的贪婪行为。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉注释（源码断言必须先剥注释，否则注释里提一句就会假红/假绿）。
String stripComments(String src) {
  var s = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  s = s.split('\n').map((l) {
    final i = l.indexOf('//');
    return i >= 0 ? l.substring(0, i) : l;
  }).join('\n');
  return s;
}

String read(String rel) => File(rel).readAsStringSync();

void main() {
  final flow = stripComments(read('lib/player/player_flow_page.dart'));
  final ui = stripComments(
      read('lib/player/presentation/player_ui_page.dart'));

  group('★ 退出卡死（无限递归）', () {
    test('★ `PopScope.canPop` 不得恒为 false', () {
      final m = RegExp(r'canPop:\s*([^,\n]+),').firstMatch(flow);
      expect(m, isNotNull, reason: '找不到 canPop 参数');

      final canPop = m!.group(1)!.trim();
      expect(canPop, isNot('false'),
          reason: '★ `canPop: false` + 在 `onPopInvokedWithResult` 里调\n'
              '    `maybePop()` = **同步无限递归** ⇒ UI 线程卡死。\n'
              '    这正是用户说的"点左侧的退出箭头直接卡住"。\n'
              '    正确写法：`canPop: _allowPop`。\n'
              '    当前值：$canPop');
      expect(canPop.contains('_allowPop'), isTrue,
          reason: 'canPop 应绑定 `_allowPop`（可控的一次性放行）');
    });

    test('★ 退出流程必须先解除拦截、再 pop（顺序不能反）', () {
      // 在 `_finalizeAndExit` 之后的范围里找两个锚点
      final fn = flow.indexOf('void _finalizeAndExit()');
      expect(fn, greaterThanOrEqualTo(0), reason: '找不到 _finalizeAndExit');

      // 取方法后 2000 字符作为方法体近似（足够覆盖，且不会跨到别的方法）
      final body = flow.substring(fn, (fn + 2000).clamp(0, flow.length));

      final allowIdx = body.indexOf('_allowPop = true');
      final popIdx = body.indexOf('maybePop');

      expect(allowIdx, greaterThanOrEqualTo(0),
          reason: '★ `_finalizeAndExit` 里必须置 `_allowPop = true` ——\n'
              '    否则 pop 会被 PopScope 再次拒绝，而拒绝回调又调回本方法\n'
              '    ⇒ 无限递归。');
      expect(popIdx, greaterThan(allowIdx),
          reason: '★ `_allowPop = true` 必须在 `maybePop()` **之前**执行。\n'
              '    顺序反了等于没修。');
    });
  });

  group('★ 点击立即隐藏（且不吃掉双击）', () {
    test('★ 控制层可见时单击应**立即**隐藏（不等 250ms）', () {
      final fn = ui.indexOf('void _handleTap()');
      expect(fn, greaterThanOrEqualTo(0), reason: '找不到 _handleTap');
      final body = ui.substring(fn, (fn + 2000).clamp(0, ui.length));

      expect(body.contains('uiCtl.hide()'), isTrue,
          reason: '★ 用户要求"点击后马上就能隐藏"。\n'
              '    `_handleTap` 必须在第一次点击时**立即** `hide()`，\n'
              '    而不是等 `tapDelay`(250ms) 的延时回调。');
    });

    test('★ 立即隐藏**不得**吃掉双击（我上一版就错在这）', () {
      final fn = ui.indexOf('void _handleTap()');
      final body = ui.substring(fn, (fn + 2000).clamp(0, ui.length));

      expect(body.contains('onTogglePlay'), isTrue,
          reason: '★ `_handleTap` 必须保留双击 → `onTogglePlay()` 的分支。\n'
              '    我第一版写成 `if (visible) { _tapCount = 0; hide(); return; }`，\n'
              '    第二次点击变成"新的第一次" ⇒ **双击彻底失效**。\n'
              '    被 `test/player_tap_test.dart` 的 2 例抓红。');
      expect(body.contains('_tapStartedVisible'), isTrue,
          reason: '★ 需要记录"第一次点击时是否可见"，\n'
              '    以便双击时**恢复可见**（否则双击会闪一下控制层）');
    });

    test('★ 双击时要恢复可见（否则"闪一下"）', () {
      final fn = ui.indexOf('void _handleTap()');
      final body = ui.substring(fn, (fn + 2000).clamp(0, ui.length));

      final elseIdx = body.indexOf('} else {');
      expect(elseIdx, greaterThan(0), reason: '找不到双击分支');
      expect(body.substring(elseIdx).contains('show()'), isTrue,
          reason: '★ 双击分支里要 `uiCtl.show()` —— 第一次点击已把控制层藏了，\n'
              '    不恢复的话双击会"闪一下"。');
    });
  });

  group('★ 方向策略（用户：手机使用，进播放页不锁横屏）', () {
    test('★ initState 不得锁横屏（横屏只在点全屏时）', () {
      final fn = flow.indexOf('void initState()');
      expect(fn, greaterThanOrEqualTo(0), reason: '找不到 initState');
      // ⚠️ 窗口要**够大**：`initState` 里除方向设置外还有启动埋点、
      //    以及 K3 新增的媒体会话命令注册（约 60 行）。窗口太小会**截断**，
      //    使 `portraitUp` 落在窗口外 ⇒ 误报"没锁竖屏"。
      //    （实测：加 K3 后本用例从绿变红，原因就是窗口不够，不是回归。）
      final body = flow.substring(fn, (fn + 6000).clamp(0, flow.length));

      expect(body.contains('landscapeLeft'), isFalse,
          reason: '★ 用户明确："播放页不锁横屏，我是手机使用，点击全屏时变成横屏"。\n'
              '    `initState` 里**不得**出现 landscapeLeft/Right。');
      expect(body.contains('portraitUp'), isTrue,
          reason: 'initState 应锁竖屏（手机使用的主场景）');
    });

    test('★ 全屏按钮必须切方向（不能只切系统栏）', () {
      final fn = flow.indexOf('onFullscreenToggled:');
      expect(fn, greaterThanOrEqualTo(0), reason: '找不到 onFullscreenToggled');
      final body = flow.substring(fn, (fn + 2000).clamp(0, flow.length));

      expect(body.contains('landscapeLeft'), isTrue,
          reason: '★ 用户要求"点击全屏时变成横屏" ⇒ 全屏必须锁横屏。\n'
              '    原实现只切系统栏不切方向（而播放页本就锁横屏）\n'
              '    ⇒ 点了看不出变化 = "点击全屏好像没用"。');
      expect(body.contains('portraitUp'), isTrue,
          reason: '退出全屏时应回竖屏');
    });

    test('★ 退出箭头应在左上角（顶栏加左侧内边距）', () {
      // 顶栏 Padding：left 应为正数（贴左但留边），且 top 含安全区
      final fn = ui.indexOf('key: keys.player.topBar');
      expect(fn, greaterThanOrEqualTo(0), reason: '找不到 topBar');
      // 往上看 8 行，应看到 EdgeInsets
      final from = (fn - 400).clamp(0, ui.length);
      final ctx = ui.substring(from, fn);

      expect(ctx.contains('EdgeInsets.only'), isTrue,
          reason: '顶栏应有 EdgeInsets.only 控制边距');
      expect(ctx.contains('MediaQuery.paddingOf'), isTrue,
          reason: '★ 用户要求"退出箭头放在左上角" ⇒ 顶栏要加**顶部安全区**，\n'
              '    否则竖屏下按钮会被状态栏/挖孔屏压住。');
      expect(ctx.contains('left:'), isTrue,
          reason: '应显式声明 left（贴左 = 锚在左上角）');
    });
  });
}
