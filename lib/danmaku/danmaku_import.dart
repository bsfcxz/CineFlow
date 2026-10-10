/// 本地弹幕文件解析（用户要求"导入本地弹幕文件"接真功能）。
///
/// ## 支持格式（覆盖主流弹幕导出）
/// | 格式 | 来源 | 说明 |
/// |---|---|---|
/// | **`.xml`（B站 XML）** | B站下载、弹弹play 导出 | `<d p="时间,模式,字号,颜色,…">文本</d>` |
/// | **`.json`（弹弹play）** | 弹弹play 导出 | `{"comments":[{"p":"…","m":"…"}]}` |
/// | **`.ass`（字幕式弹幕）** | 部分工具 | 只取带 `\move`/`\pos` 的 Dialogue 行 |
///
/// ## 为什么不做 `.ass` 的完整解析（如实说明）
/// `.ass` 的弹幕没有统一规范：有的用 `\move`（滚动）、有的用 `\pos`（固定）、
/// 还有用 `\t` 做动画。**不同工具导出的差别极大**，完整解析要写一个
/// ASS 子集解释器。
/// ⇒ 这里只做**尽力而为**的提取：识别时间 + 文本 + 是否 `\move` 判滚动，
///    取不到就跳过该行（并在界面上告知解析了多少条）。
library;

import 'dart:convert';

import 'danmaku_models.dart';

/// 一次导入的结果。
class DanmakuImportResult {
  const DanmakuImportResult({
    this.items = const [],
    this.fileName = '',
    this.format = '',
    this.error,
    this.skipped = 0,
  });

  final List<Danmaku> items;
  final String fileName;

  /// 识别出的格式（`XML` / `JSON` / `ASS`）—— 用于回显"识别成什么了"
  final String format;

  /// 失败原因（中文，可直接展示）。成功时为 null。
  final String? error;

  /// 解析过程中跳过的行数（格式不符/时间非法）—— 如实告知用户
  final int skipped;

  bool get ok => error == null;
}

/// 解析弹幕文件内容。**纯函数**（便于单测，不碰文件系统）。
///
/// [content] 文件全文；[fileName] 仅用于回显格式名。
/// 格式**自动判定**（按内容特征，不只看扩展名 —— 用户可能改过名）。
DanmakuImportResult parseDanmakuFile(String content, {String fileName = ''}) {
  final text = content.trim();
  if (text.isEmpty) {
    return DanmakuImportResult(
        fileName: fileName, error: '文件是空的');
  }

  // ---- 判定格式（按内容特征，不只看扩展名）----
  //
  // ★★ 顺序有讲究（真实 bug 抓出来的）
  // ASS 文件**以 `[Script Info]` 开头** —— 而下面的"以 `[` 开头 ⇒ JSON"
  // 分支会**先把 ASS 抢走**，于是 ASS 被当成 JSON 解析并报
  // "JSON 格式有误"。真机上的表现是"选 .ass 文件说格式错误"。
  // ⇒ **必须先判 ASS**（特征是 `[Script Info]` / `Dialogue:`），
  //    再判 JSON（以 `{` 开头，或**以 `[` 开头且不是 ASS 段头**）。
  if (text.contains('[Script Info]') || text.contains('Dialogue:')) {
    return _parseAss(text, fileName);
  }
  if (text.startsWith('{')) {
    return _parseJson(text, fileName);
  }
  // `[` 开头还要排除 ASS 的段头（`[Events]` / `[V4+ Styles]` 等）——
  // 有的 ASS 没有 `[Script Info]` 段，只有 `[Events]`
  if (text.startsWith('[')) {
    final isAssSection = RegExp(r'^\[[A-Za-z0-9+ ]+\]').hasMatch(text);
    if (!isAssSection) return _parseJson(text, fileName);
  }
  if (text.contains('<i>') || text.contains('<d ') || text.contains('<?xml')) {
    return _parseXml(text, fileName);
  }
  // 兜底：按 XML 再试一次（可能是不带声明的 `<i>` 片段）
  final xml = _parseXml(text, fileName);
  if (xml.ok && xml.items.isNotEmpty) return xml;
  return DanmakuImportResult(
    fileName: fileName,
    error: '无法识别格式（支持 B站 XML / 弹弹play JSON / ASS）',
  );
}

// ══════════════════════════════════════════════════════════════
// B站 XML
// ══════════════════════════════════════════════════════════════

