/// **真机集成测试：新播放 UI（PlayerUiPage）× mpv 内核** —— 全链路 +
/// 按播放ui.html 原型核对设置面板。
///
/// 为什么只有 mpv 一个用例：双内核的另一个在
/// `player_ui_media3_test.dart`，**必须分开两个文件、两次 `flutter test`
/// 进程跑** —— 原因见 `player_ui_harness.dart` 文件头（Guarded 冲突）。
///
/// 运行方式：
/// ```
/// flutter test integration_test/player_ui_kernel_test.dart -d <dev> \
///   --dart-define=CF_TEST_URL=http://127.0.0.1:8765/cf_test.mp4
/// ```
/// （前置：宿主机 `python -m http.server 8765` + `adb reverse tcp:8765 tcp:8765`）
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:cineflow/player/kernel_factory.dart';

import 'player_ui_harness.dart';

/// Guarded 冲突是集成测试 binding 的竞态（真帧回调 vs TestAsyncUtils
/// 守卫），表现为偶发、与内核无关（mpv 全绿过 3 次后第 4 次也撞过）。
/// 只重试这一种框架竞态；真实断言失败照常抛出，**不会**被重试掩盖。
Future<void> runWithGuardRetry(
  WidgetTester tester,
  KernelType type,
) async {
  for (var attempt = 1; attempt <= 3; attempt++) {
    try {
      final r = await exerciseKernel(tester, type, mediaUrl);
      expect(r['threw'], isNull, reason: '$type 异常: $r');
      expect(r['gotDuration'], isTrue);
      expect(r['positionMoved'], isTrue);
      expect(r['uiSpeedApplied'], isTrue, reason: '$type UI 倍速没落到内核');
      expect(r['uiPauseApplied'], isTrue, reason: '$type UI 暂停没落到内核');
      return;
    } catch (e) {
      final isGuardRace = '$e'.contains('Guarded function conflict');
      if (!isGuardRace || attempt == 3) rethrow;
      debugPrint('[CF-DUAL-UI] $type 第 $attempt 次撞 Guarded 竞态，重试…');
      await tester.pump(const Duration(seconds: 1));
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('新播放 UI × mpv 真机全链路（含原型设置面板核对）', (tester) async {
    debugPrint('[CF-DUAL-UI] 片源 = $mediaUrl');
    ensureMediaAvailable();

    await runWithGuardRetry(tester, KernelType.mpv);
  });
}
