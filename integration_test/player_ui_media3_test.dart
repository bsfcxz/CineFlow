/// **真机集成测试：新播放 UI（PlayerUiPage）× Media3 内核** —— 全链路 +
/// 按播放ui.html 原型核对设置面板。
///
/// 为什么单独一个文件：见 `player_ui_harness.dart` 文件头 ——
/// 与 mpv 用例**必须分两次 `flutter test` 进程跑**（Guarded 冲突）。
///
/// 运行方式（同 mpv 用例，见 harness 文件头）：
/// ```
/// flutter test integration_test/player_ui_media3_test.dart -d <dev> \
///   --dart-define=CF_TEST_URL=http://127.0.0.1:8765/cf_test.mp4
/// ```
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:cineflow/player/kernel_factory.dart';

import 'player_ui_harness.dart';
import 'player_ui_kernel_test.dart' show runWithGuardRetry;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('新播放 UI × Media3 真机全链路（含原型设置面板核对）', (tester) async {
    debugPrint('[CF-DUAL-UI] 片源 = $mediaUrl');
    ensureMediaAvailable();

    await runWithGuardRetry(tester, KernelType.media3);
  });
}
