# -*- coding: utf-8 -*-
"""批次 B：详情页 收藏/看过 toggle + HD Tag + 状态同步"""
import io

p = 'lib/pages/detail_page.dart'
s = io.open(p, encoding='utf-8').read()

# 1) imports: services (Clipboard)
s = s.replace(
    """import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';""",
    """import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';""")

# 2) 状态字段
s = s.replace(
    """class _DetailPageState extends ConsumerState<DetailPage> {
  String? _selectedSeasonId;
  String? _selectedVersionId;""",
    """class _DetailPageState extends ConsumerState<DetailPage> {
  String? _selectedSeasonId;
  String? _selectedVersionId;
  String? _syncedItemId;
  bool _fav = false;
  bool _watched = false;
  bool _toggling = false;""")

# 3) _buildBody：状态同步 + HD tags
old_head = """  Widget _buildBody(EmbyItemDetail d) {
    final api = ref.watch(embyApiProvider)!;
    final item = d.item;
    final isSeries = item.type == 'Series';
    final tags = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.communityRating != null)
        '⭐ ${item.communityRating!.toStringAsFixed(1)}',
      if (item.officialRating != null && item.officialRating!.isNotEmpty)
        item.officialRating!,
      ...item.genres.take(2),
    ];"""
new_head = """  Widget _buildBody(EmbyItemDetail d) {
    final api = ref.watch(embyApiProvider)!;
    final item = d.item;
    final isSeries = item.type == 'Series';
    // 按钮状态随条目同步
    if (_syncedItemId != item.id) {
      _syncedItemId = item.id;
      _fav = item.isFavorite;
      _watched = item.played;
    }
    final tags = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.communityRating != null)
        '⭐ ${item.communityRating!.toStringAsFixed(1)}',
      if (item.officialRating != null && item.officialRating!.isNotEmpty)
        item.officialRating!,
      ...item.genres.take(2),
      // HD 元信息 Tag（从真实媒体流生成，对齐原型 dmeta-tag.hd）
      ..._hdTags(d),
    ];"""
assert old_head in s, 'head not found'
s = s.replace(old_head, new_head)

# 4) _actionButtons 改造
old_btns = """      const SizedBox(width: 9),
      ...[
        Icons.favorite_border_rounded,
        Icons.download_outlined,
        Icons.cast_rounded,
      ].map((icon) => Padding(
            padding: const EdgeInsets.only(left: 9),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x14FFFFFF),
                border: Border.all(color: const Color(0x26FFFFFF)),
              ),
              child: Icon(icon, size: 17, color: Cf.text),
            ),
          )),
    ]);
  }"""
new_btns = """      const SizedBox(width: 9),
      // 收藏（真实 toggle）
      _roundBtn(
        icon: _fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: _fav ? Cf.danger : Cf.text,
        onTap: _toggling
            ? null
            : () async {
                final next = !_fav;
                setState(() {
                  _toggling = true;
                  _fav = next;
                });
                try {
                  final api = ref.read(embyApiProvider)!;
                  final result = await api.toggleFavorite(item.id, favorite: next);
                  if (result != next) setState(() => _fav = !next);
                } catch (_) {
                  setState(() => _fav = !_fav);
                  if (mounted) showComingSoon(context, '收藏失败，请稍后重试');
                } finally {
                  if (mounted) setState(() => _toggling = false);
                }
              },
      ),
      const SizedBox(width: 9),
      // 看过（真实 toggle）
      _roundBtn(
        icon: _watched ? Icons.visibility_rounded : Icons.visibility_outlined,
        color: _watched ? Cf.warn : Cf.text,
        onTap: _toggling
            ? null
            : () async {
                final next = !_watched;
                setState(() {
                  _toggling = true;
                  _watched = next;
                });
                try {
                  final api = ref.read(embyApiProvider)!;
                  final result = await api.togglePlayed(item.id, played: next);
                  if (result != next) setState(() => _watched = !next);
                } catch (_) {
                  setState(() => _watched = !_watched);
                  if (mounted) showComingSoon(context, '标记失败，请稍后重试');
                } finally {
                  if (mounted) setState(() => _toggling = false);
                }
              },
      ),
      const SizedBox(width: 9),
      _roundBtn(
        icon: Icons.download_outlined,
        onTap: () => showComingSoon(context, '下载'),
      ),
    ]);
  }

  /// HD 元信息 Tag：从第一路媒体流生成（4K / HDR / 杜比）
  List<String> _hdTags(EmbyItemDetail d) {
    if (d.mediaSources.isEmpty) return const [];
    final video = d.mediaSources.first.streams
        .where((s) => s.type == 'Video')
        .toList();
    final audio = d.mediaSources.first.streams
        .where((s) => s.type == 'Audio')
        .toList();
    final out = <String>[];
    if (video.isNotEmpty) {
      final v = video.first;
      if ((v.width ?? 0) >= 3800 || (v.height ?? 0) >= 2100) out.add('4K');
      final range = (v.videoRange ?? '').toUpperCase();
      if (range.contains('DOVI')) {
        out.add('杜比视界');
      } else if (range.contains('HDR')) {
        out.add('HDR');
      }
    }
    if (audio.isNotEmpty) {
      final t = (audio.first.displayTitle ?? '') + (audio.first.codec ?? '');
      if (t.toUpperCase().contains('ATMOS') || t.contains('全景声')) {
        out.add('杜比全景声');
      }
    }
    return out;
  }

  Widget _roundBtn(
      {required IconData icon,
      required VoidCallback? onTap,
      Color color = Cf.text}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x14FFFFFF),
          border: Border.all(
              color: onTap == null ? Cf.border : const Color(0x26FFFFFF)),
        ),
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }"""
assert old_btns in s, 'btns not found'
s = s.replace(old_btns, new_btns)

# 5) SliverAppBar 右上：投屏（toast）/ 分享（复制链接）
old_bar = """        SliverAppBar(
          pinned: true,
          expandedHeight: 260,
          backgroundColor: Cf.bg,
          iconTheme: const IconThemeData(color: Colors.white),"""
new_bar = """        SliverAppBar(
          pinned: true,
          expandedHeight: 260,
          backgroundColor: Cf.bg,
          iconTheme: const IconThemeData(color: Colors.white),
          actions: [
            IconButton(
              onPressed: () => showComingSoon(context, '投屏'),
              icon: const Icon(Icons.cast_rounded, size: 20),
            ),
            IconButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(
                    text:
                        'https://movie.douban.com/  \u00b7 \u300a${item.displayTitle}\u300b'));
                showComingSoon(context, '分享');
              },
              icon: const Icon(Icons.ios_share_rounded, size: 19),
            ),
            const SizedBox(width: 6),
          ],"""
assert old_bar in s, 'appbar not found'
s = s.replace(old_bar, new_bar)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('detail B patched OK')
