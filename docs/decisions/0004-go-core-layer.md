# ADR 0004 · 引入 Go 核心逻辑层（经 FFI 桥接）

- 状态：**已采纳**（2026-10-04）
- 决策者：项目所有者（明确要求"技术栈严格按照 Go 和 Flutter"）
- 影响范围：新增 `go/`、`lib/core/go_core.dart`、`tool/build_go.sh`、`android/.../jniLibs/`；
  与 ADR 0002（纯 Dart MVP）部分重叠，**0002 的"业务逻辑全在 Dart"被本 ADR 收窄**

## 背景

计划书（`cineflow.html`）原定技术栈是「Go 核心逻辑层 + Flutter UI」，
经 `flutter-go-bridge` 与 **Synurang（gRPC over FFI）** 桥接。
ADR 0002 曾因"纯 Dart 更快落地"降级为纯 Dart MVP，Go 侧从未落地。

2026-10 项目所有者明确要求**严格执行原技术栈**，故须把 Go 层建起来。

## 决策

引入 Go 核心逻辑层，编译为 Android 共享库（`-buildmode=c-shared`），
经 `dart:ffi` 调用。

### 关键实现约定

1. **分层**：`lib/core/go_core.dart`（Dart 绑定）↔ C ABI ↔ `go/bridge.go`（薄包装）
   ↔ `go/internal/rpc`（纯 Go 路由）↔ `go/internal/media`（纯 Go 业务规则）
2. **C ABI 只有三个符号**：`CineFlowPing` / `CineFlowCall` / `CineFlowFree`
3. **统一信封**：`CineFlowCall(method, payloadJSON) -> responseJSON`，
   形如 `{"ok":true,"result":{...}}` 或 `{"ok":false,"error":"..."}`
4. **内存契约**：返回的 `*C.char` 由 Go 侧 `C.CString` 分配，
   **必须**由 Dart 侧调 `CineFlowFree` 释放（Dart 侧用 try/finally 保证）
5. **降级**：`.so` 加载失败**不阻塞启动**——`GoCore.available == false`，
   业务可回退纯 Dart 路径。理由：Go 层是新引入的承载点，
   它的缺失不该让应用不可用。

### 为什么路由逻辑单独成包（踩过的坑）

`bridge.go` 含 `import "C"`，**整个 main 包因此依赖 cgo**；而本机默认
`CGO_ENABLED=0` 且无 gcc，于是 `go test ./...` 与 `go vet ./...` 都编不过 main 包，
纯逻辑单测无从谈起。拆出 `internal/rpc`（零 cgo）后，23 个测试在任意环境可跑，
不可测面积只剩 3 个薄包装。

## 与 Synurang 的关系（重要）

原选型 Synurang 需要其代码生成器 `protoc-gen-synurang-ffi`（Rust 编写，
`cargo install`），本机**无 cargo / protoc**，故当前先用**与之同构**的
「方法名 + JSON」最小 C ABI 打通链路。

替换成本已被刻意压低：Synurang 生成的 C ABI 本质也是「扁平化参数 + 字符串缓冲」，
接入时**只改 `bridge.go` 的转发，不改 Dart 侧调用契约**
（`GoCore.invoke(method, payload)` 语义不变）。

> 升级条件：装 Rust + protoc 后，用 `protoc --synurang-ffi_out=. service.proto`
> 生成 typed binding，替换 `bridge.go` 的 `CineFlowCall` 实现。

## 已迁移到 Go 的规则（有 Go 侧单测）

| 方法 | 规则 | 原 Dart 位置 |
|---|---|---|
| `media.normalizeLatest` | 清洗 `/Latest` 裸数组（滤掉 BoxSet/Folder） | `EmbyItem.isPlayable` |
| `media.filterByType` | 类型复筛（服务端 `IncludeItemTypes` 不可信） | `emby_provider` |
| `media.sortParams` | 排序补方向 + 加次级键（`DateCreated`→`Descending`） | `library_page`（已删） |
| `media.progress` | 进度/已看完/剩余分钟（95% 阈值） | `models.dart` |

## 构建

```bash
bash tool/build_go.sh                    # 默认 arm64-v8a（手机端）
bash tool/build_go.sh arm64-v8a x86_64   # 多 ABI
```

产物落在 `android/app/src/main/jniLibs/<abi>/libcineflow_go.so`，
Gradle 自动打进 APK。

> ⚠️ `.gitattributes` 必须把 `*.so` 标为 `binary`：
> 默认的 `* text=auto eol=lf` 会把 .so 当文本改写字节，
> **破坏 ELF 头导致库无法加载**。已加入。

## 替代方案（及未选原因）

| 方案 | 为什么没选 |
|---|---|
| 保持纯 Dart（ADR 0002） | 用户明确要求严格按 Go + Flutter 技术栈 |
| Go 编译成独立进程 + IPC | 手机端多一个进程开销大、保活难；FFI 同进程更省 |
| 直接上 Synurang | 缺 Rust/protoc 工具链；先打通链路，后续替换成本已压低 |
| C++/Rust 核心层 | 计划书选型是 Go；且 115driver 等预留生态在 Go 侧 |

## 回退条件

若出现以下情况，回退到纯 Dart（ADR 0002）：
- FFI 在某目标 ABI 上无法加载且无替代方案
- Go 层引入的复杂度超过它带来的收益（如仅剩 ping 这类无实质逻辑）

回退时更新：本 ADR 标"被取代"、`docs/architecture.md`、`docs/task-board.md`、
`AGENTS.md` §1 技术栈表。

## 参考

- 官方多语言 SDK：<https://github.com/MediaBrowser/Emby.ApiClients>
  —— **无 Dart 客户端，但有 Go 客户端**（`Clients/Go`，版本 4.10.1.0），
  印证"Go 核心层 + 自写 Dart UI"这条路线的合理性
- 官方 REST 文档：<https://dev.emby.media/reference/RestAPI.html>

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始：Go 层打通（真机验证 ping/媒体规则），记录 Synurang 未落地原因 |
