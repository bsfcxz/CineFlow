import 'package:cineflow/data/session_store.dart';
import 'package:cineflow/player/player_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放偏好与偏好键的单元测试。
///
/// 为什么需要：`default_rate` 曾长期"有读无写"（缺陷 §7.5）——
/// `player_page` 起播时读它，但全项目没有写入入口，偏好永远停在默认值。
/// 这类缺陷编译期与静态分析都发现不了，只有断言编解码本身才能防回归。
///
/// 注：媒体库排序（缺陷 §7.2）的测试已随列表页一起移除——
/// 见 `docs/decisions/0003-remove-library-tab.md`，重构后按新设计重新定交互。
/// 但**服务端排序方向的结论仍然有效**（`DateCreated` 必须 `Descending`），
/// 已记入该 ADR 与 `MediaProvider.getItems` 注释。
void main() {
  group('默认倍速偏好（缺陷 7.5）', () {
    test('未设置时回退到 1.0x', () {
      expect(PlayerPage.parseDefaultRate(null), 1.0);
      expect(PlayerPage.parseDefaultRate(''), 1.0);
      expect(PlayerPage.parseDefaultRate('abc'), 1.0);
    });

    test('可解析已保存的倍速', () {
      expect(PlayerPage.parseDefaultRate('1.5'), 1.5);
      expect(PlayerPage.parseDefaultRate('2.0'), 2.0);
      expect(PlayerPage.parseDefaultRate('1.25'), 1.25);
    });

    test('写回值：1.0x 存空串（等于清除偏好），其余存数值', () {
      expect(PlayerPage.encodeDefaultRate(1.0), '',
          reason: '1.0x 是默认值，存空串避免留下无意义的偏好');
      expect(PlayerPage.encodeDefaultRate(1.5), '1.5');
      expect(PlayerPage.encodeDefaultRate(2.0), '2.0');
    });

    test('可选项与编解码闭环：每一项都能原样读回', () {
      for (final rate in PlayerPage.defaultRateChoices) {
        final saved = PlayerPage.encodeDefaultRate(rate);
        // 1.0x 存空串，读回时应回退成 1.0
        expect(PlayerPage.parseDefaultRate(saved), rate,
            reason: '${rate}x 存取应闭环');
      }
    });
  });

  group('SessionStore 偏好键（防止键名写错导致静默失效）', () {
    test('default_rate 键名前缀稳定', () {
      // 键名前缀由 SessionStore 统一加 cf_pref_，这里锁定后缀
      expect(SessionStore.prefPrefix, 'cf_pref_');
    });
  });
}