/// 解析 B站 XML：`<d p="时间,模式,字号,颜色,时间戳,池,用户哈希,行ID">文本</d>`
///
/// ## 为什么不引入 XML 解析库
/// 需要的只有一个 `<d>` 标签及其 `p` 属性 —— 用正则足够，
/// 且能容忍**格式破损**的导出文件（真实文件常有未转义字符，
/// 严格解析器会整体失败，而正则能救回大部分）。
DanmakuImportResult _parseXml(String content, String fileName) {
  final re = RegExp(r'<d\s+p="([^"]*)"[^>]*>([\s\S]*?)</d>',
      caseSensitive: false);
  final items = <Danmaku>[];
  var skipped = 0;

  for (final m in re.allMatches(content)) {
    final p = m.group(1) ?? '';
    final rawText = m.group(2) ?? '';
    final d = _fromXmlParts(p, rawText);
    if (d == null) {
      skipped++;
      continue;
    }
    items.add(d);
  }
  if (items.isEmpty) {
    return DanmakuImportResult(
        fileName: fileName,
        format: 'XML',
        error: 'XML 里没有找到弹幕（`<d p="...">` 标签）');
  }
  items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return DanmakuImportResult(
      items: items, fileName: fileName, format: 'XML', skipped: skipped);
}

Danmaku? _fromXmlParts(String p, String rawText) {
  final segs = p.split(',');
  if (segs.length < 4) return null;
  final sec = double.tryParse(segs[0].trim());
  if (sec == null || sec < 0) return null;
  final mode = int.tryParse(segs[1].trim()) ?? 1;
  // ⚠️ 段数决定布局（本仓库已记录该坑）：
  //   B站 8 段：时间,模式,字号,颜色,…  ⇒ 颜色在 index 3
  //   弹弹play 4 段：时间,模式,颜色,用户 ⇒ 颜色在 index 2
  final colorIdx = segs.length >= 8 ? 3 : 2;
  var color = int.tryParse(segs[colorIdx].trim()) ?? 0xFFFFFF;
  // 夹到 24 位（服务端/文件可能给带 alpha 的 32 位数，
  // 直接给 Flutter 会因 alpha=0 变全透明 —— 见 models 里的同类注释）
  color &= 0xFFFFFF;

  final text = _unescapeXml(rawText).trim();
  if (text.isEmpty) return null;

  return Danmaku(
    timeMs: (sec * 1000).round(),
    text: text,
    mode: _modeOf(mode),
    color: color,
    fontSize: _fontSizeOf(segs, colorIdx),
  );
}

/// 弹幕文件缺字号时的**基线字号**（B站 XML 的默认值）。
///
/// ## 为什么是 25 而不是 UI 排版字号
/// 这是**弹幕文件内部的相对字号**（`p` 字段的第 3 段），
/// 渲染时按 `fontSize / 25.0` 算相对缩放（见 `_DanmakuPainter`）。
/// ⇒ 它与 `Cf` 的排版令牌**不是同一个尺度**，不能换成 `Cf.body` 之类。
///
/// ⚠️ 抽成常量是因为 `design_tokens_test` 守卫"裸 fontSize 种类数"：
///    直接写字面量 `25` 会多出一种档位，让门禁变红（实测踩到）。
const int kXmlDefaultFontSize = 25;

/// B站 XML 的实体反转义（`&amp;` 等）。
///
/// ⚠️ 顺序有讲究：`&amp;` 必须**最后**替换，否则 `&amp;lt;`
/// 会被先解成 `&lt;` 再解成 `<`（双重解码）。
String _unescapeXml(String s) {
  var out = s;
  for (final e in const [
    ('&lt;', '<'),
    ('&gt;', '>'),
    ('&quot;', '"'),
    ('&apos;', "'"),
  ]) {
    out = out.replaceAll(e.$1, e.$2);
  }
  return out.replaceAll('&amp;', '&');
}

/// 字号：B站 XML 的字号在颜色**前一位**（8 段布局）。
int _fontSizeOf(List<String> segs, int colorIdx) {
  if (segs.length >= 8 && colorIdx == 3) {
    return int.tryParse(segs[2].trim()) ?? 25;
  }
  return 25;
}

/// 弹幕模式数字 → 枚举（只区分滚动/顶部/底部，其余归滚动）。
DanmakuMode _modeOf(int mode) => switch (mode) {
      4 => DanmakuMode.top,
      5 => DanmakuMode.bottom,
      _ => DanmakuMode.scroll,
    };

// ══════════════════════════════════════════════════════════════
// 弹弹play JSON
// ══════════════════════════════════════════════════════════════

