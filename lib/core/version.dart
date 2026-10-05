/// 应用版本号 —— **单一事实来源**。
///
/// 为什么要有这个文件：版本号曾散在三处且互不一致（缺陷 7.17）——
/// `VERSION` 是 0.2.0、`pubspec.yaml` 是 1.0.0+1、协议头 `clientVersion` 是 0.1.0、
/// 「我的」页硬编码 v0.1.0。三处不一致的后果不只是难看：
/// 更新检查会误判「已是最新」而静默卡死老用户。
///
/// 现在的约定：
///   1. 仓库根 `VERSION` 是**唯一权威**，只写 `X.Y.Z` 一行；
///   2. `pubspec.yaml` 的 `version:` 必须与它同前缀（构建脚本 `tool/bump_version.ps1` 校验）；
///   3. Dart 侧一律读本文件，**不要再硬编码版本字符串**；
///   4. 发版时跑 `powershell -File tool/bump_version.ps1 -Version X.Y.Z` 一次改齐。
///
/// 注意：`VERSION` 是纯文本文件，Dart 无法在编译期读取它，所以这里用常量镜像它。
/// 校验由构建脚本承担（`tool/bump_version.ps1 -Check` 会比对两者并报错）。
library;

/// 应用版本（与仓库根 `VERSION` 保持一致）。
const String kAppVersion = '0.2.0';

/// Emby 协议头 `Version="..."` 用的客户端版本。
///
/// 与 [kAppVersion] 同源：协议头版本失真会让服务端会话里的客户端信息不可信，
/// 排查问题时误导（曾长期是 0.1.0 而应用已是 1.0.0）。
const String kClientVersion = kAppVersion;

/// 「我的」页展示用（带 v 前缀）。
const String kAppVersionLabel = 'v$kAppVersion';
