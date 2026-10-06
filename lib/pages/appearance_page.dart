/// 外观设置页 —— 主题色四选一（青/绿/紫/橙，运行时切换并持久化）
/// 配色基准保持深蓝夜色背景，仅切换强调色系（对齐原型 theme-dots）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../state/providers.dart';

class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    Future(() async {
      final store = ref.read(sessionStoreProvider);
      final idx =
          int.tryParse(await store.getPref('theme_index') ?? '') ?? 0;
      if (mounted) setState(() => _selected = idx);
    });
  }

  Future<void> _apply(int index) async {
    setState(() => _selected = index);
    Cf.applyTheme(index);
    ref.read(themeIndexProvider.notifier).set(index); // 全树重建换色
    await ref.read(sessionStoreProvider).setPref('theme_index', '$index');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            BackButton(color: Cf.text),
            const Text('外观',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 16),

          // —— 主题色 ——
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Cf.surface,
              border: Border.all(color: Cf.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              const Text('主题色',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              const Text('强调色与主按钮渐变 · 立即生效',
                  style: TextStyle(fontSize: 11, color: Cf.text3)),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                for (var i = 0; i < Cf.themePresets.length; i++)
                  GestureDetector(
                    onTap: () => _apply(i),
                    child: Column(children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Cf.themePresets[i].$2,
                              Cf.themePresets[i].$3,
                            ],
                          ),
                          border: Border.all(
                              color: _selected == i
                                  ? Colors.white
                                  : Colors.transparent,
                              width: 2.5),
                          boxShadow: _selected == i
                              ? [
                                  BoxShadow(
                                      color: Cf.themePresets[i]
                                          .$2
                                          .withValues(alpha: .5),
                                      blurRadius: 14),
                                ]
                              : null,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(Cf.themePresets[i].$1,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: _selected == i
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: _selected == i
                                  ? Cf.text
                                  : Cf.text3)),
                    ]),
                  ),
              ]),
            ]),
          ),
          const SizedBox(height: 14),

          // —— 深色模式 ——
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Cf.surface,
              border: Border.all(color: Cf.border),
            ),
            child: Row(children: [
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('深色模式',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w800)),
                  SizedBox(height: 3),
                  Text('CineFlow 为沉浸观影而生，始终使用深色主题',
                      style: TextStyle(fontSize: 11, color: Cf.text3)),
                ]),
              ),
              Text('始终开启',
                  style: TextStyle(fontSize: 11, color: Cf.accent)),
            ]),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
