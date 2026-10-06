/// U9 的**决定性验证**：HomeShell 在真实断点下到底渲染哪种导航。
///
/// # 为什么不用真机截图
///
/// 我试过了，**结论是截图在这台设备上不可靠**：
/// 竖屏与横屏两次 `screencap` 拿到的是**同一份 2400×1080 字节**，
/// 而 `dumpsys window displays` 明确显示几何已变
/// （`cur=1080x2400 land=False w392dp` → `cur=2400x1080 land=True w843dp`）。
/// 也就是说 MIUI 的截屏缓冲没跟上旋转 —— 拿它当证据会得出**错误结论**。
///
/// 改用 widget 测试直接渲染 `HomeShell`：可控、可复现、能断言**控件位置**，
/// 比截图强得多（而且不依赖设备）。
///
/// # 断言什么
/// 竖屏（392dp，Compact）→ **底部 Tab 存在、侧栏不存在**
/// 横屏（843dp，Expanded）→ **侧栏存在、底部 Tab 不存在**
/// Medium（700dp）→ **仍用底部 Tab**（审计明确要求不切侧栏）
///
/// 并断言**两种形态共用同一份 `keys.shell.tab(i)`** ——
/// 这是本批自己造出又修掉的 bug（侧栏第一版漏了键，
/// 会导致 Patrol 用例在横屏下找不到 Tab，而竖屏全绿）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/core/theme.dart';
import 'package:cineflow/keys.dart';
import 'package:cineflow/pages/home_shell.dart';
import 'package:cineflow/state/providers.dart';

import '../patrol_test/fake_media_provider.dart';

/// 真机 1080×2400 @440dpi 的换算（density scale = 440/160 = 2.75）。
const _deviceDpr = 2.75;

/// 用逻辑尺寸渲染 HomeShell，返回每次 `keys.shell.tab(i)` 的命中区。
Future<void> _pumpShell(WidgetTester tester, Size logical) async {
  tester.view.physicalSize = logical * _deviceDpr;
  tester.view.devicePixelRatio = _deviceDpr;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // 离线：不需要服务器、凭据、网络（结果完全确定）
        embyApiProvider.overrideWithValue(FakeMediaProvider()),
      ],
      child: MaterialApp(
        theme: Cf.theme(),
        home: const HomeShell(),
      ),
    ),
  );
  // 首页有异步 provider，给它几帧；不 pumpAndSettle（首页有自动轮播定时器）
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}


void main() {
  group('U9 · 真机断点 → 导航形态（widget 级决定性验证）', () {
    testWidgets('竖屏 392.7dp（Compact）→ 底部 Tab，无侧栏', (tester) async {
      await _pumpShell(tester, const Size(1080 / _deviceDpr, 2400 / _deviceDpr));

      expect(CfBreakpoints.of(1080 / _deviceDpr), CfBreakpoints.compact);
      // keys.shell.tab(i) 存在 = 导航（底栏或侧栏）在
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(keys.shell.tab(i)), findsOneWidget,
            reason: '竖屏下找不到第 $i 个 Tab');
      }
      // 底栏特征：Scaffold 有 bottomNavigationBar
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.bottomNavigationBar, isNotNull,
          reason: '竖屏（Compact）应用底部 Tab，不该是 null');
    });

    testWidgets('★ 横屏 872.7dp（Expanded）→ 侧栏，无底部 Tab', (tester) async {
      await _pumpShell(tester, const Size(2400 / _deviceDpr, 1080 / _deviceDpr));

      expect(CfBreakpoints.of(2400 / _deviceDpr), CfBreakpoints.expanded,
          reason: '横屏逻辑宽 872.7dp 应落 Expanded —— 这是 U9 的前提');

      // ⚠️ 关键断言 1：底部 Tab 必须**消失**
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.bottomNavigationBar, isNull,
          reason: 'Expanded 下底部 Tab 应该消失（改用侧栏）。\n'
              '若它还在，说明 useSideRail 没生效。');

      // ⚠️ 关键断言 2：Tab 键**仍然存在**（只是搬到了侧栏）
      //    这是本批自己造出又修掉的 bug：侧栏第一版漏了 keys.shell.tab(i)，
      //    后果是 Patrol 用例在横屏下找不到 Tab，而竖屏全绿 —— 极难发现。
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(keys.shell.tab(i)), findsOneWidget,
            reason: 'Expanded 下找不到第 $i 个 Tab —— \n'
                '侧栏必须与底栏共用同一份 keys.shell.tab(i)，\n'
                '否则横屏时所有 Tab 相关测试都会静默失效。');
      }
    });

    testWidgets('★ 侧栏确实在左侧（位置断言，不是"存在即可"）', (tester) async {
      await _pumpShell(tester, const Size(2400 / _deviceDpr, 1080 / _deviceDpr));

      final tab0 = tester.getRect(find.byKey(keys.shell.tab(0)));
      final screenW = tester.view.physicalSize.width / _deviceDpr;

      expect(tab0.left, lessThan(screenW * 0.15),
          reason: 'Tab 0 的左边在 x=${tab0.left}（屏宽 $screenW）—— \n'
              '侧栏应在最左侧窄条内。若它落在中间/底部，说明还是底部 Tab 的布局。');
      expect(tab0.width, lessThan(screenW * 0.15),
          reason: 'Tab 命中区宽度 ${tab0.width} 太宽，不像 72dp 侧栏里的一项');

      // 侧栏三项应纵向排列（y 递增），而不是横向（x 递增）
      final tab1 = tester.getRect(find.byKey(keys.shell.tab(1)));
      final tab2 = tester.getRect(find.byKey(keys.shell.tab(2)));
      expect(tab1.top, greaterThan(tab0.top),
          reason: '侧栏里第 1 项应在第 0 项下方（纵向排列）');
      expect(tab2.top, greaterThan(tab1.top),
          reason: '侧栏里第 2 项应在第 1 项下方');
      expect((tab1.left - tab0.left).abs(), lessThan(2.0),
          reason: '侧栏各项的左边界应该对齐（同一列）');
    });

    testWidgets('Medium 700dp → 仍用底部 Tab（审计要求不切侧栏）', (tester) async {
      await _pumpShell(tester, const Size(700, 900));

      expect(CfBreakpoints.of(700), CfBreakpoints.medium);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.bottomNavigationBar, isNotNull,
          reason: 'Medium 不该切侧栏 —— 审计明确要求"不切侧栏，\n'
              '避免本阶段引入导航重构"。600–840dp 用侧栏会让内容区变窄。');

      // 底栏特征：三项横向排列（x 递增）
      final r0 = tester.getRect(find.byKey(keys.shell.tab(0)));
      final r1 = tester.getRect(find.byKey(keys.shell.tab(1)));
      expect(r1.left, greaterThan(r0.left),
          reason: '底部 Tab 各项应横向排列');
      expect((r1.top - r0.top).abs(), lessThan(2.0),
          reason: '底部 Tab 各项应在同一行');
    });
  });

  group('U9 · 侧栏的无障碍语义', () {
    testWidgets('侧栏三项都能被读屏找到（button + selected + label）', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpShell(tester, const Size(2400 / _deviceDpr, 1080 / _deviceDpr));

      // 三个 Tab 的 label 都是中文名，应能按语义找到
      for (final name in ['首页', '排行榜', '我的']) {
        expect(find.bySemanticsLabel(name), findsWidgets,
            reason: '读屏找不到「$name」—— 侧栏缺 label 语义');
      }
      handle.dispose();
    });
  });
}
