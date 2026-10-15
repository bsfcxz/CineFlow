/// **分类浏览**（稿子 180b4d 的分类面板）。
///
/// ## 结构
/// ```
/// 分类浏览                            ← 标题
/// [剧集][电影][动漫][综艺][纪录片][儿童]   ← 类别 chips（横滑）
/// [全部][国产][港台][日韩][欧美]         ← 地区 chips（随类别变）
/// ──────────────
/// 网格（2 列海报 + 标题 + 评分 + 热度）
/// ```
///
/// ## 数据来源
/// `CalendarClient.fetchBrowse`（TMDB `discover` + `with_genres`
/// + `with_origin_country`）。实测 **24/24 组合全部有数据**。
///
/// ## 为什么地区列表**随类别变**
/// 稿子里就是这么定义的（`CATEGORIES[i].regions`）：
/// · 剧集/电影：全部/国产/港台/日韩/欧美
/// · 动漫：全部/**国漫**/**日番**/欧美（动漫不用"国产/日韩"这种叫法）
/// · 综艺/纪录片/儿童：全部/国产/欧美
/// 这符合直觉 —— 动漫圈说"国漫/日番"，影视圈说"国产/日韩"。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/calendar_client.dart';
import '../state/providers.dart';
import '../widgets/calendar_detail_sheet.dart';

class BrowsePage extends ConsumerStatefulWidget {
  const BrowsePage({super.key, this.initial});

  /// 打开时预选的类别（首页点哪个格子就进哪个类别）。
  ///
  /// ## 为什么要这个参数
  /// 首页有 6 个分类格子，用户点「动漫」期望**直接看到动漫** ——
  /// 进来还要再点一次「动漫」是多余的一步。
  final BrowseCategory? initial;

