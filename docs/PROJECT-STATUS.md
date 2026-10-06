# CineFlow 开发计划与进度报告

> **生成日期**：2026-10-05　|　**版本**：0.3.0（build 2）
> **本文件是快照**：进度数字会过期，**每次开发前请以 [`AI-MEMORY.md`](AI-MEMORY.md) 为准**（那里是每轮更新的台账）。
> 本报告回答三个问题：**要做成什么**（计划）· **现在到哪了**（进度）· **具体怎么实现的**（细节）。

---

## 一、项目定位

**CineFlow（影流）** —— Material 风格的 **Emby 第三方播放器**，当前**仅 Android 手机端**。

- 媒体库 / 详情 / 播放全部由**用户自建的 Emby 服务器**真实数据驱动；**应用本身不托管任何内容**。
- 播放内核：**安卓原生 mpv**（自持 `libmpv.so` + Kotlin/JNI 薄桥 + Flutter 纹理输出）。
- 扩展能力：115 网盘直连播放、弹幕（弹弹play 官方 + 自建兼容）、豆瓣榜单。
- 许可：**Apache-2.0**，源码 https://github.com/bsfcxz/CineFlow

### 与原始计划书的关系

原始计划书在 `C:\Users\a1332\Desktop\cineflow.html`（**注意：不在仓库内**，AGENTS.md 写的
`../cineflow.html` 路径是错的，实际在上一层目录）。

计划书 v2.0 定的是「Flutter + Go 内嵌服务层 + Synurang/FFI」架构与八阶段路线图。
**执行中出现了 6 处偏差**（见 §5），其中 3 处是用户主动变更（已留 ADR），3 处是文档滞后。

---

## 二、技术架构（实际实现）

```
┌──────────────────────────────────────────────────────────────┐
│              Flutter UI 层（lib/，55 文件 / 14250 行）         │
│   pages/(11) · player/(6) · danmaku/(10) · pan115/(5)         │
│   data/(8) · core/(5) · state/(2) · widgets/(2) · douban/(5)   │
└───────────────────────────┬──────────────────────────────────┘
                            │
        ┌───────────────────┴───────────────────┐
        ▼                                       ▼
┌───────────────────┐                 ┌──────────────────────┐
│ MediaProvider 抽象 │                 │  PlayerFacade 抽象    │
│ （Emby 实现）      │                 │  （mpv 实现）         │
└─────────┬─────────┘                 └──────────┬───────────┘
          │ FFI（JSON-over-FFI）                 │ MethodChannel
          ▼                                      │ EventChannel
┌───────────────────┐                          │
│  Go 核心层         │                          │
│  libcineflow_go.so │                          │
│  18 文件 / 2385 行 │                          │
│  media · rpc ·     │                          │
│  pan115 · m115     │                          │
└───────────────────┘                          │
                                               ▼
                            ┌──────────────────────────────────┐
                            │  Kotlin 桥（308 行）              │
                            │  MPVLib / PlayerChannel           │
                            └──────────────┬───────────────────┘
                                           │ JNI
                                           ▼
                            ┌──────────────────────────────────┐
                            │  C 桥（cineflow_mpv.c 510 行）    │
                            │  事件线程 · JSON 转义 · Surface→wid│
                            └──────────────┬───────────────────┘
                                           ▼
                            ┌──────────────────────────────────┐
                            │  libmpv.so（11.80 MB，自持）      │
                            │  ffmpeg 静态链入                  │
                            │  gpu-context=android 自建 EGL     │
                            └──────────────────────────────────┘
```

### ★ 关键决策：渲染出口用 Flutter 纹理，不是 PlatformView

Kotlin 拿 `TextureRegistry` 的 Surface → `NewGlobalRef` → `mpv_set_option("wid", int64)`，
mpv 自己建 EGL 画进这个 Surface，Flutter 侧就是普通的 `Texture(textureId:)` 图层。

