/// 豆瓣图床图片组件 —— dio 拉取（带 Referer/UA 防盗链头）+ 内存缓存
/// Image.network 的失败原因不可观测且同样带 headers 仍 418，故统一走 dio。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'douban_client.dart';

class DoubanImage extends StatefulWidget {
  const DoubanImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.radius = 8,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double radius;

  @override
  State<DoubanImage> createState() => _DoubanImageState();
}

class _DoubanImageState extends State<DoubanImage> {
  static final _cache = <String, Uint8List>{};
  static final _dio = Dio(BaseOptions(
    validateStatus: (c) => c != null && c < 600,
    responseType: ResponseType.bytes,
  ));
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DoubanImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  Future<void> _load() async {
    final cached = _cache[widget.url];
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    if (_loading) return;
    _loading = true;
    try {
      final r = await _dio.get<List<int>>(widget.url,
          options: Options(headers: DoubanClient.imageHeaders));
      final bytes = r.data;
      if (bytes != null && r.statusCode == 200) {
        _cache[widget.url] = Uint8List.fromList(bytes);
        if (mounted) setState(() => _bytes = _cache[widget.url]);
      }
    } catch (_) {
      // 保持占位
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Container(
        width: widget.width,
        height: widget.height,
        color: const Color(0xFF162040),
        alignment: Alignment.center,
        child: _bytes != null
            ? Image.memory(_bytes!, fit: widget.fit,
                width: widget.width, height: widget.height)
            : Icon(Icons.movie_outlined, size: 20, color: Color(0xFF5A6F99)),
      ),
    );
  }
}
