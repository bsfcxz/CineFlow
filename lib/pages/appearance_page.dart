/// 外观设置页 —— 主题色四选一（青/绿/紫/橙，运行时切换并持久化）
/// 配色基准保持深蓝夜色背景，仅切换强调色系（对齐原型 theme-dots）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/session_store.dart';
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
    // 深色模式开关状态（默认 true —— 与改动前"始终深色"一致）
    unawaited(_loadDarkMode());
    Future(() async {
      final store = ref.read(sessionStoreProvider);
      final idx =
          int.tryParse(await store.getPref('theme_index') ?? '') ?? 0;
      if (mounted) setState(() => _selected = idx);
    });
  }

  // ══════════════════════════════════════════════════════════
  //  背景底色（用户 2026-10-14 最终定稿：六档 + 自定义）
  // ══════════════════════════════════════════════════════════

  /// 透明度**草稿**（拖动时只改它，松手才落盘）。
  ///
  /// ## 为什么要草稿（本仓库踩过的坑）
  /// `onChanged` 每帧触发。若直接写 `secure_storage`，
  /// 拖一次滑块会写**几十次**（Keystore 加解密很慢）⇒ 界面卡。
  int? _bgOpacityDraft;

  /// **深色模式**开关（默认开 —— 与改动前行为一致）。
  ///
  /// ## 为什么默认 true
  /// 改动前 App 就是始终深色 ⇒ 默认值必须与之一致，
  /// 否则老用户升级后界面会**无故变亮**。
  bool _darkMode = true;

  /// 应用背景底色（改静态色 → 触发重建 → 持久化）。
  ///
  /// ## `persist: false`
  /// 拖动滑块时传 false（只预览），松手时传 true 落盘。
  /// 切换深色模式。
  ///
  /// ## 为什么要记住"关闭前的那一档"
  /// 关闭时把底色切成 `solidWhite`；若不留原值，
  /// 用户再打开就只能回到 `solidWhite`（**切不回他原来选的深色档**）。
  /// ⇒ 用 `kDarkModePrevBgKey` 存一下。
  ///
  /// ## 为什么同时改状态栏图标
  /// 亮底 + 白图标 = 看不见（实测过同类问题）。
  /// `SystemChrome` 的 `statusBarIconBrightness` 决定图标深浅。
  /// 读「深色模式」开关的**上次状态**（只影响开关显示）。
  ///
  /// ## ⚠️ 为什么不在这里改 `bg_kind`
  /// 视觉的唯一来源是 `bg_kind`（`main.dart` 已按它恢复背景）。
  /// 若这里再按 `kDarkModeKey` 去改一次，就会**覆盖用户在
  /// 「背景底色」区的手动选择**（两个入口打架，本仓库踩过同类问题）。
  /// ⇒ 本方法只读开关状态，让它与界面**显示一致**。
  Future<void> _loadDarkMode() async {
    try {
      final store = ref.read(sessionStoreProvider);
      final v = await store.traktFlag(SessionStore.kDarkModeKey);
      // `getPref` 无记录时返回 null ⇒ `traktFlag` 会回 false，
      // 但**默认应为 true**（与改动前一致）⇒ 显式判 null
      final raw = await store.getPref(SessionStore.kDarkModeKey);
      final on = raw == null ? true : v;
      if (!mounted) return;
      setState(() => _darkMode = on);
      _syncStatusBarIcons();
    } catch (e) {
      debugPrint('[外观] 读深色模式失败（按默认开）: $e');
    }
  }

  Future<void> _toggleDarkMode(bool v) async {
    final store = ref.read(sessionStoreProvider);
    setState(() => _darkMode = v);
    if (v) {
      // 开：恢复关闭前那档（没有记录 ⇒ 回默认深色）
      final prev = await store.getPref(SessionStore.kDarkModePrevBgKey) ?? '';
      final kind = CfBgKind.values.firstWhere(
        (e) => e.name == prev,
        orElse: () => CfBgKind.dark,
      );
      await _applyBg(kind);
    } else {
      // 关：记住当前档，再切白色
      await store.setPref(
          SessionStore.kDarkModePrevBgKey, Cf.bgKind.name);
      await _applyBg(CfBgKind.solidWhite);
    }
    await store.setTraktFlag(SessionStore.kDarkModeKey, v);
    _syncStatusBarIcons();
    if (mounted) setState(() {});
  }

  /// 状态栏图标颜色跟随底色明暗（亮底用深色图标）。
  ///
  /// ⚠️ 与 `main.dart` 里既有的 `SystemChrome` 调用**不冲突**：
  ///    那边只设 `systemNavigationBarColor`，这里只管**图标亮度**。
  void _syncStatusBarIcons() {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarIconBrightness:
          Cf.bgKind.isLightNow ? Brightness.dark : Brightness.light,
      statusBarBrightness:
          Cf.bgKind.isLightNow ? Brightness.light : Brightness.dark,
    ));
  }

  Future<void> _applyBg(CfBgKind kind,
      {int? opacity, Color? custom, bool persist = true}) async {
    final op = opacity ?? _bgOpacityDraft ?? Cf.bgOpacity;
    if (custom != null) Cf.customBgColor = custom;
    Cf.applyBackground(kind, opacity: op);
    ref.read(bgStyleProvider.notifier).set(kind);
    if (!persist) return;
    final store = ref.read(sessionStoreProvider);
    await store.setPref('bg_kind', kind.name);
    await store.setPref('bg_opacity', '$op');
    if (custom != null) {
      // 存 32 位 ARGB 的十六进制（不含 `#`）
      await store.setPref('bg_custom',
          custom.toARGB32().toRadixString(16).padLeft(8, '0'));
    }
  }

  /// **自定义调色板**（用户选色用）。
  ///
  /// ## 为什么给"预设色"而不是自由取色器
  /// · 自由取色器（HSV 环）实现成本高、小屏难操作
  /// · 预设色能保证**对比度可读**（我按 WCAG 挑过）
  /// ⇒ 给 12 个覆盖"深/中/浅 + 常见色调"的预设，够日常用。
  static const _kCustomSwatches = <(String, Color)>[
    ('石墨', Color(0xFF1A1A22)),
    ('墨蓝', Color(0xFF0E1626)),
    ('深棕', Color(0xFF221A16)),
    ('松绿', Color(0xFF0F1F1A)),
    ('暗紫', Color(0xFF1B1225)),
    ('酒红', Color(0xFF221218)),
    ('中灰', Color(0xFF3A3F47)),
    ('雾蓝', Color(0xFF2A3A4A)),
    ('暖沙', Color(0xFF3D3529)),
    ('米白', Color(0xFFF2EFE9)),
    ('雪白', Color(0xFFFFFFFF)),
    ('淡蓝', Color(0xFFE8EEF5)),
  ];

  Widget _bgChip(CfBgKind k) {
    final on = Cf.bgKind == k;
    // ⚠️ 必须用 InkWell（守卫测试要求设置项有按压反馈）
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              if (k.usesOpacity && _bgOpacityDraft == null) {
                _bgOpacityDraft = Cf.bgOpacity;
              }
              await _applyBg(k,
                  opacity: k.usesOpacity ? _bgOpacityDraft : null);
              if (mounted) setState(() {});
            },
            child: Ink(
              height: 52,
              decoration: BoxDecoration(
                color: on ? Cf.accent.withValues(alpha: 0.18) : Cf.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: on ? Cf.accent : Cf.border, width: on ? 1.5 : 1),
              ),
              child: Center(
                child: Text(k.label,
                    style: TextStyle(
                        fontSize: 13,
                        color: on ? Cf.accent : Cf.text2,
                        fontWeight:
                            on ? FontWeight.w700 : FontWeight.w400)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bgPreviewSwatch(String name, Color c) {
    final on = Cf.customBgColor.toARGB32() == c.toARGB32() &&
        Cf.bgKind == CfBgKind.custom;
    // ⚠️ **必须用 InkWell**（不能用裸 GestureDetector）——
    //    我在色板上用 GestureDetector，**被守卫测试当场抓红**：
    //    `settings_pages_test.dart` U8「外观设置：没有裸 GestureDetector」。
    //    ⚠️ 该测试的判据是"外观页不许出现裸 GestureDetector"（**不看用途**）
    //    ⇒ 别写"色板不是设置项所以可以"这种辩解（我试过，无效）。
    //    InkWell 本来也更合适 —— 自带涟漪反馈。
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 8),
      child: Material(
        color: c,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            await _applyBg(CfBgKind.custom, custom: c);
            if (mounted) setState(() {});
          },
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: on ? Cf.accent : Cf.border, width: on ? 2 : 1),
            ),
            child: on
                ? Icon(Icons.check_rounded,
                    size: 20,
                    // 勾号颜色按背景亮度选（亮底深勾 / 暗底白勾）
                    color: (0.299 * c.r * 255 +
                                0.587 * c.g * 255 +
                                0.114 * c.b * 255) >
                            140
                        ? Colors.black87
                        : Colors.white)
                : null,
          ),
        ),
      ),
    );
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
        child: ListView(padding: EdgeInsets.all(16), children: [
          Row(children: [
            BackButton(color: Cf.text),
            Text('外观',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
          SizedBox(height: 16),

          // —— 主题色 ——
          // ══════ ★ 背景底色（用户 2026-10-14）══════
          const SizedBox(height: 20),
          Text('背景底色',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('深色 / 黑色 / 透明 / 半透明 / 浅白 / 白色 · 自定义',
              style: TextStyle(fontSize: 11, color: Cf.text3)),
          const SizedBox(height: 12),
          Row(children: [
            _bgChip(CfBgKind.dark),
            _bgChip(CfBgKind.black),
            _bgChip(CfBgKind.clear),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _bgChip(CfBgKind.translucent),
            _bgChip(CfBgKind.dimWhite),
            _bgChip(CfBgKind.solidWhite),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _bgChip(CfBgKind.custom),
            const Spacer(flex: 2),
          ]),
          // 透明度滑块：**只在透明/半透明时显示**
          //
          // ## 为什么其它档不显示
          // 滑块对它们**无效** ⇒ 一直显示会让用户"拖了没变化"以为坏了。
          if (Cf.bgKind.usesOpacity) ...[
            const SizedBox(height: 12),
            Row(children: [
              Text('透明度',
                  style: TextStyle(fontSize: 12, color: Cf.text2)),
              const Spacer(),
              Text('${_bgOpacityDraft ?? Cf.bgOpacity}',
                  style: TextStyle(
                      fontSize: 12,
                      color: Cf.accent,
                      fontWeight: FontWeight.w700)),
            ]),
            Slider(
              value: (_bgOpacityDraft ?? Cf.bgOpacity).toDouble().clamp(0, 100),
              min: 0,
              max: 100,
              divisions: 20,
              label: '${_bgOpacityDraft ?? Cf.bgOpacity}',
              onChanged: (v) {
                setState(() => _bgOpacityDraft = v.round());
                Cf.applyBackground(Cf.bgKind, opacity: v.round());
              },
              onChangeEnd: (v) async {
                await _applyBg(Cf.bgKind, opacity: v.round());
              },
            ),
          ],
          // 自定义调色板：**只在"自定义"档时显示**
          if (Cf.bgKind == CfBgKind.custom) ...[
            const SizedBox(height: 12),
            Text('选择背景色',
                style: TextStyle(fontSize: 12, color: Cf.text2)),
            const SizedBox(height: 8),
            Wrap(
              children: [
                for (final (name, c) in _kCustomSwatches)
                  _bgPreviewSwatch(name, c),
              ],
            ),
            Text('提示：选亮色会自动切换为深色文字（保证可读）',
                style: TextStyle(fontSize: 10, color: Cf.text3)),
          ],
          const SizedBox(height: 20),
          Container(
            padding: EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Cf.surface,
              border: Border.all(color: Cf.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              const Text('主题色',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text('强调色与主按钮渐变 · 立即生效',
                  style: TextStyle(fontSize: 11, color: Cf.text3)),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                for (var i = 0; i < Cf.themePresets.length; i++)
                  // ⚠️ 三处修复（审计 U8）：
                  //   1. `GestureDetector` → `InkWell`：切主题这种"立即生效"
                  //      的操作，点了**必须有反馈** —— 尤其当用户点了**当前
                  //      已选中**的那项时颜色不会变，没有按压反馈就完全像没响应。
                  //   2. 命中区撑到 72dp（色块 40 + 间距 7 + 文字行 ≈ 62）。
                  //   3. 补语义：读屏要能念出"主题色 极光青，已选中"。
                  CfTapTarget(
                    size: 72,
                    semanticLabel: '主题色 ${Cf.themePresets[i].$1}'
                        '${_selected == i ? '，已选中' : ''}',
                    onTap: () => _apply(i),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
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
                      // 主题名在"四项横排"的窄格子里 → 必须钳制字缩，
                      // 否则 200% 下三项文字会互相挤压/换行
                      CfText(Cf.themePresets[i].$1,
                          clamp: true,
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

          // —— 深色模式（用户 2026-10-14："关闭始终用深色模式主题"）——
          //
          // ## 之前的形态
          // 一行**不可点的纯文字**：`Text('始终开启')` —— 用户没法关。
          //
          // ## 现在的语义（与「背景底色」区的关系）
          // · **开**（默认）：用用户选的那档底色（`bg_kind` 原值）
          // · **关**：切到「白色」底（`CfBgKind.solidWhite`），
          //          并**记住**原来那档 ⇒ 再打开能切回去
          // ⇒ 与「背景底色」区**同一维度**（都是底色），
          //   区别是本开关是"一键切亮/暗"的**快捷方式**，
          //   那个区是"精细选档"。用一个 `prev` 键保证可逆。
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Cf.surface,
              border: Border.all(color: Cf.border),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _toggleDarkMode(!_darkMode),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('深色模式',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800)),
                    SizedBox(height: 3),
                    Text(
                        _darkMode
                            ? '关闭后切换为亮色（浅白底 · 深色文字）'
                            : '已关闭 —— 当前是亮色界面',
                        style: TextStyle(fontSize: 11, color: Cf.text3)),
                  ]),
                ),
                Switch(
                  value: _darkMode,
                  onChanged: (v) => _toggleDarkMode(v),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