**为什么**（详见 [ADR 0009](decisions/0009-native-mpv-kernel.md)）：
1. 上游 mpv-android **根本不用 `mpv_render_context`**（`render.cpp` 全文就是 `wid`），无范例可对照；
2. render API 要求 GL 上下文"调用线程 current 且与创建时同源"，PlatformView 合成时序不受控；
3. 纹理是普通 Flutter 图层 → **弹幕/手势/控制层直接叠加，无需手势仲裁**
   （而这正是原方案自己点名的头号风险）。

---

## 三、八阶段进度

> 权威表在 [`AGENTS.md`](../AGENTS.md) §1；此处为快照。

| 阶段 | 内容 | 进度 | 状态说明 |
|---|---|---|---|
| 一 | 工程初始化 | **✅ 完成** | Flutter 侧完成；**Go 核心层已落地**（ADR 0004） |
| 二 | Emby API 接入 | **~97%** | 认证/媒体库/详情/搜索/进度上报齐全。**缺 401 自愈**（token 失效需重新登录，缺陷 7.7） |
| 三 | 视频播放核心 | **~96%** | **内核已迁到安卓原生 mpv（K0–K4，ADR 0009）+ 真机验证**。待办：Media3 会话层（`CF-P3-KERNEL-004`）、片源回归（`CF-P3-KERNEL-005`） |
| 四 | UI/UX 与媒体库 | **~80%** | 排序/降级/导演/theme 令牌全落地。**列表页 UI 待全量重构**（`CF-P4-UI-019`） |
| 五 | 弹幕系统 | **~70%** | 协议/渲染/设置/持久化**全部落地**（161 例单测）。未做：发送、手动匹配面板、密度折线图。**未联调**：官方 API 本机不可达 |
| 六 | 多平台适配 | **搁置** | 用户明确只做 Android 手机端 |
| 七 | 测试与发布 | **~70%** | 286 Dart + 143 Go + 1 真机集成，全绿。**release 签名待换**（缺陷 7.16） |
| 八 | 115 网盘扩展 | **~55%** | 协议层+扫码+浏览+播放页全落地（ADR 0007）。**未联调**：无真实账号。⚠️ 非公开接口，有风控风险 |

---

## 四、代码与测试规模（实测）

### 代码

| 层 | 文件 | 行数 |
|---|---|---|
| Dart 源码 | 55 | **16,931** |
| Dart 测试 | 17 | 3,488 |
| Go 源码 | 18 | 3,241 |
| Go 测试 | 8 | 2,548 |
| Kotlin | 3 | 393 |
| C / CMake（自写） | 2 | 629 |
| ↳ 其中 vendored mpv 头 | 4 | 3,251（非本项目代码） |

**Dart 模块分布**：`pages` 3,749 · `player` 3,104 · `data` 2,891 · `danmaku` 2,525 ·
`pan115` 1,871 · `douban` 1,248 · `core` 690 · `widgets` 611 · `state` 142 · `main.dart` 100

**Go 包分布**：`internal/pan115`(12 文件) · `internal/rpc`(5) · `internal/pan115/m115`(5) · `internal/media`(3)

> ⚠️ **行数统计口径**：本仓库源码是 **LF 行尾**，PowerShell 的 `Get-Content` 会**少算**。
> 同一批文件实测：`Get-Content` 报 **14,250** 行，实际 **16,931** 行（差 2,681 行）。
> **必须用 `ReadAllLines()` / `splitlines()`**（AGENTS.md §3.1 有明文记录）。

### 测试（实测输出，非估算）

| 套件 | 数量 | 命令 | 结果 |
|---|---|---|---|
| Dart 单测 | **286 例** | `flutter test` | `+286: All tests passed!` |
| Go 单测 | **143 例** | `go test ./...` | 4 包全 ok |
| 真机集成 | **1 例** | `flutter test integration_test/... -d <id>` | `+1: All tests passed!` |