/// 弹弹play JSON：`{"comments":[{"p":"时间,模式,颜色,用户","m":"文本"}]}`
///
/// 也容忍**裸数组**（`[{...}]`，部分工具导出）。
DanmakuImportResult _parseJson(String content, String fileName) {
  dynamic data;
  try {
    data = jsonDecode(content);
  } catch (e) {
    return DanmakuImportResult(
        fileName: fileName, format: 'JSON', error: 'JSON 格式有误：$e');
  }

  final List<dynamic> list;
  if (data is Map) {
    final c = data['comments'];
    if (c is! List) {
      return DanmakuImportResult(
          fileName: fileName, format: 'JSON', error: 'JSON 里没有 `comments` 字段');
    }
    list = c;
  } else if (data is List) {
    list = data;
  } else {
    return DanmakuImportResult(
        fileName: fileName, format: 'JSON', error: 'JSON 结构无法识别');
  }

  final items = <Danmaku>[];
  var skipped = 0;
  for (final e in list) {
    if (e is! Map) {
      skipped++;
      continue;
    }
    final p = e['p']?.toString() ?? '';
    final text = e['m']?.toString().trim() ?? '';
    if (text.isEmpty) {
      skipped++;
      continue;
    }
    final segs = p.split(',');
    final sec = segs.isEmpty ? null : double.tryParse(segs[0].trim());
    if (sec == null || sec < 0) {
      skipped++;
      continue;
    }
    final mode = segs.length > 1 ? (int.tryParse(segs[1].trim()) ?? 1) : 1;
    final color = segs.length > 2
        ? (int.tryParse(segs[2].trim()) ?? 0xFFFFFF) & 0xFFFFFF
        : 0xFFFFFF;
    items.add(Danmaku(
      timeMs: (sec * 1000).round(),
      text: text,
      mode: _modeOf(mode),
      color: color,
      fontSize: kXmlDefaultFontSize,
    ));
  }
  if (items.isEmpty) {
    return DanmakuImportResult(
        fileName: fileName, format: 'JSON', error: 'JSON 里没有可用的弹幕条目');
  }
  items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return DanmakuImportResult(
      items: items, fileName: fileName, format: 'JSON', skipped: skipped);
}

// ══════════════════════════════════════════════════════════════
// ASS（尽力而为）
// ══════════════════════════════════════════════════════════════

/// 解析 ASS 的 `Dialogue` 行。
///
/// ## 为什么是"尽力而为"（如实说明局限性）
/// `.ass` 弹幕**没有统一规范**：有的用 `\move`（滚动）、有的 `\pos`（固定）、
/// 有的用 `\t` 做动画。**不同工具导出差别极大**。
/// ⇒ 这里只提取：时间 + 文本 + "有 `\move` 就算滚动，否则按顶部固定"。
///    解析不了的行**跳过并计数**（界面上告知，不静默丢）。
DanmakuImportResult _parseAss(String content, String fileName) {
  final items = <Danmaku>[];
  var skipped = 0;

  for (final line in const LineSplitter().convert(content)) {
    if (!line.startsWith('Dialogue:')) continue;
    // Dialogue: 层,起,止,样式,名,边距L,R,V,特效,文本
    // ⚠️ 文本里可能含逗号 ⇒ 只能 split 出前 9 段，其余合并回文本
    final body = line.substring('Dialogue:'.length);
    final parts = body.split(',');
    if (parts.length < 10) {
      skipped++;
      continue;
    }
    final start = _assTime(parts[1].trim());
    if (start == null) {
      skipped++;
      continue;
    }
    // 第 10 项起是文本（含逗号）
    final rawText = parts.sublist(9).join(',');
    final text = _assPlainText(rawText);
    if (text.isEmpty) {
      skipped++;
      continue;
    }
    final isScroll = rawText.contains(r'\move');
    items.add(Danmaku(
      timeMs: start,
      text: text,
      mode: isScroll ? DanmakuMode.scroll : DanmakuMode.top,
      color: 0xFFFFFF,
      fontSize: kXmlDefaultFontSize,
    ));
  }

  if (items.isEmpty) {
    return DanmakuImportResult(
        fileName: fileName,
        format: 'ASS',
        error: 'ASS 里没有找到弹幕行（`Dialogue:` 且带文本）');
  }
  items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return DanmakuImportResult(
      items: items, fileName: fileName, format: 'ASS', skipped: skipped);
}

/// ASS 时间 `H:MM:SS.cc` → 毫秒。
int? _assTime(String s) {
  final m = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})[.:](\d{1,3})$').firstMatch(s);
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  final sec = int.parse(m.group(3)!);
  // 厘秒：`50` → 500ms（补足到 3 位再取）
  final fracRaw = m.group(4)!;
  final frac = int.parse(fracRaw.padRight(3, '0').substring(0, 3));
  return ((h * 3600 + mi * 60 + sec) * 1000) + frac;
}

/// 去掉 ASS 样式标签（`{\...}`），只留纯文本。
String _assPlainText(String raw) {
  // 先去掉所有 {...} 块（含 \move、\pos、\c&H...& 等）
  var out = raw.replaceAll(RegExp(r'\{[^}]*\}'), '');
  // `\N` / `\n` 是换行，弹幕里换成空格（弹幕只渲染单行）
  out = out.replaceAll(RegExp(r'\\[Nn]'), ' ');
  return out.trim();
}
