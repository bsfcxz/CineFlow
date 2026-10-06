/// 起播超时判据的单元测试（防"灰屏修复其实没生效"这类静默缺陷）。
///
/// ## 为什么必须有这个文件
///
/// 原始实现的判据是 `if (_dur > 0 || _playing) return;` —— 看起来合理，
/// **实际让整个超时功能失效**：
///
///   `playing` 由 mpv 的 `pause` 属性驱动
///   （`native_kernel.dart`: `case 'pause': _pushState(playing: data != true)`），
///   而 `openUrl(play: true)` 一进去就把 `pause=no` 设上了 ——
///   **尚未拿到任何数据时 `playing` 已经是 true**。
///   于是死源（STRM 指向能连上但不返回数据的 URL）场景下计时器必然提前
///   return，灰屏照旧。
///
/// 这类缺陷**静态分析发现不了、界面也看不出来**（要真有一个死源才能复现），
/// 只有把判据抽成纯函数并断言其真值表才守得住。
///
/// ## 被测对象
/// `PlayerPage.shouldTimeout` —— 与 `_armStartTimeout` 内的判据**同源**
/// （实现里直接调用它，不是复制一份逻辑，否则测试会与实现漂移）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/player_page.dart';

void main() {
  group('起播超时判据 shouldTimeout', () {
    test('死源：有 pause=no（playing=true）但无时长无进度 → 应超时', () {
      // ★ 这就是原始 bug 的场景：playing 为 true 但什么都没拿到
      expect(
        PlayerPage.shouldTimeout(
          playing: true,
          duration: Duration.zero,
          position: Duration.zero,
          positionAtArm: Duration.zero,
        ),
        isTrue,
        reason: 'playing=true 就提前 return 是本缺陷的根因 —— 死源下 will 永不超时',
      );
    });

    test('正常起播：拿到时长 → 不超时', () {
      expect(
        PlayerPage.shouldTimeout(
          playing: true,
          duration: const Duration(minutes: 45),
          position: Duration.zero,
          positionAtArm: Duration.zero,
        ),
        isFalse,
      );
    });

    test('无时长但已在出画面（position 推进）→ 不超时', () {
      // 某些直播/分片流拿不到 duration，但确实能播 —— 不能误杀
      expect(
        PlayerPage.shouldTimeout(
          playing: true,
          duration: Duration.zero,
          position: const Duration(seconds: 3),
          positionAtArm: Duration.zero,
        ),
        isFalse,
      );
    });

    test('暂停且无时长无进度 → 仍算超时（用户看不到任何反馈）', () {
      expect(
        PlayerPage.shouldTimeout(
          playing: false,
          duration: Duration.zero,
          position: Duration.zero,
          positionAtArm: Duration.zero,
        ),
        isTrue,
      );
    });

    test('position 未超过布防时的值（回退/归零）→ 不算推进', () {
      expect(
        PlayerPage.shouldTimeout(
          playing: true,
          duration: Duration.zero,
          position: const Duration(seconds: 2),
          positionAtArm: const Duration(seconds: 5),
        ),
        isTrue,
        reason: 'position 比布防时还小说明并未真正推进（换了源/归零）',
      );
    });

    test('duration 为负（异常值）不应被当成"已有时长"', () {
      expect(
        PlayerPage.shouldTimeout(
          playing: true,
          duration: const Duration(seconds: -1),
          position: Duration.zero,
          positionAtArm: Duration.zero,
        ),
        isTrue,
      );
    });

    test('超时时长是 15s（与 Kotlin 侧 network-timeout 对齐）', () {
      expect(PlayerPage.startTimeoutDuration, const Duration(seconds: 15));
    });
  });
}
