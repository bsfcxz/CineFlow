/// 弹幕设置页 —— 配置弹幕源、外观、屏蔽词。
///
/// ## 为什么需要这一页
///
/// 弹幕源需要用户自己提供（本仓库不含任何凭据，见 danmaku_config.dart）：
///   - 官方弹弹play：需去 <https://dev.dandanplay.com> 申请 AppId/AppSecret
///   - 自建服务：需自己部署 danmu_api / misaka_danmu_server 并填地址
///
/// 两种形态**必填项完全不同**（一个要密钥，一个只要地址），
/// 所以按 kind 动态切换表单，而不是把两组字段都摆出来让用户猜。
///
/// ## 为什么 AppSecret 用 obscureText
///
/// 它在官方方案里是签名密钥；`SessionStore` 底层是
/// `flutter_secure_storage`（Android Keystore），存储层已加密。
/// 输入框遮挡只是防"旁边有人看到"。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import 'danmaku_config.dart';
import 'danmaku_providers.dart';

class DanmakuSettingsPage extends ConsumerStatefulWidget {
  const DanmakuSettingsPage({super.key});

  @override
  ConsumerState<DanmakuSettingsPage> createState() =>
      _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends ConsumerState<DanmakuSettingsPage> {
  late TextEditingController _base;
  late TextEditingController _appId;
  late TextEditingController _appSecret;
  late TextEditingController _blocked;

  /// 地址归一化的提示（"已自动补 http://" 这类）
  String? _urlNote;

  /// 拖动中的临时值。
  ///
  /// ## 为什么需要它（真实性能问题）
  ///
  /// 若直接在 `onChanged` 里调 `patch()`，拖动一次滑块会触发
  /// **每帧一次**的持久化：JSON 编码 → `flutter_secure_storage` 写入
  /// （底层是 Android Keystore 加解密 + 磁盘）→ invalidate 客户端。
  /// 一次拖动几十帧就是几十次加密写盘，明显卡顿且损耗闪存。
  ///
  /// 正确做法：`onChanged` 只更新这里的本地状态（UI 立刻跟手），
  /// `onChangeEnd` 才写一次盘。见 [_slider]。
  final _draft = <String, double>{};

  double _val(String key, double fallback) => _draft[key] ?? fallback;

  @override
  void initState() {
    super.initState();
    final c = ref.read(danmakuConfigProvider).value ?? const DanmakuConfig();
    _base = TextEditingController(text: c.baseUrl);
    _appId = TextEditingController(text: c.appId);
    _appSecret = TextEditingController(text: c.appSecret);
    _blocked = TextEditingController(text: c.blockedWords.join(' '));
  }

  @override
  void dispose() {
    _base.dispose();
    _appId.dispose();
    _appSecret.dispose();
    _blocked.dispose();
    super.dispose();
  }

  /// 保存前做一次归一化与校验。
  ///
  /// 地址错了的表现是"弹幕不出来"，用户很难自己定位，
  /// 所以这里**能自动纠正的就纠正**（补协议头、剥多余路径），
  /// 不能纠正的给出中文原因并拒绝保存。
  Future<void> _save() async {
    final notifier = ref.read(danmakuConfigProvider.notifier);
    final cur = ref.read(danmakuConfigProvider).value ?? const DanmakuConfig();

    var base = _base.text;
    if (cur.kind == DanmakuProviderKind.selfHosted) {
      final (normalized, note) = DanmakuUrl.normalizeBase(base);
      final err = DanmakuUrl.validate(normalized);
      if (err != null) {
        setState(() => _urlNote = err);
        return;
      }
      base = normalized;
      _base.text = normalized;
      setState(() => _urlNote = note);
    }

    await notifier.save(cur.copyWith(
      baseUrl: base,
      appId: _appId.text.trim(),
      appSecret: _appSecret.text.trim(),
      blockedWords: _blocked.text
          .split(RegExp(r'[\s,，]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false),
    ));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(danmakuConfigProvider);
    final c = async.value ?? const DanmakuConfig();

    return Scaffold(
      backgroundColor: Cf.bg,
      appBar: AppBar(
        backgroundColor: Cf.bg,
        foregroundColor: Cf.text,
        title: Text('弹幕设置', style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text('保存', style: TextStyle(color: Cf.accent)),
          ),
        ],
      ),
      body: async.isLoading
          ? Center(child: CircularProgressIndicator(color: Cf.accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _group('弹幕源'),
                // 源类型：三种形态的必填项完全不同，选错会让人困惑。
                // 用 RadioGroup 而不是给每个 RadioListTile 传 groupValue——
                // 后者在本 Flutter 版本已废弃（deprecated after v3.32）。
                RadioGroup<DanmakuProviderKind>(
                  groupValue: c.kind,
                  onChanged: (v) {
                    if (v == null) return;
                    ref.read(danmakuConfigProvider.notifier).patch(kind: v);
                  },
                  child: Column(children: [
                    for (final k in DanmakuProviderKind.values)
                      _radio(k),
                  ]),
                ),

                if (c.kind == DanmakuProviderKind.official) ...[
                  SizedBox(height: 8),
                  _hint('在 dev.dandanplay.com 创建应用后获得 AppId 与 AppSecret。\n'
                      '本项目不含任何内置凭据，需你自己填写（仅存本机安全存储）。'),
                  _field(_appId, 'AppId', hint: '例如 abc123'),
                  _field(_appSecret, 'AppSecret', obscure: true),
                ],

                if (c.kind == DanmakuProviderKind.selfHosted) ...[
                  SizedBox(height: 8),
                  _hint('填到地址/token 为止，不要带 /api/v2。\n'
                      '例：http://192.0.2.10:9321 或 http://192.0.2.10:9321/mytoken\n'
                      '（御坂服务可加 /api/v1/{token}）'),
                  _field(_base, '服务地址', hint: 'http://192.0.2.10:9321'),
                  if (_urlNote != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_urlNote!,
                          style: TextStyle(
                              fontSize: 11, color: Cf.accent)),
                    ),
                ],

                SizedBox(height: 20),
                _group('外观'),
                _slider('不透明度', _val('opacity', c.opacity), 0.2, 1.0,
                    onChanged: (v) => setState(() => _draft['opacity'] = v),
                    onCommit: (v) => ref
                        .read(danmakuConfigProvider.notifier)
                        .patch(opacity: v)),
                _slider('字号', _val('fontScale', c.fontScale), 0.6, 1.8,
                    onChanged: (v) => setState(() => _draft['fontScale'] = v),
                    onCommit: (v) => ref
                        .read(danmakuConfigProvider.notifier)
                        .patch(fontScale: v)),
                _slider('显示区域', _val('showArea', c.showArea), 0.3, 1.0,
                    onChanged: (v) => setState(() => _draft['showArea'] = v),
                    onCommit: (v) => ref
                        .read(danmakuConfigProvider.notifier)
                        .patch(showArea: v)),

                // ---- 以下对照 B 站「弹幕设置」面板补齐 ----
                //
                // B 站把这些放在**播放器内的弹幕面板**里（不跳设置页），
                // 因为"看着看着觉得碍事"是最常见的诉求。
                // 本项目把它们收在同页，理由：设置页已存在且一致；
                // 关键是**要有这些开关**，位置次之。
                SizedBox(height: 20),
                _group('弹幕类型'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('关掉某类可以避免遮挡画面（B 站同款开关）',
                      style: Cf.micro),
                ),
                Wrap(spacing: Cf.gap2, runSpacing: Cf.gap2, children: [
                  _modeChip('滚动', c.modes.scroll,
                      (v) => ref
                          .read(danmakuConfigProvider.notifier)
                          .patch(modes: c.modes.copyWith(scroll: v))),
                  _modeChip('顶部', c.modes.top,
                      (v) => ref
                          .read(danmakuConfigProvider.notifier)
                          .patch(modes: c.modes.copyWith(top: v))),
                  _modeChip('底部', c.modes.bottom,
                      (v) => ref
                          .read(danmakuConfigProvider.notifier)
                          .patch(modes: c.modes.copyWith(bottom: v))),
                ]),

                SizedBox(height: 16),
                _slider('弹幕速度', _val('speed', c.speed), 0.5, 2.0,
                    onChanged: (v) => setState(() => _draft['speed'] = v),
                    onCommit: (v) => ref
                        .read(danmakuConfigProvider.notifier)
                        .patch(speed: v)),

                SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: c.bold,
                  onChanged: (v) => ref
                      .read(danmakuConfigProvider.notifier)
                      .patch(bold: v),
                  title: Text('弹幕加粗', style: Cf.body),
                  subtitle: Text('小屏/弱网下更易读', style: Cf.micro),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: c.avoidSubtitle,
                  onChanged: (v) => ref
                      .read(danmakuConfigProvider.notifier)
                      .patch(avoidSubtitle: v),
                  title: Text('防挡字幕', style: Cf.body),
                  subtitle: Text('给字幕留出空间，弹幕不压字幕（建议开）', style: Cf.micro),
                ),

                SizedBox(height: 20),
                _group('屏蔽词'),
                _field(_blocked, '屏蔽词', hint: '空格分隔，如：广告 剧透 刷屏'),
                Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('包含任一屏蔽词的弹幕会被整条隐藏',
                      style: TextStyle(fontSize: 11, color: Cf.text3)),
                ),

                SizedBox(height: 20),
                _group('其他'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: c.enabled,
                  onChanged: (v) =>
                      ref.read(danmakuConfigProvider.notifier).patch(enabled: v),
                  title: Text('启用弹幕',
                      style: TextStyle(fontSize: 14, color: Cf.text)),
                  subtitle: Text('关闭后不影响播放，只是不显示弹幕',
                      style: TextStyle(fontSize: 11, color: Cf.text3)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: c.useAsync,
                  onChanged: (v) =>
                      ref.read(danmakuConfigProvider.notifier).patch(useAsync: v),
                  title: Text('异步生成（御坂服务 2.7.0+）',
                      style: TextStyle(fontSize: 14, color: Cf.text)),
                  subtitle: Text(
                      '服务端没有该集弹幕时，等待其现场生成（最长 5 分钟）。\n'
                      '其他服务会忽略此选项，开启无害',
                      style: TextStyle(fontSize: 11, color: Cf.text3)),
                ),
              ],
            ),
    );
  }

