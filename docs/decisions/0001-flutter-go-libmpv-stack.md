# ADR 0001：采用 Flutter + Go 内嵌服务 + libmpv 技术栈

- 状态：**已废弃（2026-10-04 被 [ADR 0002](0002-pure-dart-mvp.md) 取代）**
- 决策者：Captain + Architect
- 影响范围：全项目分层、桥接方式、三端打包
- 来源：本 ADR 记录的是计划书 `../cineflow.html` 定义的**原始技术栈设想**，保留以备追溯。
  **它描述的不是本仓库当前实现**——实际实现见 ADR 0002。

## 背景与问题

CineFlow 要覆盖手机 / 桌面 / 电视的私人影音播放，需要：
(a) 一套 UI 覆盖多端；(b) 一个能稳定做 Emby 协议、弹幕聚合、未来 115 接入的服务层；
(c) 播放内核要能吃 libmpv（ASS 弹幕、硬解、质量档位）。
纯 Dart 方案在协议与聚合层要重复造轮子；纯原生多端要写三套 UI。

## 决策

1. UI 层 **Flutter**（Riverpod + go_router + drift），一套代码覆盖手机/桌面/电视。
2. 服务层 **Go 内嵌**，以 FFI/Protobuf 暴露给 Dart；Go 侧不依赖任何 Flutter 包。
3. 播放统一 **media_kit（libmpv）**，不混用其他播放器内核；平台差异用 `Capabilities()` 表达，不在内核间硬切。
4. 跨端数据契约用 **Protobuf over FFI**，契约先行、向后兼容。
5. 媒体源统一抽象 **`MediaProvider`**，Emby 先落地，115 只交付预留层（骨架 + `ErrNotImplemented`）。

## 替代方案（及未选原因）

| 方案 | 未选原因 |
|---|---|
| 纯 Flutter + dart 直接调 Emby HTTP | 弹幕聚合、115 未来的会话/风控逻辑放 UI 层，测试难、复用差；Go 生态的抓取与重试更省事 |
| Rust 核心（Tauri/自研） | 三端出包与 FFI 调试成本高于 Go；团队与生态参考少 |
| Go 原生 GUI（go-flutter / Wails） | UI 多端一致性差，电视端与移动端要重写 UI |
| 双内核（ExoPlayer / MPV 按端切） | 内部分支、bug 翻倍；先把 libmpv 一套吃透，端差异交给 `Capabilities()` |

## 影响范围

- `lib/` 只认统一模型；`go/` 不引 Flutter；桥接是唯一跨层入口
- 三端出包都要带 Go 产物（`.dll/.dylib/.so`、`.xcframework`、`.aar`），打包脚本是必修基础设施
- 115 真实接入（阶段八）不得改 `MediaProvider` 签名

## 回退条件

若 iOS 端 FFI 静态库长期无法链接、或双工具链调试成本失控：
降级为「纯 Dart 实现 Emby API + 弹幕 HTTP」，Go 层只保留 CLI 形态作为调试工具；
需重新评审 ADR 0002 并同步 `docs/architecture.md` 与计划书的阶段二/三排期。

> **该回退条件已于 2026-10-04 触发**：实际开发选择了"降级为纯 Dart"这条路径，
> 见 [ADR 0002](0002-pure-dart-mvp.md)。本 ADR 因此标为已废弃。

## 参考

- 形态最接近的开源参考：`getlantern/lantern`（Flutter+Go，桌面 FFI / 移动 gomobile 平台通道 + Protobuf）
- 桥接生成参考：`csnewman/flutter-go-bridge`、`leehack/flutter_golang_ffi_example`
- 播放内核依赖：`media-kit/media-kit`（libmpv 封装）

---

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本：flutter/go/libmpv 技术栈决策与替代方案、回退条件 |
| v1.1 | 2026-10-04 | 状态改为「已废弃（被 ADR 0002 取代）」；标注本 ADR 描述的是计划书设想而非当前实现；回退条件标注已触发 |
