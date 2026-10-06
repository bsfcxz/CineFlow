/// 冷启动到登录页这段过程的**回归守护**（2026-10 用户反馈）。
///
/// # 用户反馈
/// > "ui 中的启动页 / 闪屏页有问题，先暂时直接去除这个，保留登录页。"
/// > "我说的是应用加载到登录页面的这个过程产生的启动/闪屏页有问题。"
///
/// # 根因：这条链路上 logo 出现了**三次，尺寸形态全都不同**
///
/// | 阶段 | 显示 | 尺寸 / 形态 |
/// |---|---|---|
/// | ① Android 系统启动图（API 31+ 强制） | `launch_logo` | 288×288 圆角方块，被系统**裁成圆形** |
/// | ② Dart `/splash` 路由 | `CfLogo(size: 56, radius: 16)` | 56dp 圆角方块 |
/// | ③ 登录页 | `CfLogo()` | 默认 **52dp / radius 14** |
///
/// 肉眼看到的就是"图标跳一下、再变一次"。
///
/// # 修法（两层一起改才算数）
///
/// **Dart 侧**
///   · 删除 `/splash` 路由（`lib/core/router.dart`）
///   · `main.dart` 在 `runApp` **之前**用 `ProviderContainer` 预热会话
///     （首帧前恢复完 → 加载态根本不出现）
///
/// **Android 侧**
///   · 启动图只留**纯品牌底色**，去掉 logo（`launch_background.xml`、`values-v31`）
///   · 补 `values-night-v31/styles.xml` —— 修一个真实的限定符 bug
///   · `NormalTheme.windowBackground` 由 `?android:colorBackground` 改为 `@color/cf_bg`
///
/// 于是整条链路只剩一种视觉：
///    启动图(#0B1020) → 首帧窗口背景(#0B1020) → 登录页(Cf.bg = #0B1020)
/// **三者同色 → 无缝**，登录页的 `CfLogo` 随页面一起出现。
///
/// # 为什么用源码断言
/// 这一段横跨 Dart 与 Android 资源，**没有一门单元测试能直接跑它**
/// （真机还得看启动瞬间，而我读不了图）。源码断言能精确守住"别把 logo 加回来"，
/// 且反向注入可验证 —— 这是本批唯一可行且可靠的守线方式。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读 Dart 源码并剥掉整行注释（注释里提到被删的东西会造成**假绿** —— 实测踩过）。
String _code(String rel) => File(rel)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final s = l.trimLeft();
      return !s.startsWith('//') && !s.startsWith('*');
    })
    .join('\n');

/// 读 XML 资源并剥掉 **`<!-- ... -->` 注释块**。
///
/// ## ⚠️ 为什么要单独写一个（实测踩过）
///
/// 第一版直接复用了 [_code]（只剥 `//` 行）。但 XML 的注释是 `<!-- -->` **块**，
/// 于是 `<!-- ... launch_logo ... -->` 里的说明文字被当成**代码**匹配到，
/// 两个断言**假红**：代码里明明已经没有 logo 了，测试却说有。
///
/// 这和之前那个"注释导致假绿"的坑是同一类问题的镜像 ——
/// **凡是基于源码文本的断言，剥注释的口径必须与文件语法匹配**：
/// Dart 用 `//`，XML 用 `<!-- -->`。
String _xml(String rel) {
  final raw = File(rel).readAsStringSync();
  // 去掉完整的 <!-- ... --> 块（含跨行）
  final noBlock = raw.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  // 再去掉落在块外但以 * 开头的残留行（防御性）
  return noBlock
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('*'))
      .join('\n');
}

