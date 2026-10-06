/// Patrol 环境自检——**不依赖应用任何代码**。
///
/// 这个文件只做一件事：证明 Patrol 的测试链路本身是通的
/// （Dart 测试 → PatrolJUnitRunner → 真机 Activity → 断言回传）。
/// 它刻意只用一个 Flutter 框架自带的 widget，不碰 CineFlow 的
/// ProviderScope / 网络 / 安全存储——任何一环出问题都会干扰
/// "到底是 Patrol 没配好，还是应用启动失败"的判断。
///
/// 跑法：patrol test -t patrol_test/harness_smoke_test.dart
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

void main() {
  patrolTest(
    'Patrol 环境自检：建树 → 找到控件 → 点击生效',
    ($) async {
      var taps = 0;

      await $.pumpWidgetAndSettle(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('cineflow-harness')),
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('harness-ready'),
                    TextButton(
                      onPressed: () => setState(() => taps++),
                      child: Text('tapped-$taps'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      // 1. 控件树渲染出来了
      expect($('harness-ready'), findsOneWidget);

      // 2. 点击真的传到了 Flutter 侧（不是只找到控件就完事）
      await $('tapped-0').tap();
      expect($('tapped-1'), findsOneWidget);

      // 3. 再来一次，确认不是巧合
      await $('tapped-1').tap();
      expect($('tapped-2'), findsOneWidget);
    },
  );
}
