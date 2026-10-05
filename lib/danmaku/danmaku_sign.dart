/// 弹弹play 开放弹幕网络的请求签名（**纯函数，可单测**）。
///
/// ## 官方规范（来源：<https://doc.dandanplay.com/open/> 第二节第 5 条）
///
/// 算法：`base64(sha256(AppId + Timestamp + Path + AppSecret))`
///
/// 三段细节容易做错，官方文档逐条写明：
/// 1. **Path 不含域名、不含查询参数**，且**以 `/` 开头**。
///    例：请求 `https://api.dandanplay.net/api/v2/comment/123?withRelated=true`
///    → 参与签名的 path 是 `/api/v2/comment/123`（**不含 `?withRelated=true`**）。
/// 2. **拼接顺序固定为 AppId → Timestamp → Path → AppSecret**，区分大小写，
///    中间**没有分隔符**。
/// 3. Timestamp 是 **UTC 秒级** Unix 时间戳。与服务器时间偏差过大会 403
///    （`X-Error-Message: Invalid Timestamp`），故必须用设备真实时间。
///
/// ## 为什么单独成文件且做成纯函数
///
/// 签名错了服务端只返回一个 403 + 一个响应头，没有可读的调试信息；
/// 而这类"看起来对但差一个字符"的问题靠肉眼审代码极难发现。
/// 做成纯函数后可以用**官方给出的示例值**做确定性断言（见 `test/danmaku_sign_test.dart`）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 生成 `X-Signature`。
///
/// [path] 必须是**不含查询参数**的路径（以 `/` 开头）。
/// 传入带 `?` 的字符串会被自动截断——这比抛异常安全：
/// 调用方很可能直接把 `uri.path` 之外的完整 path+query 传进来，
/// 截断能救回这种常见误用，而抛异常会让弹幕直接不可用。
String dandanplaySignature({
  required String appId,
  required String appSecret,
  required String path,
  required int timestamp,
}) {
  final cleanPath = path.split('?').first;
  final data = '$appId$timestamp$cleanPath$appSecret';
  final digest = sha256.convert(utf8.encode(data));
  return base64.encode(digest.bytes);
}

/// 构造官方要求的三件套请求头。
///
/// 只回三个头，不掺入其它逻辑——调用方（Dio 拦截器）负责注入。
Map<String, String> dandanplayAuthHeaders({
  required String appId,
  required String appSecret,
  required String path,
  DateTime? now,
}) {
  final ts = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
  return {
    'X-AppId': appId,
    'X-Timestamp': '$ts',
    'X-Signature': dandanplaySignature(
      appId: appId,
      appSecret: appSecret,
      path: path,
      timestamp: ts,
    ),
  };
}