> ⚠️ **Dart 静态计数（grep `test(`）= 282，实际运行 = 286** —— 有 4 例由循环动态生成。
> **以运行输出为准**，这是本仓库反复踩过的坑（曾把数字写错多次）。

**Dart 用例分布**：弹幕 7 文件 161 例 · drift 17 · 服务端筛选 16 · 路由 15 ·
115 存储 13 · 豆瓣缓存 12 · Go 核心载荷 10 · 演职员 10 · 首页降级 6 · 偏好 5 · 登录冒烟 1

**Go 用例分布**：pan115 60 · m115 60 · media 11 · rpc 12

### 质量基线

| 项 | 当前值 |
|---|---|
| `flutter analyze` | **0 issue**（无 error / warning / info） |
| `go vet` | 0 警告 |
| 开发门禁 `scripts/check-dev.ps1` | **18 项全过，退出码 0** |
| 仓库体积 | 0.10 GB（构建垃圾已清） |

---

## 五、计划书 vs 实际：6 处偏差

| # | 计划书写的 | 实际 | 性质 | 留痕 |
|---|---|---|---|---|
| 1 | 播放内核 `media_kit (libmpv)` | **安卓原生 mpv**，media_kit 已移除 | 用户主动变更 | ADR 0009 |
| 2 | `Riverpod 2.x` | **3.x** | 文档滞后 | — |
| 3 | `Synurang`（gRPC over FFI） | **未落地**，用同构的 JSON-over-FFI | 缺 Rust + protoc | ADR 0004 |
| 4 | 115「预留接口，暂不实现」 | **已实现**（~55%） | 用户要求重启 | ADR 0007 |
| 5 | 多平台（iOS/桌面/平板/TV） | **仅 Android**，其余搁置 | 用户明确缩小 | AGENTS §1 |
| 6 | 弹幕渲染「待选型」 | 已定 **自绘 CustomPainter** | 已决策 | ADR 0006 |

> 建议在计划书里补一段「实际偏差说明」，否则后来人会拿它当规格用。

---

## 六、关键技术细节

### 6.1 播放内核（最复杂的一块）

**三条不可动摇的顺序约束**（违反必崩）：

1. **`av_jni_set_java_vm` 必须在任何 mpv 调用前注册**（放 `JNI_OnLoad`）。
   不注册的现象极具误导性：**解封装完全正常**（logcat 里 h264/aac 所有轨道都列出来了），
   只有视频输出失败 → `end-file error`。**"能解析出轨道"不等于"能播"**。
2. **`wid` 必须在 `mpv_initialize` 之前 `mpv_set_option`**（之后设置不再生效）。
   → Kotlin 顺序钉死：`createSurface → attachSurface → initialize`。
3. **`Surface` 必须 `NewGlobalRef`**；**事件线程必须在 `mpv_terminate_destroy` 前 join**。

**真机证据**（Xiaomi M2012K11AC / Android 13 / arm64）：

```
av_jni_set_java_vm -> 0 (0=成功)
attachSurface: wid=14182  →  wid 已设定 = 14182
mpv_initialize 成功，client API 版本=131074
[mpv/vd] Using hardware decoding (mediacodec).
AO: [audiotrack] 44100Hz stereo 2ch float
VO: [gpu] 1920x1080 mediacodec
```

**libmpv.so 规格**：12,369,680 字节；ELF `7F 45 4C 46` / 机器 `0xB7`(AArch64) / ET_DYN；
`DT_NEEDED` 只有系统库（libm/libandroid/libOpenSLES/libEGL/libdl/libc）→ **ffmpeg 静态链入**，单文件自包含。

### 6.2 Go 核心层

- **业务逻辑必须在零 cgo 的包**（`internal/rpc`、`internal/media`、`internal/pan115`）——
  含 `import "C"` 的包会让 `go test` 在无 gcc 时编不过。`bridge.go` 只留 C 边界薄包装。