  Widget _group(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(title,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Cf.text2)),
      );

  /// 「滚动 / 顶部 / 底部」类型开关（对照 B 站的弹幕类型三连开关）。
  ///
  /// 用 FilterChip 而不是 Switch：B 站的做法是**一排可切换的标签**，
  /// 一眼能看出当前开了哪几类；Switch 竖排占地方且要读文字才知道状态。
  /// 命中区遵循 48dp（`Cf` 主题已给 chip 设了 minimumSize）。
  Widget _modeChip(String label, bool selected, ValueChanged<bool> onChanged) {
    return FilterChip(
      label: Text(label, style: Cf.caption),
      selected: selected,
      onSelected: onChanged,
      showCheckmark: true,
      checkmarkColor: Cf.ink,
      backgroundColor: Cf.surface2,
      selectedColor: Cf.accent,
      labelStyle: Cf.caption.copyWith(
        color: selected ? Cf.ink : Cf.text2,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide(color: selected ? Cf.accent : Cf.border),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, color: Cf.text3, height: 1.5)),
      );

  Widget _radio(DanmakuProviderKind kind) => RadioListTile<
      DanmakuProviderKind>(
    contentPadding: EdgeInsets.zero,
    dense: true,
    value: kind,
    activeColor: Cf.accent,
    title: Text(kind.label,
        style: TextStyle(fontSize: 14, color: Cf.text)),
  );

  Widget _field(TextEditingController ctl, String label,
          {bool obscure = false, String? hint}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: ctl,
          obscureText: obscure,
          style: TextStyle(fontSize: 14, color: Cf.text),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            labelStyle: TextStyle(fontSize: 13, color: Cf.text3),
            hintStyle: TextStyle(fontSize: 13, color: Cf.text3),
            filled: true,
            fillColor: Cf.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Cf.border),
            ),
          ),
        ),
      );

  /// 可拖动滑块。
  ///
  /// [onChanged] 只更新本地草稿（保证跟手），[onCommit] 在松手时才落盘。
  /// 这样一次拖动只写一次 secure_storage（见 `_draft` 的说明）。
  Widget _slider(
    String label,
    double value,
    double min,
    double max, {
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onCommit,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          SizedBox(
            width: 64,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: Cf.text2)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              activeColor: Cf.accent,
              onChanged: onChanged,
              onChangeEnd: onCommit,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(value.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: Cf.text3)),
          ),
        ]),
      );
}
