/// **音量架构**回归测试（K3.5）。
///
/// ## 本轮把音量统一到系统通道，这引入了三类**只有测试能守住**的缺陷
///
/// 1. **回环**：自己 `set()` 也会触发系统广播 ⇒ "设置→广播→再设置"
///    无限循环（UI 抖动、CPU 空转）。
///    测试要断言"**相同值被丢弃**"。
/// 2. **双重衰减**：内核音量若不为 unity，实际响度 = 系统 × 内核
///    （系统 50% × 内核 50% = 25%）。测试要断言架构约束。
/// 3. **duck 走错通道**：音频焦点闪避若改**系统**音量，
///    会把用户手机的音量改小且**不会自动恢复** ——
///    退出 App 后手机声音莫名变小。测试要断言 duck 仍走内核。
///
/// ## 为什么这些必须靠测试
/// 三类在真机上都**表现为"感觉不太对"**，很难归因：
/// · 回环 → UI 抖一下（用户以为是动画）
/// · 双重衰减 → "怎么声音这么小"（用户以为片源问题）
/// · duck 走错 → 退出后手机变小（用户根本不会联想到播放器）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去注释后的源码（**断言必须用它**，见 AGENTS §8.4①）。
String readCode(String path) {
  var s = File(path).readAsStringSync();
  s = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  s = s.replaceAll(RegExp(r'//[^\n]*'), '');
  return s;
}