- 交叉编译：`CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=<ndk>/…/aarch64-linux-android24-clang.cmd`
  （`.cmd` 后缀不能省）。
- **Go 编译器会合并字符串常量** → 无法用 `strings` 扫 `.so` 验证方法名，
  **只能靠运行时调用**（启动时的 `[GoCore] sortParams=…` 自检日志）。

### 6.3 数据层

- **drift 家族钉 2.31.x、sqlite3 钉 2.x**：3.x 需 Dart native assets，未启用时运行期报
  `Couldn't resolve native function 'sqlite3_temp_directory'`。
- **TTL 在写入时固化**进 `expires_at` 列，由 SQL 判断（旧契约允许实现方收下 ttl 却不用，是缺陷 §7.4 的根源）。
- 缓存放 drift/SQLite 而非内存 → 重启后仍命中。

### 6.4 115 网盘（风险最高）

- 走的是**非公开 webapi 接口**（非官方开放平台），**有账号风控风险**，已在登录页明示。
- **UA 与取直链绑定**：取址 UA 必须与播放 UA 逐字节一致，且 `Set-Cookie`（`download_token`）
  必须合并进播放请求 → 故 `Pan115Playback` **把 url 与 headers 绑在同一类型**，不给"只拿 URL"的机会。
- **`m115` 不是对称加解密**：全流程只有公开指数 e、没有私钥 d，
  `Decode(Encode(x,k),k)` **不还原原文** —— 这是上游既定设计，**别"修好"它**。
- 全局 **2 请求/秒严格串行**（账号安全，非性能优化）。

---

## 七、待办（按优先级）

| # | 事项 | 卡号 | 说明 |
|---|---|---|---|
| 1 | **真机走查播放器整页** | — | 集成测试只驱动内核，**画面/手势/弹幕叠加没看过** |
| 2 | **Media3 会话层**（通知栏/耳机键/后台/音频焦点） | `CF-P3-KERNEL-004` | ⚠️ 音频焦点**必须自研**（Media3 不代劳） |
| 3 | 片源回归（4K DV / PGS / 多音轨） | `CF-P3-KERNEL-005` | 迁移的唯一验证缺口 |
| 4 | 列表页 UI 全量重构 | `CF-P4-UI-019` | ADR 0003 后待重做 |
| 5 | 401 自愈 | `CF-P2-EMBY-011` | 缺陷 7.7 |
| 6 | release 签名 | `CF-P7-RELEASE-013` | 缺陷 7.16，**发布前必做** |
| 7 | 播放中 WakeLock | `CF-P3-KERNEL-006` | 缺陷 7.11 |
| 8 | 115 真实账号联调 | `CF-P8-115-030` | 等账号 |
| 9 | 接入 Synurang 替换 JSON-over-FFI | `CF-P1-GO-020` | 等 Rust + protoc |

### 发布状态

**发布候选已就绪**（等用户审批，见 [AI-DISTRIBUTION.md](AI-DISTRIBUTION.md)）：

| 项 | 值 |
|---|---|
| 产物 | `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` |
| 大小 | **37.97 MB** |
| versionCode / Name | **2002** / 0.3.0 |
| SHA256 | `72dbced4b28b569c007dbdb173ee54d56716ba496bacd70602ccc22e31b7199c` |
| 内核 | ✅ mpv（含 `libmpv.so`，零 media_kit 痕迹） |
| 真机验证 | ✅ 装机成功（无需 `-d`）、启动无崩溃、界面正常渲染 |
| 混淆符号表 | `build/symbols/`（**必须与 APK 成对保留**） |

---

## 八、工程流程（本项目特有）

### 每轮开发固定动作

