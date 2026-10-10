/// 手动匹配面板 —— 让用户**自己选**弹幕库里的哪一部哪一集。
///
/// ## 为什么必须有（外部成熟项目一致结论）
/// 自动匹配必然在两类情况下猜错，且用户**无从纠正**：
///
/// 1. **译名不同**
///    > Emby 识别为《彻夜之歌》后因为弹弹play 中为《夜曲》导致无法匹配
/// 2. **多季/剧场版/OVA 归档**
///    > 如『OVERLORD』第四季若使用 S[N] 格式归档，可能出现匹配失败/错误
///
/// `chen3861229/dd-danmaku`（401★）与 `RyoLee/emby-danmaku`（457★）
/// 的 README **都**把「手动匹配」列为界面核心功能之一。
///
/// ## 实测印证（本项目的真实数据）
/// 搜「斗罗大陆」返回 **8 个候选**（第二季 / 昊天扬威 / 铅华洗净…）；
/// 搜「我推的孩子」返回 **3 个**（第一/二/三季）。
/// ⇒ 自动匹配取第一个必然在多数情况下**选错季**，而用户毫无办法。
///
/// ## 交互设计（三步收敛）
/// 1. 预填**自动匹配用的关键词**（用户只需微调，不用从零输）
/// 2. 列出候选番剧（标题 + 类型 + 集数）
/// 3. 选中后列出该番剧的集 → 点某一集**立即生效**
///
/// ⚠️ 为什么不直接给"贴 episodeId"的输入框：
/// 普通用户不知道 episodeId 是什么，也拿不到。必须用**看得懂的名字**。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import 'danmaku_models.dart';
import 'danmaku_providers.dart';

/// 手动匹配结果：用户选中的 episodeId。
///
/// 用 `Navigator.pop(context, result)` 返回；取消时返回 null。
class DanmakuManualMatch {
  const DanmakuManualMatch({
    required this.episodeId,
    required this.animeTitle,
    this.episodeLabel = '',
  });

  final int episodeId;

  /// 用户选的番剧名（用于回显"你选的是这一部"）
  final String animeTitle;

  final String episodeLabel;

  /// 回显文案（播放页提示用）
  String get display =>
      episodeLabel.isEmpty ? animeTitle : '$animeTitle · $episodeLabel';
}

class DanmakuMatchSheet extends ConsumerStatefulWidget {
  const DanmakuMatchSheet({super.key, required this.initialKeyword});

  /// 预填关键词（= 自动匹配解析出的番剧名，用户只需微调）
  final String initialKeyword;

  @override
  ConsumerState<DanmakuMatchSheet> createState() => _DanmakuMatchSheetState();
}

class _DanmakuMatchSheetState extends ConsumerState<DanmakuMatchSheet> {
  late final TextEditingController _ctrl;
  List<DanmakuCandidate>? _candidates;
  bool _searching = false;
  String? _error;

  /// 当前展开的候选（点某部番剧后显示它的集）
  DanmakuCandidate? _opened;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialKeyword);
    // 首帧后自动搜一次 —— 用户多半直接选，不用再点"搜索"
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ctrl.text.trim().isNotEmpty) _search();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _opened = null;
    });
    try {
      final client = ref.read(danmakuClientProvider);
      if (client == null) {
        setState(() => _error = '弹幕源不可用（请先在设置里选择弹幕源）');
        return;
      }
      final list = await client.searchCandidates(kw);
      if (mounted) setState(() => _candidates = list);
    } catch (e) {
      if (mounted) setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 标题栏 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(children: [
                Expanded(
                  child: Text('手动匹配弹幕',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: Cf.text3,
                  tooltip: '关闭',
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('自动匹配不对时，自己选要匹配哪一部（译名不同/多季归档常见）',
                  style: Cf.micro),
            ),

            // ---- 搜索框 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    style: TextStyle(fontSize: 14, color: Cf.text),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '输入番剧名，如 我推的孩子',
                      hintStyle: TextStyle(fontSize: 13, color: Cf.text3),
                      filled: true,
                      fillColor: Cf.surface2,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Cf.radiusSm),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  style: FilledButton.styleFrom(
                    backgroundColor: Cf.accent,
                    foregroundColor: Cf.ink,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  child: Text(_searching ? '搜索中' : '搜索',
                      style: const TextStyle(fontSize: 13)),
                ),
              ]),
            ),

            // ---- 结果区 ----
            Flexible(child: _resultView()),
          ],
        ),
      ),
    );
  }

  Widget _resultView() {
    if (_error case final e?) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(e, style: TextStyle(fontSize: 13, color: Cf.danger)),
      );
    }
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final list = _candidates;
    if (list == null) return const SizedBox.shrink();
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('没搜到「${_ctrl.text.trim()}」。\n试试去掉季数后缀或用原名。',
            style: TextStyle(fontSize: 13, color: Cf.text3)),
      );
    }

    // 已展开某部 ⇒ 显示它的集列表
    if (_opened case final c?) {
      return _episodeList(c);
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final c = list[i];
        return ListTile(
          dense: true,
          title: Text(c.display,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Cf.text)),
          subtitle: Text('${c.episodes.length} 集',
              style: TextStyle(fontSize: 11, color: Cf.text3)),
          trailing: Icon(Icons.chevron_right_rounded,
              size: 18, color: Cf.text3),
          onTap: () => setState(() => _opened = c),
        );
      },
    );
  }

  Widget _episodeList(DanmakuCandidate c) {
    if (c.episodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('「${c.title}」没有可用的集',
            style: TextStyle(fontSize: 13, color: Cf.text3)),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // 返回候选列表
      InkWell(
        onTap: () => setState(() => _opened = null),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            Icon(Icons.arrow_back_rounded, size: 16, color: Cf.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text('重选番剧（当前：${c.title}）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Cf.accent)),
            ),
          ]),
        ),
      ),
      Flexible(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: c.episodes.length,
          itemBuilder: (context, i) {
            final e = c.episodes[i];
            return ListTile(
              dense: true,
              title: Text(e.display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Cf.text)),
              // 点某一集 ⇒ **立即生效**（不再要用户确认一次）
              onTap: () => Navigator.pop(
                context,
                DanmakuManualMatch(
                  episodeId: e.episodeId,
                  animeTitle: c.title,
                  episodeLabel: e.display,
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