void main() {
  group('★ 音量架构：单一事实源 = 系统音量', () {
    late String flow;

    setUpAll(() {
      flow = readCode('lib/player/player_flow_page.dart');
    });

    test('★ 手势/滑块走 VolumeService（不是内核 setVolume）', () {
      final i = flow.indexOf('onVolumeChanged:');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 onVolumeChanged');
      // 取到下一个逗号后的换行（该回调是一行）
      final body = flow.substring(i, (i + 400).clamp(0, flow.length));

      expect(body.contains('_volumeService.set('), isTrue,
          reason: '★ 音量必须落到**系统通道**（VolumeService）。\n'
              '    改回 `_kernel?.setVolume(...)` 会立刻重现两个问题：\n'
              '    ① 按手机侧边键时 App 滑块不动\n'
              '    ② 系统音量 × 内核音量 = 双重衰减');
      expect(body.contains('_kernel?.setVolume'), isFalse,
          reason: '★ 这里不该再调内核音量（那就是双重衰减的来源）');
    });

    test('★ 内核音量固定为 unity（消除双重衰减）', () {
      expect(flow.contains('kKernelUnityVolume'), isTrue,
          reason: '起播时应把内核音量显式设为 unity');

      final i = flow.indexOf('kKernelUnityVolume = ');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到常量定义');
      final def = flow.substring(i, (i + 60).clamp(0, flow.length));
      expect(def.contains('100'), isTrue,
          reason: 'mpv/Media3 侧 100 = unity（内核会换算成 1.0）');
    });
  });

  group('★ 回环防护（自己 set 也会收到广播）', () {
    late String svc;

    setUpAll(() {
      svc = readCode('lib/player/infrastructure/system/system_services.dart');
    });

    test('★ 监听回调按值去重（相同值必须丢弃）', () {
      final i = svc.indexOf('void startListening()');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 startListening');
      // 用下一个方法名作右边界 —— 别拍长度（会吃到相邻方法，见 AGENTS §8.4①）
      final j = svc.indexOf('Future<void> stopListening()', i);
      expect(j, greaterThan(i), reason: '找不到 stopListening（边界锚点）');
      final body = svc.substring(i, j);

      // ⚠️ 断言必须**精确到"去重那一行"**，不能用裸关键字。
      //
      // 实测（反向注入暴露）：原来写 `contains('_value')` + `contains('return')`，
      // 而这两个词在方法里**还有别的来源**
      //   · `_value = c;`（第 10 行赋值）
      //   · `if (_sub != null) return;` / `if (v == null) return;`（其他分支）
      // ⇒ **把去重行整个删掉，断言照样为真**（假绿）。
      //
      // 去重行的**语义**是"**差值比较 + 同一行 return**"，
      // 且它必须**在** `onSystemChanged?.call` **之前**（顺序也是语义）。
      final lines = body.split('\n');
      final dedupLine = lines.indexWhere(
          (l) => l.contains('abs(') && l.contains('<') && l.contains('return'),
      );
      expect(dedupLine, greaterThanOrEqualTo(0),
          reason: '★ 找不到"差值比较 + return"的去重逻辑。\n'
              '    它是防回环的关键：我们自己 `set()` 后系统会回发广播，\n'
              '    不去重就形成"设置→广播→再设置"回环（UI 抖动 + CPU 空转）。');

      // 顺序也要守：先去重，再上报
      final callLine = lines.indexWhere((l) => l.contains('onSystemChanged?.call'));
      expect(callLine, greaterThan(dedupLine),
          reason: '★ 去重必须**在**上报之前 —— 顺序反了等于没去重');
    });

    test('★ set() 先更新本地值（让回环广播能被去重）', () {
      final i = svc.indexOf('Future<void> set(double v)');
      expect(i, greaterThanOrEqualTo(0));
      final j = svc.indexOf('class ', i);
      final body = svc.substring(i, j > i ? j : svc.length);

      final setLocal = body.indexOf('_value = c');
      final callNative = body.indexOf('invokeMethod');
      expect(setLocal, greaterThanOrEqualTo(0),
          reason: 'set 里必须更新 `_value`');
      expect(callNative, greaterThanOrEqualTo(0));
      expect(setLocal, lessThan(callNative),
          reason: '★ 必须**先**更新本地值**再**调原生 ——\n'
              '    这样紧跟着回来的广播值等于 `_value` ⇒ 被去重滤掉。\n'
              '    顺序反了则自触发广播会被当成"用户改了音量"，形成回环。');
    });

    test('★ syncFromSystem 不得触发 onChanged（否则回写系统形成回环）', () {
      final ac =
          readCode('lib/player/application/controllers/audio_controller.dart');
      final i = ac.indexOf('void syncFromSystem(double volume)');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 syncFromSystem');
      // 右边界：下一个方法或类尾
      final j = ac.indexOf('void setDelay', i);
      final body = ac.substring(i, j > i ? j : (i + 600).clamp(0, ac.length));

      expect(body.contains('_emit()'), isFalse,
          reason: '★ `syncFromSystem` **绝不能**调 `_emit()` ——\n'
              '    它会触发宿主 `onVolumeChanged` ⇒ 回写系统音量 ⇒\n'
              '    "系统→UI→系统"回环。\n'
              '    系统变化是既成事实，UI 只需跟随显示。');
      expect(body.contains('state = state.copyWith'), isTrue,
          reason: '但仍要更新 state（riverpod 据此刷新 UI）');
    });
  });

  group('★ 音频焦点 duck 必须走内核（不能改系统音量）', () {
    late String flow;

    setUpAll(() {
      flow = readCode('lib/player/player_flow_page.dart');
    });

    test('★ duck 改内核音量，不碰系统音量', () {
      final i = flow.indexOf("case 'duck':");
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 duck 分支');
      final j = flow.indexOf("case 'unduck':", i);
      expect(j, greaterThan(i));
      final body = flow.substring(i, j);

      expect(body.contains('k?.setVolume'), isTrue,
          reason: '★ duck **必须**改内核音量。\n'
              '    若改成系统音量：会把**用户手机**的媒体音量改小，\n'
              '    且**不会自动恢复** ⇒ 用户退出 App 后手机声音莫名变小。\n'
              '    这是 Android 上很典型的错误（map 到用户可见的设置项）。');
      expect(body.contains('_volumeService'), isFalse,
          reason: '★ duck **不得**碰系统音量通道');
    });

    test('★ unduck 还原到 unity（不是用 UI 换算函数）', () {
      final i = flow.indexOf("case 'unduck':");
      expect(i, greaterThanOrEqualTo(0));
      final j = flow.indexOf("case 'resumeAfterFocusGain':", i);
      final body = flow.substring(i, j > i ? j : (i + 500).clamp(0, flow.length));

      expect(body.contains('kKernelUnityVolume'), isTrue,
          reason: '★ 没记到原值时要回到 unity（内核恒定值）');
      expect(body.contains('volumeToKernel'), isFalse,
          reason: '★ **不得**用 `volumeToKernel` ——\n'
              '    那是"UI 0–1 → 内核 0–100"的**用户音量**换算；\n'
              '    内核现在恒定 unity，语义已不同。用错会让内核音量\n'
              '    跟着 UI 变（双重衰减重现）。');
    });

    test('★ duck 记的是内核音量，不是 UI 音量', () {
      final i = flow.indexOf("case 'duck':");
      final j = flow.indexOf("case 'unduck':", i);
      final body = flow.substring(i, j);

      expect(body.contains('k?.state.volume'), isTrue,
          reason: '★ 要记**内核**当前音量供还原。\n'
              '    记 UI 音量（`audioStateProvider`）是错的 —— 那是系统音量，\n'
              '    与内核量纲/用途都不同。');
    });
  });

  group('★ 系统音量监听（本轮核心需求：侧边键要同步 UI）', () {
    late String flow;

    setUpAll(() {
      flow = readCode('lib/player/player_flow_page.dart');
    });

    test('★ 起播时读系统音量初值（否则滑块与实际响度不符）', () {
      expect(flow.contains('_volumeService.init()'), isTrue,
          reason: '★ 不读初值 ⇒ 滑块显示默认值，与实际系统音量不符');
    });

    test('★ 启动监听并把系统变化同步给 UI', () {
      expect(flow.contains('startListening()'), isTrue,
          reason: '★ 不监听 ⇒ 按侧边键时 App 滑块不动（本轮要修的正是这个）');
      expect(flow.contains('onSystemChanged'), isTrue,
          reason: '订阅系统变化回调');

      final i = flow.indexOf('onSystemChanged = ');
      expect(i, greaterThanOrEqualTo(0));
      final body = flow.substring(i, (i + 300).clamp(0, flow.length));
      expect(body.contains('syncFromSystem'), isTrue,
          reason: '★ 收到系统变化要调 `syncFromSystem` ——\n'
              '    它**不触发** onChanged，避免回写系统形成回环');
    });

    test('★ 退出时停掉监听（避免悬挂回调）', () {
      expect(flow.contains('stopListening()'), isTrue,
          reason: '★ 不停 ⇒ 退出后每次按侧边键仍唤醒已 dispose 的页面\n'
              '    （回调里用 `ref` 会抛异常）');
    });

    test('★ 原生侧监听用 VOLUME_CHANGED_ACTION（跟参考实现一致）', () {
      final kt = readCode(
          'android/app/src/main/kotlin/com/cineflow/app/system/SystemChannel.kt');
      expect(kt.contains('VOLUME_CHANGED_ACTION'), isTrue,
          reason: '★ 用系统广播 `android.media.VOLUME_CHANGED_ACTION`\n'
              '    （Next Player `VolumeState.kt:204` 同款）。\n'
              '    注意它是 hidden 常量，只能写字面量。');
      expect(kt.contains('registerReceiver'), isTrue);
      expect(kt.contains('unregisterReceiver'), isTrue,
          reason: '★ 必须成对：只注册不注销会泄漏 receiver');
    });

    test('★ API 33+ 注册广播要声明导出性（否则抛 SecurityException）', () {
      final kt = readCode(
          'android/app/src/main/kotlin/com/cineflow/app/system/SystemChannel.kt');
      expect(kt.contains('RECEIVER_NOT_EXPORTED'), isTrue,
          reason: '★ API 33+ 起 `registerReceiver` **必须**显式声明导出性，\n'
              '    否则直接抛 SecurityException（实测会崩）。\n'
              '    这是系统广播 ⇒ NOT_EXPORTED 正确。');
    });
  });
}