void main() {
  group('冷启动 · Dart 侧：不再有中间过渡页', () {
    test('router.dart 里没有 /splash 路由', () {
      final src = _code('lib/core/router.dart');
      expect(
        src.contains('/splash'),
        isFalse,
        reason: '又出现了 /splash 路由。\n'
            '它会在系统启动图与登录页之间插入**第三个尺寸不同的 logo**，\n'
            '用户看到的就是"图标跳一下再变一次"。\n'
            '会话恢复已改为在 main.dart 首帧前预热完成。',
      );
      expect(src.contains('Routes.splash'), isFalse);
    });

    test('登录页路由仍在（用户要求保留）', () {
      final src = _code('lib/core/router.dart');
      expect(src.contains("path: Routes.login"), isTrue,
          reason: '登录页路由被误删了 —— 用户明确要求"保留登录页"');
    });

    test('会话恢复期间落登录页，不落首页（首页非空依赖 api 会红屏）', () {
      final src = _code('lib/core/router.dart');
      // resolveRedirect 的 isLoading 分支应返回 Routes.login
      final i = src.indexOf('session.isLoading');
      expect(i, greaterThan(-1), reason: '找不到 isLoading 分支');
      final branch = src.substring(i, i + 220);
      expect(
        branch.contains('Routes.login'),
        isTrue,
        reason: '恢复期间没有落登录页。\n'
            '若放行首页：HomePage 是 `ref.read(embyApiProvider)!`，\n'
            '而该 provider 依赖 sessionProvider.value（恢复中为 null）\n'
            '→ 抛 Null check operator used on a null value（红屏）。',
      );
      expect(
        branch.contains('Routes.home'),
        isFalse,
        reason: '恢复期间不能落首页 —— 会红屏（见上）',
      );
    });
  });

  group('冷启动 · Dart 侧：会话在首帧前预热', () {
    final src = _code('lib/main.dart');

    test('runApp 之前 await 了会话预热', () {
      expect(src.contains('sessionProvider.future'), isTrue,
          reason: 'main.dart 没有预热会话。\n'
              '不预热的话首帧时 sessionProvider 仍是 AsyncLoading，\n'
              '过渡态就必然出现（红屏 / 闪登录页 / 需要第三个 logo 页）。');
      expect(src.contains('UncontrolledProviderScope'), isTrue,
          reason: '预热用的 ProviderContainer 必须交给 runApp 复用，\n'
              '否则 runApp 里会新建一个 container，预热白做（会话要恢复两次）。');
    });

    test('预热有超时且失败不阻塞启动', () {
      expect(
        RegExp(r'\.timeout\(').hasMatch(src),
        isTrue,
        reason: '预热没有超时。flutter_secure_storage 底层是 Keystore 解密，\n'
            '设备密钥损坏时可能迟迟不返回 —— 绝不能因恢复失败而不启动。',
      );
      expect(
        RegExp(r'catch\s*\(').hasMatch(src),
        isTrue,
        reason: '预热没有兜异常。失败时应按未登录继续（走登录页，用户重登即可），\n'
            '而不是让整个 App 起不来。',
      );
    });
  });

  group('冷启动 · Android 侧：启动图只剩纯品牌底色', () {
    test('launch_background（API<21 与 API>=21）都不含 logo', () {
      for (final f in [
        'android/app/src/main/res/drawable/launch_background.xml',
        'android/app/src/main/res/drawable-v21/launch_background.xml',
      ]) {
        final x = _xml(f);
        expect(
          x.contains('launch_logo'),
          isFalse,
          reason: '$f 又引用了 launch_logo。\n'
              '启动图上的 logo 会被系统裁成圆形，而登录页的 CfLogo 是圆角方块\n'
              '→ 形态不一致 = 肉眼可见的跳变。',
        );
        expect(
          x.contains('@color/cf_bg'),
          isTrue,
          reason: '$f 应保留品牌底色（与登录页 Cf.bg 同色，才能无缝过渡）',
        );
      }
    });

    test('values-v31 用透明图标（不回落画 android:icon）', () {
      final x = _xml('android/app/src/main/res/values-v31/styles.xml');
      expect(
        x.contains('windowSplashScreenBackground'),
        isTrue,
        reason: '必须显式声明启动图背景。\n'
            '若这些属性整个不声明，系统会**回落用 android:icon**\n'
            '（自适应图标 88% 透明安全区 + 圆形遮罩）绘制启动图。',
      );
      expect(
        x.contains('cf_splash_blank'),
        isTrue,
        reason: '启动图图标应为**透明**的 cf_splash_blank —— 启动图上不该有 logo',
      );
      expect(
        x.contains('launch_logo'),
        isFalse,
        reason: 'values-v31 又用了 launch_logo —— 会被裁成圆形，与登录页不一致',
      );
    });

    test('★ values-night-v31 存在（修资源限定符 bug）', () {
      // Android 资源解析中 **UI 模式(-night) 优先级高于平台版本(-v31)**。
      // 只在 values-v31 声明 windowSplashScreen* 时，深色模式会选到
      // values-night（没有这些属性）→ 系统回落画 android:icon（圆形裁切）。
      // 现象：同一个 App 的启动画面随系统主题改变。
      final f = File(
          'android/app/src/main/res/values-night-v31/styles.xml');
      expect(
        f.existsSync(),
        isTrue,
        reason: '缺少 values-night-v31/styles.xml。\n'
            'night 限定符优先级高于 v31 → 深色模式下会选到没有\n'
            'windowSplashScreen* 的 values-night，系统回落用 android:icon\n'
            '（圆形遮罩 + 88% 透明安全区）画启动图 → 深色模式启动图与浅色不一致。',
      );
      final x = _xml(f.path);
      expect(x.contains('windowSplashScreenBackground'), isTrue);
      expect(x.contains('cf_splash_blank'), isTrue);
      expect(x.contains('launch_logo'), isFalse);
    });

    test('三处 NormalTheme 背景都是品牌色（不再是 ?android:colorBackground）', () {
      // ?android:colorBackground 在浅色系统主题下解析为**纯白** ——
      // 它垫在 Flutter UI 背后，首帧前会闪一整屏白。
      for (final f in [
        'android/app/src/main/res/values/styles.xml',
        'android/app/src/main/res/values-night/styles.xml',
        'android/app/src/main/res/values-night-v31/styles.xml',
      ]) {
        final x = _xml(f);
        if (!x.contains('NormalTheme')) continue;
        final i = x.indexOf('NormalTheme');
        final seg = x.substring(i);
        expect(
          seg.contains('@color/cf_bg'),
          isTrue,
          reason: '$f 的 NormalTheme 没用品牌底色。\n'
              '?android:colorBackground 在浅色主题下是纯白 → 首帧前闪白屏。',
        );
      }
    });
  });

  group('冷启动 · 整条链路同色（无缝过渡的前提）', () {
    test('启动图底色 == NormalTheme 底色 == Cf.bg', () {
      final colors =
          _xml('android/app/src/main/res/values/colors.xml');
      expect(
        colors.contains('#FF0B1020'),
        isTrue,
        reason: 'cf_bg 应等于 Cf.bg(#0B1020)。\n'
            '三者同色是"零跳变"的前提：\n'
            '  启动图 → NormalTheme 窗口背景 → 登录页背景',
      );

      final theme = _code('lib/core/theme.dart');
      expect(
        theme.contains('0xFF0B1020') || theme.contains('0B1020'),
        isTrue,
        reason: 'lib/core/theme.dart 里的 Cf.bg 应与 colors.xml 的 cf_bg 一致',
      );
    });
  });
}
