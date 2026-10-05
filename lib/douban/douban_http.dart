/// 豆瓣客户端的 HTTP 适配层 —— 替代原 source_api 的 AppHttpClient /
/// Logger / Response 扩展，只实现 douban_client.dart 实际用到的能力。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

/// 豆瓣请求失败
class DoubanException implements Exception {
  final String message;
  const DoubanException(this.message);
  @override
  String toString() => message;
}

/// 简化版 HTTP 响应（对齐原 source_api 扩展的 API 面）
class DoubanHttpResponse {
  final int statusCode;
  final String body;
  const DoubanHttpResponse(this.statusCode, this.body);

  bool get isOk => statusCode >= 200 && statusCode < 300;

  String get asText => body;

  /// 失败时构造异常（保留豆瓣原始信息，不吞成空列表）
  Object toFailure(String scope) =>
      DoubanException('$scope 失败 (HTTP $statusCode)');
}

typedef DoubanLogger = void Function(String message);

void silentDoubanLogger(String message) {}

/// 基于 dio 的最小 HTTP 客户端（baseUrl 只到域名，路径写全路径）
class DoubanHttp {
  DoubanHttp({required String baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          validateStatus: (c) => c != null && c < 600,
          responseType: ResponseType.plain,
        ));

  final Dio _dio;

  Future<DoubanHttpResponse> get(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, String> headers = const {},
  }) async {
    try {
      final r = await _dio.get<String>(
        path,
        queryParameters: query.map((k, v) => MapEntry(k, '$v')),
        options: Options(headers: headers),
      );
      return DoubanHttpResponse(r.statusCode ?? 0, r.data ?? '');
    } on DioException catch (e) {
      final r = e.response;
      if (r != null) {
        return DoubanHttpResponse(
            r.statusCode ?? 0, r.data is String ? r.data as String : '');
      }
      return DoubanHttpResponse(0, '网络错误：${e.type.name}');
    }
  }
}

/// 容错的 JSON 解码（原 source_api 同名助手）
Object? tryDecodeJson(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}