  @override
  ConsumerState<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends ConsumerState<BrowsePage> {
  late BrowseCategory _cat = widget.initial ?? BrowseCategory.series;
  BrowseRegion _region = BrowseRegion.all;

  /// 缓存已拉到的结果（`类别:地区` → 条目），避免重复请求。
  ///
  /// ## 为什么在 State 里缓存
  /// 用户会在"类别/地区"之间来回切（对比着看）。
  /// 每次切都发请求既慢又浪费 TMDB 配额。
  final _cache = <String, List<CalendarEntry>>{};
  bool _loading = false;

  /// 请求序号：只采纳**最新**那次请求的结果。
  ///
  /// ## 为什么需要（真机截图暴露的真实竞态）
  /// 用户在请求飞行中快速切类别时，先后两个请求**返回顺序不确定**：
  /// 若先发的后返回，它会把**旧类别的数据写进新类别的缓存键**
  /// ⇒ 缓存被污染且**不会自愈**（切回来看到的还是错的数据）。
  int _reqId = 0;

  /// 加载失败的原因（null = 没失败）。
  ///
  /// ## 为什么必须有
  /// 真机实测：切类别后 spinner **无限转**（TMDB 此刻不稳定）。
  /// 原来 `_load` 把空结果也当成功 ⇒ 用户看到空网格，或请求挂住时
  /// **永远看不到任何说明**。加载失败要说清是**失败**（AGENTS §7.8：
  /// 不许把失败伪装成空）。
  String? _error;

  String get _key => '${_cat.name}:${_region.label}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    // ★ ① 在**发起前**固定 key 与参数
    //    （`_key` 是 getter，`await` 之后再读会拿到**新**类别的值 ⇒ 写错缓存键）
    final tag = _key;
    final cat = _cat;
    final region = _region;
    if (_cache.containsKey(tag)) return;

    // ★ ② 领请求号：只有最新那次的结果才被采纳
    final myReq = ++_reqId;

    // ══════════════════════════════════════════════════════════════
    // ★★ ③ try/catch/finally（2026-10-15 修的真 bug）
    // ══════════════════════════════════════════════════════════════
    //
    // ## 用户报障
    // > "首页中 6 个类别中点开其实**就在一块**。没有细分类别"
    //
    // 真机实测（截图 + logcat）：
    // ```
    // [分类浏览页] 类别 chips ✓ / 地区 chips ✓ / 网格区 **无限转圈**
    // 13:45:29  [Calendar] 分类浏览异常: 超时     ← 12 秒后
    // ```
    // ## 根因（本方法原来 try=0 / catch=0）
    // `fetchBrowse` 抛异常（TMDB 超时）⇒ **异常冒泡出去**
    // ⇒ 末尾那句 `setState(() { _loading = false; })` **永不执行**
    // ⇒ `_loading` 永远是 `true`
    // ⇒ `_body` 卡在 `if (items == null) return CircularProgressIndicator();`
    // ⇒ **无限转圈，且错误分支与重试按钮永远摸不到**。
    //
    // ⚠️ 那个"错误态 + 重试"（`_body` 的 `_error` 分支）**写得没问题**，
    //    但**没有任何代码路径能给它赋值**（除"未填 Key"一种）
    //    ⇒ 典型的"写了错误处理，但异常根本走不到那里"。
    //
    // ## 修法
    // 包 try/catch/finally ⇒ 无论成功/失败/超时，**一定**复位 `_loading`
    // 并把原因写进 `_error`（AGENTS §7.8：不许把失败伪装成空）。
    try {
      final tmdbKey = await ref.read(sessionStoreProvider).loadTmdbKey();
      if (!mounted || myReq != _reqId) return;
      if (tmdbKey == null || tmdbKey.isEmpty) {
        setState(() {
          _loading = false;
          _error = '未填 TMDB API Key（在「追剧日历」右上角填写）';
        });
        return;
      }
      setState(() {
        _loading = true;
        _error = null;
      });

      final list = await ref.read(calendarClientProvider).fetchBrowse(
            apiKey: tmdbKey,
            category: cat,
            region: region,
          );

      // ★ ④ 过期响应直接丢弃（不写缓存、不动 _loading）——
      //    否则会把旧类别的数据写进新类别的键
      if (!mounted || myReq != _reqId) return;
      setState(() {
        _cache[tag] = list; // 用发起时固定的 tag，不是 `_key`
        _loading = false;
        // 空结果 + 网络没报错 ⇒ 可能是"真没有"也可能是"请求失败被吞"
        // ⇒ 不写 _error（下面空态会给出可行动提示）
      });
    } catch (e) {
      // ⚠️ 这里**必须**复位 `_loading` —— 否则就是用户看到的"无限转圈"
      if (!mounted || myReq != _reqId) return;
      setState(() {
        _loading = false;
        // 把底层原因带上（`_friendly` 已把超时/断网转成中文）
        _error = '加载失败：$e\n'
            '（分类浏览用的是 TMDB 接口；若网络访问不了 TMDB，'
            '可在「追剧日历」里换用其它数据源，或稍后重试）';
      });
      debugPrint('[Browse] 加载失败（已复位 loading）: $e');
    } finally {
      // 双保险：万一上面某条路径漏了复位（例如未来改代码时新加 return）
      if (mounted && myReq == _reqId && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  void _pick(BrowseCategory c) {
    setState(() {
      _cat = c;
      // ⚠️ 换类别时**必须重置地区** —— 否则会出现"动漫 + 港台"
      //    这种该类别不支持的区域（`regions` 里没有它）⇒ 请求参数错
      _region = BrowseRegion.all;
      _error = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _cache[_key];
    return Scaffold(
      backgroundColor: Cf.bg,
      appBar: AppBar(
        title: const Text('分类浏览'),
        backgroundColor: Cf.bg,
      ),
      body: Column(children: [
        // ── 类别 chips ──
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Cf.gap4),
            itemCount: BrowseCategory.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: Cf.gap2),
            itemBuilder: (_, i) {
              final c = BrowseCategory.values[i];
              return _Chip(
                label: c.label,
                active: c == _cat,
                onTap: () => _pick(c),
              );
            },
          ),
        ),
        const SizedBox(height: 2),
        // ── 地区 chips（随类别变）──
        SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Cf.gap4),
            itemCount: _cat.regions.length,
            separatorBuilder: (_, _) => const SizedBox(width: Cf.gap2),
            itemBuilder: (_, i) {
              final r = BrowseRegion.byLabel(_cat.regions[i]);
              return _Chip(
                label: r.label,
                active: r.label == _region.label,
                small: true,
                onTap: () {
                  setState(() {
                    _region = r;
                    _error = null;
                  });
                  _load();
                },
              );
            },
          ),
        ),
        const SizedBox(height: Cf.gap2),
        const Divider(height: 1),
        Expanded(child: _body(items)),
      ]),
    );
  }

  Widget _body(List<CalendarEntry>? items) {
    // ══════════════════════════════════════════════════════════════
    // ★★ 判定顺序**必须**是：错误 → 加载中 → 空 → 网格
    // ══════════════════════════════════════════════════════════════
    //
    // ## 原来的顺序错在哪（2026-10-15 修）
    // ```dart
    // if (_loading && ...) return spinner;      // ①
    // if (items == null) return spinner;        // ② ★ 挡住了一切
    // if (_error case final msg?) { ...错误+重试... }   // ③ **永远摸不到**
    // ```
    // `items` 只在**成功**时才写进 `_cache` ⇒ 失败时它恒为 `null`
    // ⇒ ② 把 ③ 完全挡住 ⇒ **错误提示与重试按钮形同虚设**。
    // 这正是用户看到的："点开就是一片空白（转圈），没有任何说明"。
    //
    // ## 正确顺序的理由
    // · 错误是**确定状态**（有原因可展示）⇒ 优先级最高
    // · 加载中次之（此时还没有结论）
    // · 最后才是"内容为空"
    if (_error case final msg?) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.error_outline_rounded, size: Cf.iconXl, color: Cf.danger),
          const SizedBox(height: Cf.gap2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Cf.gap6),
            child: Text(msg,
                textAlign: TextAlign.center,
                style: Cf.caption.copyWith(color: Cf.text2)),
          ),
          const SizedBox(height: Cf.gap3),
          TextButton(
            // ⚠️ 重试前必须**清掉 `_error`**，否则 `_body` 会一直停在错误态
            //    （`_load` 里只在"参数就绪后"才清它 —— 若失败发生在更早
            //      的步骤，重试会立刻又被同一条件挡住）
            onPressed: () {
              setState(() => _error = null);
              _load();
            },
            child: const Text('重试'),
          ),
        ]),
      );
    }
    if (_loading && (items == null || items.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.search_off_rounded, size: Cf.iconXl, color: Cf.text3),
          const SizedBox(height: Cf.gap2),
          Text('这个分类下没有内容', style: Cf.caption.copyWith(color: Cf.text3)),
          const SizedBox(height: Cf.gap3),
          // ⚠️ 空有两种原因：TMDB 没有这个组合、或请求失败被吞。
          //    给用户一个**可行动**的出口（重试），而不是干看着。
          TextButton(
            onPressed: () {
              setState(() => _error = null);
              _load();
            },
            child: const Text('重新加载'),
          ),
        ]),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(Cf.gap4),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: Cf.gap3,
        crossAxisSpacing: Cf.gap3,
        // 海报 2:3 + 下方两行文字
        childAspectRatio: 0.62,
      ),
      itemBuilder: (_, i) => _Card(entry: items[i]),
    );
  }
}

