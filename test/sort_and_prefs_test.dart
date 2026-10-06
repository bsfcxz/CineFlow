import 'package:cineflow/data/models.dart';
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

  group('长按倍速偏好（用户要求：长按屏幕倍速播放）', () {
    test('未设置时默认 2.0x', () {
      expect(PlayerPage.parseHoldSpeed(null), 2.0);
      expect(PlayerPage.parseHoldSpeed(''), 2.0);
      expect(PlayerPage.parseHoldSpeed('abc'), 2.0);
    });

    test('可解析已保存的档位', () {
      for (final s in PlayerPage.holdSpeedChoices) {
        expect(PlayerPage.parseHoldSpeed('$s'), s, reason: '$s 存取应闭环');
      }
    });

    test('★ 越界值回退默认（防手改偏好把播放器搞坏）', () {
      // <1 无意义（长按应该更快），>4 会掉帧
      expect(PlayerPage.parseHoldSpeed('0.5'), 2.0);
      expect(PlayerPage.parseHoldSpeed('0'), 2.0);
      expect(PlayerPage.parseHoldSpeed('-2'), 2.0);
      expect(PlayerPage.parseHoldSpeed('99'), 2.0);
      expect(PlayerPage.parseHoldSpeed('1e9'), 2.0);
    });

    test('默认档位在选项列表里（保证 UI 能显示"当前选中"）', () {
      expect(PlayerPage.holdSpeedChoices.contains(2.0), isTrue,
          reason: '默认值必须在可选列表里，否则设置页没有任何一项是高亮的');
    });

    test('档位严格递增（UI 从左到右由慢到快）', () {
      final l = PlayerPage.holdSpeedChoices;
      for (var i = 1; i < l.length; i++) {
        expect(l[i] > l[i - 1], isTrue, reason: '档位必须递增：$l');
      }
    });
  });

  group('控制条按钮显隐规则（用户要求：唯一性隐藏，可选择性显示）', () {
    // 用户原话："如果存在唯一性那就可以隐藏，如果有可选择性那就可以显示"
    //          "选集…如果播放电影…只有一部那就需要隐藏"

    group('选集按钮', () {
      test('★ 电影（无分集）→ 隐藏', () {
        expect(PlayerPage.showEpisodeButton(null), isFalse,
            reason: '电影从首页直接进播放器时 episodes 为 null，只有一部片，无可选');
      });

      test('★ 只有 1 集 → 隐藏（点开也没得选）', () {
        final one = [MediaItem(id: 'e1', name: '第 1 集', type: 'Episode')];
        expect(PlayerPage.showEpisodeButton(one), isFalse);
      });

      test('★ 剧集/综艺（多集）→ 显示', () {
        final many = [
          for (var i = 1; i <= 24; i++)
            MediaItem(id: 'e$i', name: '第 $i 集', type: 'Episode'),
        ];
        expect(PlayerPage.showEpisodeButton(many), isTrue);
      });

      test('恰好 2 集 → 显示（有选择余地了）', () {
        final two = [
          MediaItem(id: 'e1', name: '上', type: 'Episode'),
          MediaItem(id: 'e2', name: '下', type: 'Episode'),
        ];
        expect(PlayerPage.showEpisodeButton(two), isTrue);
      });
    });

    group('音轨按钮（没有"关闭"选项，故需 ≥2 条）', () {
      test('0 条 → 隐藏', () {
        expect(PlayerPage.showAudioButton(0), isFalse);
      });

      test('★ 1 条 → 隐藏（点开别无选择）', () {
        expect(PlayerPage.showAudioButton(1), isFalse,
            reason: '音轨没有"关闭"这个选项，1 条时弹层里只有一个条目');
      });

      test('★ 2 条及以上 → 显示', () {
        expect(PlayerPage.showAudioButton(2), isTrue);
        expect(PlayerPage.showAudioButton(5), isTrue);
      });
    });

    group('字幕按钮（多一个"关闭"选项，故 ≥1 条即显示）', () {
      test('0 条 → 隐藏（只有"关闭字幕"，纯噪音）', () {
        expect(PlayerPage.showSubtitleButton(0), isFalse);
      });

      test('★ 1 条 → 显示（可在"该字幕"与"关闭"之间选）', () {
        expect(PlayerPage.showSubtitleButton(1), isTrue,
            reason: '字幕多一个"关闭"选项，所以 1 条也有 2 种选择');
      });

      test('多条 → 显示', () {
        expect(PlayerPage.showSubtitleButton(3), isTrue);
      });
    });

    test('★ 字幕与音轨的判据**故意不同**（都别改成一样）', () {
      // 这是本组测试最重要的不变量：
      // 字幕有"关闭"选项 → 1 条就有得选
      // 音轨没有"关闭"     → 1 条没得选
      expect(PlayerPage.showSubtitleButton(1), isTrue);
      expect(PlayerPage.showAudioButton(1), isFalse);
    });
  });

  group('SessionStore 偏好键（防止键名写错导致静默失效）', () {
    test('default_rate 键名前缀稳定', () {
      // 键名前缀由 SessionStore 统一加 cf_pref_，这里锁定后缀
      expect(SessionStore.prefPrefix, 'cf_pref_');
    });
  });
}
