/// 数据库连接与全局实例。
///
/// ## 连接策略
///
/// 生产用 `drift_flutter` 的 `driftDatabase()`：它按平台选实现
/// （Android 用 sqlite3_flutter_libs 自带的 native 库，桌面用系统 sqlite），
/// 并把文件放到各平台的"应用私有数据目录"——**不是 cacheDir**：
/// 播放历史属于用户数据，被系统当缓存清掉就丢了。
///
/// 测试用 `NativeDatabase.memory()`：每次测试干净、不落盘、互不干扰。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';

/// 数据库文件名。
const _dbName = 'cineflow';

/// 打开生产数据库（文件型）。
QueryExecutor openAppExecutor() => driftDatabase(name: _dbName);

/// 应用数据库实例。
///
/// 用 Provider 而不是全局单例变量：测试可用 `overrideWith` 换成内存库，
/// 而全局变量做不到（会跨测试互相污染）。
final appDbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(openAppExecutor());
  ref.onDispose(db.close);
  return db;
});