/// chips（类别/地区共用；地区用小一号）。
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.active,
    required this.onTap,
    this.small = false,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: small ? 12 : 16),
        decoration: BoxDecoration(
          // Active 用粉紫渐变（用户配色规格：主色→副色）
          gradient: active
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Cf.accent, Cf.accent3])
              : null,
          color: active ? null : Cf.surface,
          border: Border.all(color: active ? Colors.transparent : Cf.border),
          borderRadius: BorderRadius.circular(Cf.radiusMd),
        ),
        child: Text(
          label,
          style: (small ? Cf.micro : Cf.label).copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? Cf.ink : Cf.text2,
          ),
        ),
      ),
    );
  }
}

/// 网格卡片（海报 + 标题 + 评分/热度）。
///
/// ## 点卡片做什么
/// 打开**日历详情的弹层**（`showCalendarDetail`）——
/// 它已经实现了简介/导演/主演/平台/跳转，复用即可。
/// ⚠️ 不能点进 Emby 详情页：这些条目来自 TMDB，
///    **可能不在用户库里**（点进去会是"找不到"）。
class _Card extends StatelessWidget {
  const _Card({required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context) {
    final poster = entry.posterUrl;
    return GestureDetector(
      onTap: () => showCalendarDetail(context, entry),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Cf.radiusMd),
              child: SizedBox(
                width: double.infinity,
                child: poster == null || poster.isEmpty
                    ? _fallback()
                    : Image.network(
                        poster,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _fallback(),
                        loadingBuilder: (c, ch, p) =>
                            p == null ? ch : _fallback(),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(entry.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Cf.caption.copyWith(color: Cf.text)),
          const SizedBox(height: 2),
          Row(children: [
            if (entry.rating case final r? when r > 0) ...[
              const Icon(Icons.star_rounded,
                  size: 12, color: Color(0xFFF5C518)),
              const SizedBox(width: 2),
              Text(r.toStringAsFixed(1),
                  style: Cf.micro.copyWith(fontSize: 10)),
            ],
            // 年份：取 airDate 的**前 4 位**（实测形如 "2026-10-08"）。
            // ⚠️ 不用 productionYearText —— CalendarEntry **没有**这个字段
            //    （我第一版臆造了它，编译器直接报错）。日历条目只有 irDate。
            if (_yearOf(entry.airDate) case final y?) ...[
              const SizedBox(width: 6),
              Text(y, style: Cf.micro.copyWith(fontSize: 10)),
            ],
          ]),
        ],
      ),
    );
  }

  /// 从 irDate 提取年份（前 4 位）。
  ///
  /// ## 为什么不用 DateTime.parse
  /// irDate 实测形如 2026-10-08，也可能只有 2026（TMDB 偶发）。
  /// 直接取前 4 位对两种形态都成立，且**不需要处理解析失败**。
  static String? _yearOf(String? d) {
    if (d == null || d.length < 4) return null;
    final y = d.substring(0, 4);
    return int.tryParse(y) == null ? null : y;
  }

  Widget _fallback() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, color: Cf.text3),
      );
}