| 时机 | 动作 |
|---|---|
| **动手前** | 读 [`AI-MEMORY.md`](AI-MEMORY.md)（进度快照 + 变更台账 + 交接）+ `AGENTS.md` §6/§7/§9 |
| **收工前** | 跑 `scripts/check-dev.ps1`（**退出码 0 才算完成**）+ 更新 `AI-MEMORY.md` |
| **发版前** | 读 [`AI-DISTRIBUTION.md`](AI-DISTRIBUTION.md)，**未经用户审批绝不发版** |

### 门禁体系

```bash
# 一条命令跑完：静态分析 / 单测 / 仓库门禁 / 产物校验 / 真机冒烟
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-dev.ps1

# 单项
flutter analyze && flutter test
(cd go && go vet ./... && go test ./...)
powershell ... -File scripts/check-secrets.ps1     # 敏感信息
powershell ... -File scripts/check-docs.ps1        # 必需文档 + 断链
powershell ... -File tool/bump_version.ps1 -Check  # 版本号三处一致
```

**门禁本身也做过反向注入验证**（否则"门禁通过"没有意义）：
APK 入口污染检测、PowerShell BOM 检测，都实测"制造问题→报红→修复→转绿"。

### 版本号

**唯一权威**：仓库根 `VERSION`（只写 `X.Y.Z`）。
`pubspec.yaml`(`X.Y.Z+<build>`) 与 `lib/core/version.dart` 必须一致，由 `bump_version.ps1` 强制校验。

**build number（Android versionCode）只增不减** —— 它决定能否覆盖安装。
曾经恒为 1，导致设备上装的 2001 永远更大、`adb install -r` 报降级错误，
而**用户没有 `-d`**，只会看到"应用未安装"。现已修。

---

## 九、文档地图

| 想知道 | 看 |
|---|---|
| **接下来往哪走 / 先做什么 / 什么卡住了** | [`DEVELOPMENT-PLAN.md`](DEVELOPMENT-PLAN.md)（**开发计划书**：目的地 · 作业面 · 雾区 · 范围外 · 执行顺序） |
| **现在到哪了 / 上轮改了什么** | [`AI-MEMORY.md`](AI-MEMORY.md)（**每轮必读必写**） |
| 作业手册（铁律 / 坑 / 验收） | [`../AGENTS.md`](../AGENTS.md) |
| **发版纪律（不得自增版本、不得删旧 Release、须审批）** | [`AI-DISTRIBUTION.md`](AI-DISTRIBUTION.md) |
| 播放内核方案与 8 个实测坑 | [`PLAYER-KERNEL.md`](PLAYER-KERNEL.md) |
| 架构决策与理由 | [`decisions/`](decisions/README.md)（ADR 0001–0007、0009） |
| 可执行任务卡 | [`task-board.md`](task-board.md) |
| 审查清单 | [`review-checklist.md`](review-checklist.md) |
| 变更日志写法 | [`CHANGELOG-GUIDE.md`](CHANGELOG-GUIDE.md) |
| 发布说明（Release 正文事实源） | [`changelog/`](changelog/README.md) |

---

## 十、已知限制（对外必须如实说明）

| 限制 | 影响 | 依据 |
|---|---|---|
| **debug 签名** | 仅供自用与体验，**不能正式分发、不能上架** | 缺陷 7.16 |
| 仅 **arm64-v8a** | 32 位设备与部分模拟器装不上 | 构建配置 |
| 无 Media3 会话层 | **无通知栏控制 / 蓝牙耳机键 / 后台播放** | K3 未做 |
| 无 401 自愈 | token 失效需重新登录 | 缺陷 7.7 |
| 无 WakeLock | 播放中可能熄屏 | 缺陷 7.11 |
| 115 非公开接口 | 有账号风控风险 | ADR 0007 |
| 弹幕官方 API 未联调 | 本机网络不可达，仅靠单测守协议 | ADR 0006 |

---

*本报告由实测数据生成（测试数量、代码行数、APK 指纹均为命令输出，非估算）。
计划书原件见 `C:\Users\a1332\Desktop\cineflow.html`。*
