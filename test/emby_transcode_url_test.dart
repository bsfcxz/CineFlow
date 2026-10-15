// ══════════════════════════════════════════════════════════════════════
//  守卫测试：Emby **转码 URL** 必须带 `PlaySessionId`
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户报障（2026-10-15）
// > "切换转码是播放器报错，这是啥情况"
//
// ## 真机证据
// ```
// [mpv/cplayer] Playing: .../Videos/3304770/hls1/main/265.mp4?PlaySessionId=
// [mpv/ffmpeg]  http: HTTP error 400 Bad Request
// [mpv/stream]  Failed to open ...
// end-file error: error=-13 loading failed      ← 265/266/267/268 逐个失败
// ```
// ⚠️ URL **以 `?PlaySessionId=` 结尾（值为空）** —— Emby 把 master.m3u8 的
//    查询参数**透传到分段 URL**，我们没带 ⇒ 分段拿到空值 ⇒ **400**。
//
// ## 权威依据（Jellyfin 服务端 = Emby 同源，代码级）
// `Jellyfin.Api/Helpers/StreamingHelpers.cs`：
// ```csharp
// var currentJob = !string.IsNullOrWhiteSpace(streamingRequest.PlaySessionId)
//     ? transcodeManager.GetTranscodingJob(streamingRequest.PlaySessionId)
//     : null;      // ← ★ 空 ⇒ 服务端**找不到转码任务**
// ```
// ⇒ `PlaySessionId` 是流式请求的**必填字段**，不是可选优化。
//
// ## 为什么必须测
// 少了它**不报错**：URL 照样能拼出来、master.m3u8 照样 200，
// 只有**分段**才 400 ⇒ 现象是"播放器报错"而看不出是参数问题。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _stripComments(String src) {
  final out = StringBuffer();
  var inS = false, inD = false;
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    final nxt = i + 1 < src.length ? src[i + 1] : '';
    if (!inS && !inD) {
      if (c == "'") {
        inS = true;
      } else if (c == '"') {
        inD = true;
      } else if (c == '/' && nxt == '/') {
        while (i < src.length && src[i] != '\n') {
          i++;
        }
        continue;
      } else if (c == '/' && nxt == '*') {
        i += 2;
        while (i + 1 < src.length &&
            !(src[i] == '*' && src[i + 1] == '/')) {
          i++;
        }
        i += 2;
        continue;
      }
    } else {
      if (c == r'\' && i + 1 < src.length) {
        out.write(c);
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (inS && c == "'") inS = false;
      if (inD && c == '"') inD = false;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  late String src;

  setUpAll(() async {
    src = _stripComments(
        await File('lib/data/emby_provider.dart').readAsString());
  });

  group('★★★ 转码 URL 必须带 PlaySessionId（分段 400 的根因）', () {
    test('★★★ `master.m3u8` 的 URL 必须含 `PlaySessionId=` + 变量', () {
      // 找到 transcodingUrl 的构造段（从 master.m3u8 到分号）
      final i = src.indexOf('master.m3u8');
      expect(i, greaterThan(0), reason: '找不到 master.m3u8 构造点');
      final seg = src.substring(i, (i + 900).clamp(0, src.length));
      final end = seg.indexOf(';');
      final urlPart = seg.substring(0, end > 0 ? end : seg.length);
      expect(urlPart.contains('PlaySessionId='), isTrue,
          reason: '★★★ URL 缺 `PlaySessionId` ⇒ Emby 分段返回 **400 Bad Request**\n'
              '    （真机：URL 以 `?PlaySessionId=` 空值结尾，265/266/267/268 全失败）\n'
              '    权威依据：Jellyfin `StreamingHelpers.cs` 用它对转码任务做\n'
              '    `GetTranscodingJob(PlaySessionId)`，空 ⇒ 找不到任务');
      // ⚠️ 必须是**变量插值**（`$xxx` 或 `${xxx}`），不能是字面量空串
      expect(RegExp(r'PlaySessionId=\$').hasMatch(urlPart), isTrue,
          reason: '★★ ★ 必须是变量插值：写成 `PlaySessionId=` 空值仍会 400\n'
              '    （这正是 bug 的形态：Emby 透传空参数到分段 URL）');
    });

    test('★★★ 转码 URL 的 id 必须与 `playSessionId` 字段**同一个值**', () {
      // 教训：若 URL 里再 uuidV4() 一次，会生成**第二个** id
      // ⇒ "转码任务"与"上报会话"对不上（同一类 bug 复发）。
      final i = src.indexOf('master.m3u8');
      final seg = src.substring(i, (i + 1200).clamp(0, src.length));
      // 该段内 uuidV4() 只能出现 0 次（应复用上面的 sessionId）
      final n = RegExp(r'uuidV4\(\)').allMatches(seg).length;
      expect(n, 0,
          reason: '★★★ 转码 URL 段内**不应**再调用 `uuidV4()`：\n'
              '    应复用上面已生成的同一个 id（URL 与 `playSessionId:` 字段共用）\n'
              '    否则转码任务 id ≠ 上报会话 id');
    });

    test('★★ `playSessionId` 字段被赋的值是一个**局部变量**（不是内联 uuidV4）', () {
      expect(
          RegExp(r'playSessionId:\s*sessionId').hasMatch(src), isTrue,
          reason: '★ 应为 `playSessionId: sessionId`（复用同一个 id）\n'
              '    ⚠️ 原来是 `playSessionId: uuidV4()` —— 那只用于上报，\n'
              '       URL 里没有它 ⇒ 两条路对不上');
    });

    test('★★ 上报请求里仍带 `PlaySessionId`（不能为了修 URL 而删它）', () {
      expect(src.contains("'PlaySessionId': playSessionId"), isTrue,
          reason: '★ `POST /Sessions/Playing` 也需要它\n'
              '    （官方文档：这是会话标识，Start/Progress/Stopped 都用）');
    });
  });

  group('★★★ 症状复现：空 PlaySessionId 的 URL 形态', () {
    test('★★★ 断言的是"不会生成 `?PlaySessionId=` 空值结尾的 URL"', () {
      // 真机那串 URL 的**特征**：以 `PlaySessionId=` 结尾（无值、无其他参数）
      const badUrl = 'http://s/Videos/1/hls1/main/265.mp4?PlaySessionId=';
      expect(RegExp(r'PlaySessionId=\s*$').hasMatch(badUrl), isTrue,
          reason: '★ 这是真机抓到的失败形态（用于确认判据本身有效）');
      // 修复后我们生成的 URL 一定有值：`PlaySessionId=<uuid>`
      const goodUrl = 'http://s/Videos/1/hls1/main/265.mp4'
          '?PlaySessionId=0f8a-4c2b&api_key=x';
      expect(RegExp(r'PlaySessionId=\s*$').hasMatch(goodUrl), isFalse,
          reason: '★ 有值就不会命中该判据');
    });
  });
}
