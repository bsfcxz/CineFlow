# AI 记忆库 · CineFlow

> **每次 AI 开始开发前，先读本文件。每次开发结束后，更新本文件。**
>
> 这是**唯一**要求"每轮必读"的文件。它回答三个问题：
> 1. **现在到哪一步了**（进度快照，含未提交的改动）
> 2. **上一轮谁改了什么、为什么**（变更台账——避免重复劳动与回退别人的修复）
> 3. **下一步该做什么、有什么坑等着**（交接）
>
> 与其它文档的分工：
> | 文档 | 职责 | 更新时机 |
> |---|---|---|
> | **本文件** | **进度快照 + 变更台账 + 交接** | **每轮开发开始前读、结束后写** |
> | [AGENTS.md](../AGENTS.md) | 作业手册（铁律、坑、验收基线） | 发现新坑 / 改流程时 |
> | [docs/task-board.md](task-board.md) | 可执行任务卡（ID / owner / 状态） | 建卡 / 完成任务时 |
> | [docs/decisions/](decisions/README.md) | ADR：决策与理由 | 做架构决策时 |
> | [docs/PLAYER-KERNEL.md](PLAYER-KERNEL.md) | 播放内核专项（含实测证据） | 动播放器时 |
> | [docs/review-checklist.md](review-checklist.md) | 审查清单（L0–L3） | 审查流程变化时 |
>
> 冲突优先级：**用户当轮指令 > AGENTS.md > 本文件 > 其它**。
> 本文件的"进度"部分是**快照**，会过期；代码与实测输出永远是事实来源。

---

## 0. 快速交接（30 秒版）

| 项 | 值 |
|---|---|
| 当前版本 | **0.3.0**（build **2**；`VERSION` = pubspec = `lib/core/version.dart`） |
| 当前阶段 | 阶段三收尾（播放内核迁移已完成） + **阶段四 UI 打磨（第 8 轮做了主题与排版体系）** |
| 最近一次实测 | `flutter analyze` **0 issue** · `flutter test` **286 例全绿** · `go test` **143 例** · `check-dev.ps1` **18 项全过** |
| **发布候选** | ✅ `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` **37.97 MB**（versionCode 2002 / mpv 内核 / 已真机验证）<br>SHA256 `72dbced4b28b569c007dbdb173ee54d56716ba496bacd70602ccc22e31b7199c`<br>**混淆符号表在 `build/symbols/`——必须与 APK 成对保留，勿删** |
| 工作区状态 | ⚠️ **有大量未提交改动**（见 §4），尚未 commit |
| 仓库体积 | **0.10 GB**（构建垃圾已清） |
| 真机 | Xiaomi M2012K11AC / Android 13 / arm64（`flutter devices` 自查 id） |
| 最该知道的坑 | **改完 UI 后装包前必须 `flutter build apk`**——`integration_test` **与 `patrol_test`** 都会污染 APK 入口（见 §6.1） |
| **发版状态** | ⛔ **未发布**。已备好产物与 changelog，**等用户审批**（见 [AI-DISTRIBUTION.md](AI-DISTRIBUTION.md) §3） |

---

## 1. 项目是什么

**CineFlow（影流）** —— Material 风格的 **Emby 第三方播放器**，仅 Android 手机端。

- 媒体库 / 详情 / 播放由**用户自建的 Emby 服务器**真实数据驱动；应用不托管任何内容。
- 播放内核：**安卓原生 mpv**（自持 `libmpv.so` + Kotlin/JNI 薄桥 + Flutter 纹理输出）。
- 另有 115 网盘直连播放、弹幕（弹弹play）、豆瓣榜单。
- 许可：Apache-2.0，源码公开于 https://github.com/bsfcxz/CineFlow

### 每轮开发的固定入口

| 什么时候 | 做什么 |
|---|---|
| **动手前** | 读本文件（§0 快照 → §3 台账 → §5 交接）+ `AGENTS.md` §6/§7/§9 |
| **收工前** | 跑 `scripts/check-dev.ps1`（退出码 0 才算过）+ 更新本文件 |
| **涉及发版/上传时** | **读 [AI-DISTRIBUTION.md](AI-DISTRIBUTION.md)** —— 分发铁律 D1–D10，**未经用户审批绝不发版** |
| **需要总览计划/进度/细节时** | 读 **[PROJECT-STATUS.md](PROJECT-STATUS.md)**（给人看的快照；数字逐条实测核对过） |

---

## 2. 进度快照

| 阶段 | 内容 | 状态 | 备注 |
|---|---|---|---|
| 一 | 工程初始化 | ✅ | Flutter + Go 层均落地 |
| 二 | Emby API 接入 | ~97% | 缺 401 自愈（缺陷 7.7） |
| 三 | 视频播放核心 | **~97%** | **第 11 轮真机走查通过**：4K HEVC 硬解（`VO: [gpu] 3840x2160 mediacodec`）· **Drop 0** · 横屏 `ROTATION_90` · 播放→返回 **pid 存活无崩溃**。内核迁到安卓原生 mpv（ADR 0009）。待 K3 会话层 + 片源回归 |
| 四 | UI/UX 与媒体库 | **~88%** | **第 8/9/11 轮**：补齐 15 项主题配置 + 9 档排版体系 + 修 8 处主题 bug + 统一空态 + 5 处命中区缺陷 + 响应式尺寸。**首页内容占屏 42%→72.5%**（修 isPlayable 口径）。列表页待重构（CF-P4-UI-019） |
| 五 | 弹幕系统 | ~70% | 未做：发送、手动匹配、密度折线图 |
| 六 | 多平台 | 搁置 | 用户明确只做手机端 |
| 七 | 测试与发布 | ~70% | 286 Flutter + 143 Go 全绿；release 签名待换 |
| 八 | 115 网盘 | ~55% | 无真实账号，未联调 |

### 路线图未完成项（按优先级）

1. **K3 · Media3 会话层**（`CF-P3-KERNEL-004`）—— 通知栏/蓝牙键/后台/音频焦点。⚠️ 音频焦点**必须自研**（Media3 不代劳）。
2. **迁移片源对照回归**（`CF-P3-KERNEL-005`）—— 4K DV / PGS 字幕。
3. **列表页全量重构**（`CF-P4-UI-019`）。
4. **401 自愈**（缺陷 7.7）+ **release 签名**（缺陷 7.16）。
5. **115 真实账号联调**。

---

## 3. 变更台账（谁改了什么、为什么）

### 2026-10-05 · 第 1 轮 · 播放内核迁移（K0–K4）

**做了什么**：把播放内核从 `media_kit` 插件换成**安卓原生 mpv**。

| 层 | 文件 | 关键改动 |
|---|---|---|
| C | `android/app/src/main/cpp/cineflow_mpv.c` | JNI 桥 + 事件线程 + `Surface→wid` + JSON 转义 |
| C | `.../cpp/CMakeLists.txt` | include 指向 `include/`；按 ABI 链接 `libmpv.so`；桩构建 |
| Kotlin | `.../player/MPVLib.kt` | `attachSurface/detachSurface/command/property` |
| Kotlin | `.../player/PlayerChannel.kt` | 纹理管理 + 通道；**钉死初始化顺序** |
| Kotlin | `.../MainActivity.kt` | 传 `flutterEngine.renderer`；移除 PlatformView 注册 |
| Kotlin | `.../player/MpvFlutterView.kt` | **已删除**（PlatformView 方案作废） |
| Dart | `lib/player/kernel.dart` | `PlayerKernel` 抽象 |
| Dart | `lib/player/native/native_kernel.dart` | MethodChannel/EventChannel 实现 |
| Dart | `lib/player/native/native_video_view.dart` | `Texture(textureId)` 输出层 |
| Dart | `lib/player/player_facade.dart` | 门面，API 面**刻意对齐 media_kit** |
| Dart | `lib/player/mediakit_kernel.dart` | **已删除** |
| Dart | `lib/player/player_page.dart` | 切到 `PlayerFacade`，**零 media_kit 引用** |
| Dart | `lib/pan115/pan115_player.dart` | 同上；`headers` 语义不变 |
| 配置 | `pubspec.yaml` | 移除 media_kit 三件套；加 `integration_test` |
| 测试 | `integration_test/player_kernel_test.dart` | **新增**：真机全链路验收 |

**为什么换渲染方案**（原方案是 PlatformView + `mpv_render_context`）：
① 上游 mpv-android **根本不用 render API**（`render.cpp` 就是 `wid`），无范例可对照；
② render API 要求 GL 上下文"调用线程 current 且与创建时同源"，PlatformView 合成时序不受控；
③ 纹理是普通 Flutter 图层，弹幕/手势天然叠加，**直接消除了原方案自己点名的头号风险**。

**踩到并修掉的 8 个坑**：详见 [PLAYER-KERNEL.md §4](PLAYER-KERNEL.md)。
最值钱的那个：**`av_jni_set_java_vm` 不注册时"解封装正常但播不了"**——logcat 里所有轨道都列出来了，只有视频输出失败。

**验收证据**（真机 logcat）：
```
av_jni_set_java_vm -> 0 (0=成功)
attachSurface: wid=14182 → wid 已设定 = 14182
mpv_initialize 成功，client API 版本=131074
[mpv/vd] Using hardware decoding (mediacodec).
AO: [audiotrack] 44100Hz stereo 2ch float
VO: [gpu] 1920x1080 mediacodec
```
集成测试 `00:06 +1: All tests passed!`

### 2026-10-05 · 第 2 轮 · 文档同步 + 空白屏修复 + 关于页

**A. 文档同步**（决策必须留痕）
- 新增 **ADR 0009**（内核迁移，含替代方案对比与回退条件）
- 重写 [PLAYER-KERNEL.md](PLAYER-KERNEL.md)（含实测证据 + 8 个坑 + 参考项目 GitHub 地址）
- [decisions/README.md](decisions/README.md)：登记 0009；原待办 0009「图片代理」→ 顺延 0010，新增 0014「Media3 会话层」
- [task-board.md](task-board.md)：新增 K3/K4 状态与 CF-P3-KERNEL-004/005/006
- `AGENTS.md`：阶段三 95%→96%、测试数 263→286、Go 93→143、**§6.2 整节重写**为原生 mpv 的坑

**B. 🐛 修复"打开应用白屏"**（两处独立原因，都已修）

> **原因 1（严重）：APK 入口被集成测试污染。**
> `flutter test integration_test/xxx.dart` 会用**测试文件**作为入口重新构建
> `kernel_blob.bin`，并覆盖 `build/app/outputs/flutter-apk/app-debug.apk`。
> 之后安装这个 APK → 启动的是**测试 harness**，不是 `lib/main.dart`：
> Dart VM 正常起来（所以不像崩溃），但 `main()` 的 `debugPrint` 一条都不打，
> 屏幕上什么都不画 → **纯白**。
>
> **判定方法**：`logcat` 里**没有** `[GoCore] 已加载` / `[DB] 就绪` 这两行。
> （正常启动必然有这两行。）
>
> **修法**：装包前必须重新 `flutter build apk`。
> 或在测试后跑一次 `flutter run`（也会重建正确入口）。
> **已写入 AGENTS.md §8.1 作为纪律**。

> **原因 2：启动背景是 Flutter 模板的白底。**
> `res/drawable/launch_background.xml` 是 `@android:color/white`，
> `drawable-v21/` 是 `?android:colorBackground`（浅色主题下=纯白），
> 连 `"Modify this file to customize your launch splash screen"` 注释都还在。
> 实测冷启动截图**纯白占 94.6%**。
>
> **修法**：新建 `values/colors.xml`（`cf_bg=#FF0B1020`），
> 两个 `launch_background.xml` 改为品牌深蓝底 + 居中 `ic_launcher_foreground`，
> 与 Dart 侧 `/splash` 页（`Cf.bg` + `CfLogo`）衔接。

**C. 新增「关于」页**（`lib/pages/about_page.dart`）
- 入口：「我的」页设置组 + 底部版本号（可点）
- 内容：应用介绍 / 技术栈 / 功能 / **开源致谢（带 GitHub 链接与许可）** / 开源许可 / **免责声明**
- 免责声明是**合规必需**：明示"与 Emby Corp.、115、豆瓣无关联"，"不托管任何内容"，
  "115 走非公开接口有风控风险"。这些原本只躺在仓库 `NOTICE` 里，用户看不到。

**D. 图标审查结论**
- ✅ `mipmap-*/ic_launcher{,_background,_foreground}.png` 五档**都是品牌图标**
  （深紫黑底 `#171329` + 蓝紫折带 `#5B8CFF→#9B6BFF`），非模板残留。
  由 `tool/icon/gen_icons.sh` 生成（依赖 Edge headless，本机可用）。
- ❌ **启动背景是模板白底** → 已修（见 B-原因 2）。
- ⚠️ `ic_launcher_foreground.png` 是 **432×432 全幅**（含大量透明），
  用作启动页居中位图时**视觉尺寸偏大**。已按此调整 gravity=center，实测可接受；
  若要更精致，应单独出一张 96dp 的启动图（当前无此资源）。
- ⚠️ 未提供 **Google Play 512×512 商店图**与 **Feature Graphic**（发版前需补）。

**E. 版本号**
- `0.2.0` → **`0.3.0`**（`tool/bump_version.ps1 -Version 0.3.0`，三处同步）
- ⚠️ **`versionCode` 仍是 `1`**：`bump_version.ps1` 只改 semver，**不动 build number**。
  而设备上曾装过 split-release（`2001`），所以装 debug 包需要 `adb install -r -d`。
  → **这是一个待修的缺口**，见 §5。

---

### 2026-10-05 · 第 3 轮 · AI 记忆库 + 开发收尾审查门禁 + 启动页图标修复

**A. 新增 AI 记忆库**（本文件 `docs/AI-MEMORY.md`）
- 用途：**AI 每轮开发前必读、收工后必写**。
- 三块内容：进度快照（§0/§2）· 变更台账（§3，谁改了什么为什么）· 交接（§5，下一步 + 已知缺口）。
- 已接入强约束：
  - `AGENTS.md` 顶部新增「🔴 第 0 步（每轮开发强制）」指向本文件与 `check-dev.ps1`
  - `scripts/check-docs.ps1` 的必需文档清单加入 `docs/AI-MEMORY.md`
    → **删掉或改名会让 docs 门禁失败**

**B. 新增开发收尾审查门禁** `scripts/check-dev.ps1`
一条命令跑完四类检查，**退出码 0 才算过**：
| 段 | 内容 |
|---|---|
| L0-a | `flutter analyze` / `flutter test` / `go vet` / `go test` |
| L0-b | `check-secrets` / `check-docs` / `bump_version -Check`（**看退出码不看输出**） |
| L0-c | `libmpv.so` + `libcineflow_go.so` 的 ELF 头；**APK 入口是否被污染** |
| L0-d | 真机：安装 → 启动 → `[GoCore]`/`[DB]` 日志 → 进程存活 → 无 FATAL |

- 支持 `-Quick`（只跑 a/b）与 `-SkipDevice`；**有跳过项时会在结论里明确列出**，
  逼着汇报"哪些没验证"。
- **反向注入验证过**（这是门禁脚本的硬要求）：
  1. 真跑一次 `flutter test integration_test/...` 制造污染 → 门禁**报红，退出码 1**，
     报 `APK 入口被集成测试污染`；
  2. 重新 `flutter build apk` → 门禁**转绿，退出码 0**。
- 修掉自己两个 bug（都留了注释）：
  · 变量名 `$pid` 撞 PowerShell **只读自动变量** `$PID` → 改名 `$appPid`
  · `[System.Text.Encoding]::Latin1` 在 Windows PowerShell 5.1 里是 `$null` → 改用 `ASCII`

**C. 🐛 修「图标元素未替换」**
- 审查了全部图标资源，结论分两半：
  - ✅ **桌面图标本来就是品牌图标**（非模板残留）：`mipmap-*/ic_launcher{,_background,_foreground}.png`
    五档齐全，深紫黑底 `#171329` + 蓝紫折带 `#5B8CFF→#9B6BFF`，
    由 `tool/icon/gen_icons.sh` 从 `icon_template.svg.frag` 生成（Edge headless）。
  - ❌ **启动页是 Flutter 模板白底**（真问题）：
    `res/drawable/launch_background.xml` = `@android:color/white`，
    `res/drawable-v21/launch_background.xml` = `?android:colorBackground`（浅色主题=白），
    连 `"Modify this file to customize your launch splash screen"` 注释都还在。
- 修法：新增 `res/values/colors.xml`（`cf_bg=#FF0B1020`），两个 `launch_background.xml`
  改为 `cf_bg` 底 + 居中 `@mipmap/ic_launcher_foreground`。
- **实测证据**（冷启动 700ms 截图，像素统计）：
  | | 修复前 | 修复后 |
  |---|---|---|
  | 纯白占比 | **94.6%** | **0.0%** |
  | `Cf.bg` 系占比 | ~0% | **99.2%** |
- ⚠️ 遗留：`ic_launcher_foreground.png` 是 432×432 全幅（含大量透明），
  作启动页居中位图时**视觉尺寸偏大**。要更精致需单独出 96dp 启动图。
- ⚠️ 遗留：无 Google Play 512×512 商店图与 Feature Graphic（发版前需补）。

**D. 版本号** `0.2.0` → **`0.3.0`**（`bump_version.ps1 -Version 0.3.0`，三处同步）
- ⚠️ **`versionCode` 仍是 `1`**（脚本不动 build number）—— 见 §5 待办 #1。

**E. 新增「关于」页**（`lib/pages/about_page.dart`，第 2 轮创建，本轮修好编译错误）
- 入口：「我的」页设置组 + 底部版本号
- 内容：介绍 / 技术栈 / 功能 / 开源致谢（带 GitHub 链接与许可）/ 许可 / **免责声明**
- 修掉：`_open` → `_openUrl` 重命名漏改调用点导致的编译失败

---

### 2026-10-05 · 第 4 轮 · AI 分发规范 + 发布审批门 + 🐛 修复 release.yml 致命语法错误

**A. 🐛 修复 `release.yml` —— 它此前是「跑不起来」的**

`release.yml` 的 **YAML 语法是错的**，GitHub Actions 根本无法解析：

```
yaml.scanner.ScannerError: while scanning a simple key
  in ".../release.yml", line 61, column 9
```

第 61 行 `PW_VER="$(grep -o ...)"` **缩进只有 8 空格**，比同级的 `run: |` 块
少 2 格 → 该行被解析成 YAML 键而非 shell 命令，整个文档解析失败。

- **后果**：这个工作流**从来没有成功运行过**。tag `v0.2.0` 已存在，
  但 Releases 页应当没有对应产物（或只有手工建的）。
- 顺带发现 `sed` 的转义也写错了（`s/.*\'(.*\')'.*/\1/` 在单引号 sed 里不生效），
  即使缩进对了也取不到版本号。
- 修法：整段重写为正确的 10 空格缩进，修好 sed 转义，
  并**补上第三处校验**（`pubspec.yaml`）+ **版本递增校验**。
- 验证方式：用 `yaml.safe_load` 解析全部三个 workflow ——
  修复前 `release.yml` FAIL、修复后三个全 OK（`ci.yml` / `release-notes.yml` 一直没问题）。

> 教训：**workflow 的 YAML 必须能被解析器验证**，不能靠肉眼看缩进。
> 建议后续把 `yaml.safe_load` 检查加进 `check-dev.ps1`。

**B. 新增 AI 分发规范** `docs/AI-DISTRIBUTION.md`
- 用户要求：「上传到 GitHub 不删除原有 Release；每次上传前必须增加版本号且经我审批」
- 落地为 **10 条分发铁律 D1–D10**，核心三条：
  · **D1** 没有用户当轮明确指令，绝不自作主张发版
  · **D3** 绝不删除/覆盖/替换任何已有 Release 或 tag（含预发布与草稿）
  · **D5** 未经审批绝不执行 `gh release create/edit/upload/delete`、`git push --tags`
- 含 **§3 审批单模板**（AI 填好发给用户，等明确"批准"才能继续；
  含糊回复须再问一次，不得自行解释为批准）
- 含 **§4「只增不删」强制性条款**：解释了为什么删旧版是事故
  （旧版本是回滚唯一退路；已分发的 APK 无法召回；校验和会对不上）
  ～ 唯一例外：**draft 转正之前**可改可重跑（对用户不可见）
- 已加入 `check-docs.ps1` 必需文档 → 删掉它文档门禁就红

**C. 新增发布审批凭据工具** `tool/release_ticket.ps1`
把"必须经审批"从**口头约定**变成**机械约束**：

| 动作 | 行为 |
|---|---|
| `-Action status` | 查看凭据（无凭据 = 禁止发版） |
| `-Action approve -Version X.Y.Z` | 签发凭据；**版本号必须与仓库 `VERSION` 一致**，否则拒绝 |
| `-Action consume` | 发版后消费（**一次性**，再发需重新审批） |
| `-Action revoke` | 立即作废 |

- 凭据含**有效期**（默认 2 小时），过期自动失效——避免"批一次用一个月"
- 凭据文件 `.release-approval.json` **已加入 `.gitignore`**（公开仓库不能暴露内部流程状态）
- ⚠️ **诚实说明**：这是**防误操作，不是防恶意**——AI 能自己调用 `approve`。
  它的真实价值是让发版**从一条命令变成一个显式决策步骤**并留下痕迹。
- **实测验证**（含反向注入）：
  · 无凭据 → 显示"禁止发版" ✅
  · `-Version 9.9.9`（与 VERSION 不符）→ **拒绝，退出码 1** ✅
  · `-Version 0.3.0` → 签发成功，状态显示剩余 120 分钟 ✅
  · `consume` → 一次性消费，再查回到"无凭据" ✅
  · 构造过期凭据 → 显示"已过期，禁止发版" ✅
  · `revoke` → 文件消失 ✅

**D. 给 `release.yml` 加两道机械门**
1. **`environment: release`** —— GitHub Environment protection rule，
   配了 Required reviewers 后 `publish` job 会**挂起等人工批准**。
   这是"就算 AI 擅自 push 了 tag 也过不去"的那一半。
   ⚠️ **需要在仓库 Settings → Environments 里启用一次**，否则不生效。
2. **「只增不删」守卫步骤** —— 发布前检查目标 tag 是否**已是已发布 Release**：
   是则直接报错退出，逼着递增版本号；只有**草稿**才允许重跑。
   并把现有 Release 列表打印进日志（留痕）。

**F. 📋 v0.3.0 发布审批单（待用户批准，按 AI-DISTRIBUTION.md §3）**

```markdown
- 版本号：0.3.0（上一版：0.2.0）  build 2
- 是否递增：✅ 是（0.3.0 > 0.2.0；versionCode 1 → 2）
- 三处一致性：bump_version.ps1 -Check 通过 ✅
- 开发门禁：scripts/check-dev.ps1 退出码 0（17 项全过）✅
- 测试：flutter test 286 例全绿 / go test 143 例全绿 ✅
- 真机验证：✅ 已做 —— release 包装机成功、启动无崩溃、UI 正常渲染
              （238,784 色 / 纯白 0.2% / 深色 81%）；versionCode 2002 可正常覆盖安装
- changelog：docs/changelog/v0.3.0.md 已写
              亮点：播放内核换成安卓原生 mpv、修复白屏（两个原因）、新增关于页
- 将创建的 tag：v0.3.0
- 将上传的附件：CineFlow-0.3.0-arm64-v8a.apk (37.97 MB, versionCode 2002)
                + checksums.txt (SHA256 4e5468a5…c27668)
- 已知限制（会写进 changelog）：debug 签名 / 仅 arm64 / 无通知栏与后台播放
- 是否保留全部历史 Release：✅ 是（本操作不删除任何已有 Release）
- 未验证项：播放器整页 UI 走查（画面/手势/弹幕叠加）—— 集成测试只驱动内核
```

**⛔ 未执行**：`git tag` / `gh release create` / `git push` —— 按 D1/D5 等审批。

**E. `check-dev.ps1` 新增两项检查（都被反向注入验证过）**
1. **workflow YAML 可解析性** —— 正是为了防 D 里那类 bug 再次发生。
2. **PowerShell 脚本的 UTF-8 BOM** —— 实测**踩了两次**：用编辑工具改 `.ps1`
   会**丢掉 BOM**，之后脚本被按 GBK 解码、中文行吞掉下一行代码，
   报出一堆 `Missing closing ')'` 的**假语法错误**。
   最坑的是：`check-docs.ps1` 自己坏了，门禁报的却是"不通过"，
   差点被当成业务问题去排查。
   反向注入验证：临时删掉 `check-docs.ps1` 的 BOM → 门禁报红退出码 1 → 还原后转绿。

---

### 2026-10-05 · 第 5 轮 · 产出可发布版本 + 清理垃圾 + 修 versionCode

**A. 修 `versionCode` 不递增（AI-MEMORY 待办 #1，已闭环）**

`bump_version.ps1` 原先只改 semver、**完全不动 build number**，导致 `versionCode` 恒为 `1`。
后果不是"难看"，而是**用户装不上**：设备上装的旧包是 2001，新包 1 更小，
`adb install -r` 报 `INSTALL_FAILED_VERSION_DOWNGRADE`。
我自己可以用 `-d` 强装，**但用户没有 `-d`**，他们只会看到「应用未安装」。

改法：`bump_version.ps1` 新增参数
- `-Build <n>` —— 显式指定 build（校验必须递增）
- `-BumpBuild` —— 只 +1，不动 semver
- `-Version X.Y.Z` —— 换 semver 时 build **自动 +1**（保证一定比上一版大）
- 两者都硬校验 `新 build > 旧 build`，违反直接退出码 1

实测：`-BumpBuild` → `1 -> 2`；构建产物 `versionCode='2002'`（Flutter 的 ABI 编码 = 2000+2）；
**`adb install -r` 不带 `-d` 直接 Success** —— 这条待办闭环。

**B. 产出发布候选（release 产物）**

```
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols
```

| 产物 | 大小 | 说明 |
|---|---|---|
| `app-arm64-v8a-release.apk` | **37.97 MB** | ✅ **发布用这个** |
| `app-armeabi-v7a-release.apk` | 16.95 MB | 无 libmpv（桩构建），实际不可播 |
| `app-x86_64-release.apk` | 21.01 MB | 同上 |

- `versionCode=2002` / `versionName=0.3.0`
- SHA256 `4e5468a541396e051d902f1b6720a96586b2457ce1c07906b540f1068ac27668`
- **内核已验证**：含 `libmpv.so`(11.80MB) + `libcineflow_mpv.so`，
  **零 media_kit 痕迹**（旧 release 包里有 `libmediakitandroidhelper.so`，已删）
- **真机已验证**：安装成功、启动无崩溃、UI 正常渲染（238,784 色 / 白 0.2% / 深色 81%）
- 混淆符号表已重新生成（`build/symbols/`，3 个文件 2.9–3.38 MB）—— **不要删**

> ⚠️ 上一版的 release APK 是 13:10 构建的，**含 `libmediakitandroidhelper.so`，
> 是迁移前的 media_kit 内核**——已删除，避免误当成果分发。

**C. 写了 `docs/changelog/v0.3.0.md`**（Release 正文的事实源）
风格对齐 v0.2.0：标题是「播放内核换成安卓原生 mpv，启动不再闪白屏」，
含亮点 / 其他改进 / 修好了 / **升级须知**（debug 签名 + 仅 arm64 + 换内核的回归提醒）。

**D. 清理垃圾（回收 0.77 GB：5.17 GB → 4.41 GB）**

删除前**逐个列出了绝对路径**核对（见 AGENTS 的删除纪律）：

| 目标 | 大小 | 为什么是垃圾 |
|---|---|---|
| `build/media_kit_libs_android_video` | 246.9 MB | 已移除依赖的构建残留 |
| `build/test_cache` | 235.7 MB | 集成测试缓存 |
| `build/jni` | 24.3 MB | 旧 JNI 中间产物 |
| `build/media_kit_video` | 15.2 MB | 已移除依赖的构建残留 |
| `tool/icon/_gen/profile` | 6.7 MB | Edge headless 的浏览器 profile（256 个垃圾文件） |
| 7 个迁移前 release APK | 246.5 MB | 含 media_kit，会误导 |
| 旧 `build/symbols` | 9.9 MB | 属迁移前那版，重建已生成新的 |

**保留**：`lib/`、`go/`、`docs/`、`android/app/src/main/jniLibs/`（源，非产物）、
新的 `build/symbols/`。

**E. 顺手修 `tool/build_apk.sh`**：注释还写着「media_kit 的 libmpv 三架构库必须靠
`--split-per-abi` 拆出」——依赖早删了，这句话是过时且误导的。
改成说明真实原因（自持的 libmpv.so 只有 arm64），并加了「本脚本只构建不上传，
上传必须经审批」的提示。

**F. 验证**：`check-dev.ps1` **17 项全过、退出码 0**。

**G. ⛔ 未做的事（按分发铁律 D1/D5）**：**没有打 tag、没有创建 Release、没有推送**。
产物已备好，等用户审批。

---

### 2026-10-05 · 第 6 轮 · 深度清理（保留发布 APK）+ 修正两处自己的错误认知

**A. 清理成果：4.66 GB → 0.10 GB**

保留（**成对**，缺一不可）：

| 保留项 | 大小 | 为什么不能删 |
|---|---|---|
| `app-arm64-v8a-release.apk` | 37.97 MB | 发布产物 |
| `checksums.txt` | — | 完整性校验 |
| `build/symbols/*.symbols` | 9.66 MB | **APK 是混淆过的**，没有它用户报的崩溃堆栈就是一堆 `a.b.c` |

新增 **`tool/clean_garbage.ps1`**（带 `-DryRun` / `-KeepDebug`）：
**不复用 `flutter clean`**，因为后者会把 `build/symbols/` 一起删掉——
而那是排查线上崩溃的唯一依据（AGENTS §9 明令保留）。脚本内置保留清单核对，
跑完会打印"保留/缺失"两栏。

**B. 🐛 修正错误一：我误删了 `build/symbols/`**

第一次清理时我按"构建产物都可重建"的直觉删了它，**违反了 AGENTS §9 的明文禁令**。
实测确认这不是洁癖：release APK 里 `CineFlowApp` / `PlayerFacade` /
`about_page.dart` 等符号**全部查不到** → 说明 `--obfuscate` 确实生效，
**没有符号表就无法解析用户崩溃堆栈**。

补救：重新完整构建，使 APK 与符号表**成对匹配**（新 APK SHA256 `72dbced4…`）。
并在 `clean_garbage.ps1` 里把"保留 symbols"写成硬闸 + 事后核对。

**C. 🐛 修正错误二：`debugPrint` 在 release 下**并不会**被剥离**

我在 `check-dev.ps1` 里写了个想当然的注释："release 包看不到 `[GoCore]` 日志，
因为 `debugPrint` 被剥离"。**实测证伪**：

先确认装的确实是 release 包（三重证据）——
`run-as` 报 `package not debuggable`、APK 内**无** `kernel_blob.bin`、**有** AOT `libapp.so`；
然后 logcat 里清楚打着：

```
I flutter : [GoCore] 已加载，ping={pong: cineflow-go, version: 1}
I flutter : [DB] 就绪，清理过期缓存 0 条，现有 1 条 / 30442 字符
```

真正被 release 剥离的是 `assert`，**不是 `debugPrint`**。已改正注释与判定逻辑。

**D. `check-dev.ps1` 适配 release 包**（因为 debug 包已被有意清理）
- APK 选择：优先 debug，缺失则退回 release
- release 包是 AOT、**天然没有 `kernel_blob`** → 入口污染对它不适用，如实报"免疫"而非报警
- 真机安装**不再用 `-d`**：能正常覆盖安装才证明 versionCode 机制是好的，
  用 `-d` 反而掩盖它坏掉。新增对该错误的**专项检测**（报 `VERSION_DOWNGRADE` 则明确指向 `-BumpBuild`）
- release 包增加**截图像素兜底**（>60KB 视为已渲染）

**E. 顺手修 `.gitignore`**：`dist/` 此前**未被忽略**，而 `release.yml` 会把 APK 组装到那里——
一旦误 `git add .` 就会把 30MB 二进制提交进公开仓库（违反分发铁律 D7）。已加。

**F. 验证**：`check-dev.ps1` **18 项全过、退出码 0**；
APK 指纹与 `checksums.txt` 一致；真机安装无需 `-d`、启动无崩溃、界面非白屏。

---

### 2026-10-05 · 第 7 轮 · 清理垃圾（含明文 token）+ 开源参考文档 + ⭐ libmpv.so 溯源


**A. 🔴 删除明文 GitHub token（安全）**

清理时发现 `tool/_gh_token` —— **40 字符、`gho_` 前缀的 GitHub OAuth token，明文未加密**。

先做泄露评估再删（**不打全 token 内容**）：
- ✅ **从未进 git 历史**（`git log --all -- tool/_gh_token` 为空）
- ✅ 未被任何**被跟踪**文件包含（`git grep -F` 无命中）
- ⚠️ 但"文件在磁盘上明文躺着"本身就是风险：任何打包/同步/截图/误 `git add -f` 都会泄露

已删除。**建议你到 GitHub 设置里轮换该 token**（我无法确认它此前是否被其它进程读取过）。

**B. 🐛 发现 `check-secrets.ps1` 的盲区（已补门禁）**

**根因**：该脚本用 `git ls-files`，即**只扫被 git 跟踪的文件**。
而被 gitignore 的路径（`.env`、`*.local`、`tool/_*`）**恰恰是凭据最容易落地的地方**
—— `tool/_gh_token` 正是被 `.gitignore` 的 `tool/_*` 覆盖，所以门禁完全没报。

**补法**：`check-dev.ps1` 新增「明文凭据守卫」，用
`git ls-files --others --ignored --exclude-standard` 拿被忽略的文件，
按 8 类模式扫（GitHub token / fine-grained PAT / AWS AK / OpenAI-DS key /
Slack / Google API key / 私钥块 / JWT）。
**只报文件与类型，不回显匹配内容**（打印等于二次泄露）。

**反向注入验证**：造一个含伪造 `gho_` 的 `tool/_probe_creds.txt`
→ 门禁**报红退出码 1** 并准确指出文件名与类型 → 删除后**转绿**。

**C. 清理垃圾：0.19 GB → 0.10 GB**

| 目标 | 说明 |
|---|---|
| `tool/_gh_token` + `_jl*.txt` + `_joblog.txt` + `_tree.json` | 临时凭据与抓取产物 |
| `build/test_cache`(80.9MB) · `unit_test_assets` · `native_assets` | 测试缓存 |
| `android/app/.cxx` · `.idea` | native 构建缓存、IDE 残留 |

**保留**：`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`(37.97MB) +
`checksums.txt` + `build/symbols/`（**成对，勿删**）。

**D. 新增 `docs/OSS-REFERENCES.md`（开源参考项目清单）**

按「用在哪一层」组织（内核 / Emby / 115 / 弹幕 / 基础依赖 / 作废），
写清**具体借鉴点**与「能不能抄」。汇总全仓 **39 个 GitHub 引用**。

当日实测核实 4 个新参考：
| 仓库 | stars | 许可 |
|---|---:|---|
| `mpv-android/mpv-android` | 3604 | MIT |
| `androidx/media` | 3022 | Apache-2.0 |
| `Predidit/canvas_danmaku` | 41 | MIT |
| `jarnedemeulemeester/libmpv-android` | 69 | MIT |

**E. ⭐ `libmpv.so` 溯源（此前文档从未记录，我从二进制里挖出来了）**

方法：扫描 `.so` 内的字符串。**证据链**：

```
# 内嵌的 mpv configure 参数
--disable-gpl --disable-nonfree --enable-version3 --enable-static --disable-shared
# 内嵌的 CI 构建路径
/home/runner/work/libmpv-android-video-build/libmpv-android-video-build/buildscripts/prefix/arm64-v8a/crossfile.txt
```

**由此确定三件事**：

| 项 | 结论 | 依据 |
|---|---|---|
| **许可** | **LGPL-3.0**（**不是 GPL**） | `--disable-gpl` + `--disable-nonfree` + `--enable-version3` |
| 来源 | GitHub Actions 上名为 `libmpv-android-video-build` 的仓库 | 内嵌 `/home/runner/work/<repo>/` 路径 |
| 形态 | 单文件自包含 | `--enable-static` + `DT_NEEDED` 仅系统库 |

> ⚠️ **未 100% 锁定是哪一个**：同名仓库 GitHub 上有 **9 个**（多为 fork）。
> 按路径与"单文件自包含"形态，**最可能是 `media-kit/libmpv-android-video-build`**（18★）。
> **发布前应向该仓库确认**，或直接在 `NOTICE` 里按 LGPL-3.0 履行义务。

**对 `NOTICE` 的直接影响**：现有表述"以动态链接方式随 media_kit 分发"**已过时**
（media_kit 已移除）。正确表述应为：**本产品包含 LGPL-3.0 的 libmpv（动态链接），
用户有权获取其源代码**。→ 这使 `NOTICE` 待修项从"文案问题"升级为**合规问题**。

**F. 否掉一个假设**：工作区外的 `_mpvsrc/`（45.6MB）含 `libmpv-1.0.0.aar`
（包名 `dev.jdtech.mpv`）与 mpv-android 源码 —— 是**调研素材，不是**本项目 `.so` 的来源
（实测 SHA256 与体积均不同：AAR 内 6,477,048 vs 项目 12,369,680）。

---

## 4. 工作区状态（未提交）

截至本文件更新时 `git status`（**约 54 项**，含第 8 轮的 UI 改造）：

**第 8 轮 UI 改造涉及的源文件**（全部已 analyze/test/真机验证通过）：
`lib/core/theme.dart` · `lib/widgets/media_cards.dart` ·
`lib/pages/{home,rank,profile,detail,login,playback_settings}_page.dart` ·
`lib/player/player_page.dart` · `lib/pan115/pan115_browser_page.dart`

**第 8 轮新增文档**：`docs/DEVELOPMENT-PLAN.md` · `tool/gen_plan_docx.py` ·
`docs/AI-MEMORY.md`（本文件）

**早先轮次留下的未提交项**：`AGENTS.md` · `android/app/build.gradle.kts` ·
`MainActivity.kt` · `launch_background.xml`(×2) · `docs/PLAYER-KERNEL.md` ·
`docs/decisions/README.md` · `docs/review-checklist.md` · `lib/main.dart` ·
`lib/pan115/pan115_player.dart` · `lib/pages/profile_page.dart` · `pubspec.yaml` ·
`VERSION` · `scripts/check-docs.ps1` 等

**新增（未跟踪）**：`android/app/src/main/cpp/` ·
`android/app/src/main/jniLibs/arm64-v8a/libmpv.so`（12,369,680 B）·
`android/app/src/main/kotlin/com/cineflow/app/player/` ·
`docs/decisions/0009-native-mpv-kernel.md` · `integration_test/` · `patrol_test/` ·
`lib/player/{kernel,player_facade}.dart` · `lib/player/native/` ·
`lib/pages/about_page.dart` · `scripts/check-dev.ps1` · `docs/PROJECT-STATUS.md`

**基线**：`master` 分支，4 次提交，最新 `5dd1389`，tag `v0.2.0`。

> ⚠️ 累计改动**尚未 commit**。接手时先 `git status` / `git diff` 复核，
> **不要覆盖别人的未提交改动**（AGENTS §10.5）。
> 第 8 轮开工前我已用 `git stash push -u` → `stash pop` **验证过回滚点可用**。

---

## 5. 交接：下一步该做什么

### ✅ 已完成并验证
- 内核迁移 K0–K4 + **真机集成测试 1 passed**
- 空白屏两处原因定位并修复（APK 入口污染 + 启动页白底）
- 启动页改为品牌深蓝（实测纯白 94.6% → **0.0%**）
- 关于页（含免责声明与开源致谢）
- 图标审查：桌面图标本来就是品牌图标；启动页是模板白底（已修）
- **AI 记忆库 + `check-dev.ps1` 审查门禁**（反向注入验证过）
- 文档五件套同步（ADR / PLAYER-KERNEL / 看板 / AGENTS / review-checklist）

### ⏳ 待办（建议顺序）

| # | 事项 | 为什么 | 关键点 |
|---|---|---|---|
| 1 | ~~修 `versionCode` 自增~~ | ✅ **第 5 轮已闭环**：`bump_version.ps1` 支持 `-Build` / `-BumpBuild`，实测 `adb install -r` 无需 `-d` | — |
| 2 | **真机走查播放器整页** | 集成测试只驱动内核，**没走 UI** | 需登录后点进播放器，看画面/手势/弹幕叠加 |
| 3 | **K3 Media3 会话层** | 通知栏/后台/耳机键都没有 | 见 `CF-P3-KERNEL-004`；音频焦点必须自研 |
| 4 | **提交本轮改动** | 30+ 项未提交，回滚点缺失 | 先跑 `check-dev.ps1`，再 commit |
| 5 | 片源回归（4K DV / PGS） | 迁移的唯一验证缺口 | `CF-P3-KERNEL-005` |
| 6 | 启动图单独出 96dp 资源 | 现用 432×432 全幅 foreground，居中显示偏大 | 见 §3 第 3 轮 C 的遗留 |
| 7 | **配置 GitHub `release` 环境** | `release.yml` 的审批门**还没启用**，现在是空转的 | Settings → Environments → 新建 `release` → Required reviewers 选自己 |
| 8 | **确认 Releases 页状态** | `release.yml` 此前**语法错误、从未成功运行过**；`v0.2.0` tag 存在但可能没有对应 Release | 需人工到 GitHub 看一眼实际有什么 |
| 9 | **审批并发布 v0.3.0** | ⛔ 产物已备好（37.97 MB / versionCode 2002 / 已真机验证），**等用户审批** | 见下方「发布审批单」 |

### 🚧 已知缺口（别当成已完成）
- **播放器 UI 未视觉验证**：画面是否真出图、手势、弹幕叠加——**没看过**。
- **115 未联调**：无真实账号。
- **关于页未在真机点开验证**：代码已编译进 APK（`about_page.dart` 在 kernel_blob 里，
  已用门禁确认），但**没有人实际点进「我的」→「关于」看过渲染效果**；
  且未登录时「我的」页无入口。
- **启动页修复只验证了冷启动一帧**：用像素统计确认 700ms 时是 `Cf.bg`（非白），
  但没有逐帧确认整个启动过程无闪烁。
- **Play 商店素材缺失**：512×512 图标 + Feature Graphic。
- **发布审批门尚未真正生效**：`environment: release` 需要用户去 GitHub 配置
  Required reviewers；`release_ticket.ps1` 是**防误操作不是防恶意**
  （AI 能自己调 `approve`）。真正的把关是 §3 审批单 + 人的确认。
- **`v0.2.0` 的 Release 状态未知**：因为 `release.yml` 一直是坏的，
  需人工确认 GitHub 上到底有没有这个 Release、有没有附件。

---

## 6. 关键坑速查（详细版在 AGENTS §6）

### 6.1 ⚠️ 最坑：测试框架污染 APK 入口（**两个变体**）

```
flutter test integration_test/xxx.dart   # ← 变体 1：入口变成测试文件
flutter test patrol_test/xxx_test.dart   # ← 变体 2：入口变成 patrol_test/test_bundle.dart
flutter build apk --debug                # ← 必须重新构建才能恢复 lib/main.dart 入口
```
**症状**：装上后白屏/停在无关界面、logcat 无 `[GoCore]`/`[DB]`。

> **第 8 轮实测踩到变体 2**：设备上的 debug APK 入口是 `patrol_test/test_bundle.dart`，
> 应用**根本没进 `main()`**。当时差点误判成"UI 崩了"。

**自动防护**：`scripts/check-dev.ps1` 的 L0-c 会检出（已反向注入验证）。
判据是**应用页面文件在不在 kernel_blob 里**——不能只看有没有 `main.dart`，
因为污染包**也有**（实测踩过这个误判）：

| 样本 | size | `about_page.dart` | `player_kernel_test` | 判定 |
|---|---|---|---|---|
| 干净 | 110,452,864 | ✅ | ❌ | OK |
| 污染 | 74,630,792 | ❌ | ✅ | **BLOCK** |

> **第 8 轮的干净包实测**：kernel_blob **110,465,328 B**、含 `about_page.dart`、
> **不含** `test_bundle` → 判定干净 ✅

### 6.2 播放内核（详见 PLAYER-KERNEL.md §4）
- `av_jni_set_java_vm` 不注册 → **解封装正常但播不了**（轨道全列出来，只有 VO 失败）
- `wid` 必须在 `mpv_initialize` **之前**设
- Surface 必须 `NewGlobalRef`；事件线程先 join 再 `mpv_terminate_destroy`
- `#if CINEFLOW_HAS_MPV` 不能写 `#ifdef`（CMake 传 `=0` 也算"已定义"）
- 跨 ABI 链接：`JNI_OnLoad` 里的 `av_jni_*` 也要包 `#if`（**只构建 arm64 验证不出**）
- Flutter 纹理 id **从 0 开始**（断言 `>0` 是错的）

### 6.3 环境
- Flutter `D:\dev\flutter\bin\flutter.bat`；Go `C:\Program Files\Go\bin\go.exe`（**不在 PATH**）
- Android SDK `D:\dev\android-sdk`；NDK `28.2.13676358` / `27.0.12077973`
- 门禁必须带 `-NoProfile -ExecutionPolicy Bypass`
- **不要跑 `dart format`**（会改 24/26 文件）
- MIUI 装包若报 `INSTALL_FAILED_USER_RESTRICTED`：`adb install -r -d`；
  必要时临时 `settings put global verifier_verify_adb_installs 0`（**用完记得还原**）

---

## 7. 每轮开发的固定流程

### 开始前
1. **读本文件**（§0 快照 → §3 台账 → §5 交接）
2. `git status` 看工作区是否干净；不干净先确认是自己还是别人改的
3. 读 [AGENTS.md](../AGENTS.md) §6（坑）/ §7（缺陷台账）/ §9（禁止事项）
4. 确认要改的区域在 §7 缺陷台账里是否有记录

### 开发中
5. 架构决策 → 写 ADR；新坑 → 写进 AGENTS §6
6. 纯逻辑改动**补单元测试**（"点了没反应"型缺陷静态分析发现不了）

### 结束前（**必须全过**）
7. 跑 [docs/review-checklist.md](review-checklist.md) 的 **L0 自动门禁**：
   ```bash
   flutter analyze                                    # 0 error / 0 warning
   flutter test                                       # 全绿（当前 286 例）
   (cd go && go vet ./... && go test ./...)           # 全绿（当前 143 例）
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-secrets.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-docs.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File tool/bump_version.ps1 -Check
   ```
   ⚠️ **看退出码，不看输出尾部**（失败时会打印"补救指引"，看着像正常收尾）。
8. **真机功能测试**（改了哪段走到哪段）：
   ```bash
   flutter build apk --debug --target-platform android-arm64   # ← 必须先重建！
   adb install -r -d build/app/outputs/flutter-apk/app-debug.apk
   adb shell am start -n com.cineflow.app/.MainActivity
   # 必须能看到这两行 Dart 日志：
   adb logcat -d | Select-String 'GoCore|\[DB\]'
   adb shell pidof com.cineflow.app                            # 存活
   ```
   改了播放内核 → 追加 `flutter test integration_test/player_kernel_test.dart -d <id>`
9. **更新本文件**（§2 进度 / §3 台账追加本轮 / §4 工作区 / §5 交接）
10. 按 AGENTS §8.3 汇报：**改了什么文件 + 实测输出 + 验证了哪几步 + 未验证的部分与原因**

---

## 8. 变更日志

| 日期 | 轮次 | 变更 |
|---|---|---|
| 2026-10-05 | 建立 | 首版：内核迁移台账 + 空白屏修复 + 关于页 + 图标审查 + 固定工作流 |
| 2026-10-05 | 第 3 轮 | 新增 AI 记忆库本体 + `check-dev.ps1` 审查门禁（反向注入验证）+ 启动页白底修复（94.6%→0% 纯白）+ 版本 0.3.0 + 图标审查结论 |
| 2026-10-05 | 第 4 轮 | 新增 `docs/AI-DISTRIBUTION.md`（分发铁律 D1–D10 + 审批门 + 只增不删）+ `tool/release_ticket.ps1`（审批凭据）+ **修复 `release.yml` 致命 YAML 语法错误**（该工作流此前从未成功运行）+ workflow YAML 与 PowerShell BOM 两项门禁检查 |
| 2026-10-05 | 第 5 轮 | **产出发布候选**（arm64 release APK 37.97 MB / versionCode 2002 / mpv 内核 / 已真机验证）+ 写 `docs/changelog/v0.3.0.md` + **修 versionCode 不递增**（`bump_version.ps1` 加 `-Build`/`-BumpBuild`，实测 `adb install -r` 无需 `-d`）+ 清理垃圾 **回收 0.77 GB** |
| 2026-10-05 | 第 6 轮 | **深度清理 4.66 GB → 0.10 GB**（只保留 arm64 release APK + 配套混淆符号表）+ 新增 `tool/clean_garbage.ps1`（`-DryRun` + 硬闸保护 symbols）+ **修正两处自己的错误认知**（误删 symbols；误以为 release 剥离 `debugPrint`）+ `check-dev.ps1` 适配 release 包（18 项全过）+ `.gitignore` 补 `dist/` |
| 2026-10-05 | 第 7 轮 | 删明文 GitHub token（**建议用户轮换**）+ 补 `check-secrets` 盲区（改用 `--others --ignored` 扫被忽略文件）+ `docs/OSS-REFERENCES.md` + `libmpv.so` 溯源（LGPL-3.0） |
| 2026-10-05 | 第 8 轮 | **① 开发计划书**（`docs/DEVELOPMENT-PLAN.md` 317 行 + `tool/gen_plan_docx.py` 831 行 + Word 产物）<br>**② UI 大改造**：修 Patrol 污染的 APK（应用此前根本没启动）· 对比度审计（10 项不达标 → `text3` 修为 4.56:1）· **补齐 15 项主题配置** · **修 8 处「切主题不变色」硬编码**（含输入框焦点边框）· **排版 22 个字号 → 9 档**（103 处）· 新增 `CfEmptyView` · Android Studio 真机调试验证 |
| 2026-10-05 | 第 9 轮 | **UI 设计参考落地**（Best-Flutter-UI-Templates + LinPlayer）：修 **5 处「可点区域过小」的真缺陷**（最小仅 16×16，为 48dp 标准的 1/9）· 首页轮播改**按屏高比例**（原写死 270dp）· 海报网格改**按可用宽度算列数**（原写死 3 列）· `docs/OSS-REFERENCES.md` 新增 §5.5 UI 设计参考（**标注 LinPlayer 为 AGPL-3.0 不可抄码**、其 `DESIGN.md` 实为 Apple 官网分析不适用） |
| 2026-10-05 | 第 10 轮 | **文档体积治理**（`mp-writing-for-agents` 方法）：`AGENTS.md` 曾达 **71,064 字节 > 65,536 预算**（超出的部分会被截断、代理读不到）→ 外移 §4 目录地图到 `docs/DIRECTORY-MAP.md`、§6.4.1 细节到 `docs/UI-DESIGN.md`，主文件只留指针，**降到 61,644 字节（留 3,892 余量）**；两份新文档登记进 `check-docs.ps1` 必需清单 |
| 2026-10-05 | 第 11 轮 | **播放器整页走查**（计划书第 2 步，此前从未有人看过）→ **发现并修掉 3 个真实缺陷**：<br>**① `isPlayable` 口径不一致**（Dart 是 `Movie‖Episode`，Go 是 6 种含 `Series`）→ 用户库"最近添加"全是剧集，被过滤成 **1 条**，首页出现 **940px 空白带（占屏 39%）**；修后内容占屏 **42% → 72.5%**<br>**② `getLatest` 自相矛盾**：服务端请求 `IncludeItemTypes=Movie,Episode` 却在客户端用 `isPlayable` 复筛（口径不同 → 双重削减）。实测对比：不带类型 = 24 条，带 = 1 条<br>**③ 剧集点「立即播放」必然失败**：实测 `Series` 的 `PlaybackInfo` 返回 **HTTP 500**（无 MediaSources）→ 按钮改为「选集播放」并滚到分集区<br>另修：播放失败 `catch (_)` **吞掉真实异常**（不打日志不显示原因）· 播放器 `_glassCircle` 命中区仅 ~18dp（套 48dp 透明命中区）<br>**真机验证**：4K HEVC 硬解 · `VO: [gpu] 3840x2160 mediacodec` · **Drop 0** · 横屏 `ROTATION_90` · 播放→返回 **pid 存活无崩溃** |
| 2026-10-05 | 第 12 轮 | **图标美化 + 按键可用性审查**（用户指定）：<br>**① 按钮审查**（56 文件 / 128 处可交互回调）：空实现 0 · 死按钮 0 · 命中区过小 0；**发现「做好了却没接上」1 处** —— `HistoryPage` 早已实现，但**没注册路由**、首页「继续观看 → 全部 ›」还弹「即将推出」→ 已补 `Routes.history` + 真跳转<br>**② 修 `showComingSoon` 误用**：收藏失败/看过失败本用它报错 → 用户以为"功能没做"（其实做了只是失败），且真实原因被 `catch (_)` 吞掉 → 改 SnackBar + 真实原因 + 日志<br>**③ 图标尺寸收敛 15 值 → 4 档**（16/20/24/40）<br>**④ 新增 `CfIconBadge` 统一图标徽章**（原先各页手写 29×29 vs 30、radius 8 vs 10、alpha .15 vs .18）<br>**真机验证**：底部三 Tab + 我的页设置项 + 返回键，**页面指纹**证明点击有效且返回精确回原页 |
| 2026-10-05 | 第 13 轮 | **用户反馈的 6 项 UI/交互问题**（逐项定位根因后修复）：<br>**① 启动闪烁**：`launch_background.xml` 用的是 `@mipmap/ic_launcher_foreground`（自适应前景，实测 **88% 是透明安全区**，内容仅 142×168 / 324×324）→ 启动屏画的是"又小又偏"的 logo，与 Dart `CfLogo` 不一致；同时 **Android 12+ 未声明 `windowSplashScreen*`** → 系统回落用 `android:icon`，与 Flutter 侧**两次绘制内容不同** = 闪烁。已补 `values-v31/styles.xml`（`postSplashScreenTheme` 需 androidx 依赖，实测不写）<br>**② 播放闪红**：错误面板原是**整圈 danger 红描边**，深色画面上刺眼 → 改 Material 风格（中性面板 + 红色仅 20px 图标）<br>**③ 图标未替换**：`CfLogo` 是**自绘**（渐变方块+文字 C），与用户的 `icon.png` 不是同一个东西 → 改为直接渲染 `assets/icon.png`（1x/2x/3x），**桌面图标 / 启动屏 / 应用内三处同源**<br>**④ 剧集详情页**：用户要「播放」不要「选集」→ 主动作改回**真起播**（下钻分季→分集→续播集）<br>**⑤ 播放器按键**：`_ctrlBtn` 高度仅 **32dp** 且裸 `GestureDetector`（**无按压反馈** = "点了没用"的观感来源）→ 套 48dp 命中区 + `InkWell`<br>**⑥ 弹幕对照 B 站**：新增**类型开关**（滚动/顶部/底部）· **速度** · **加粗** · **防挡字幕**；并修 **2 个真实 bug**：`speed` 未接进 `effectiveScrollDuration`（改了不生效）· Painter 缓存 key **缺 fontWeight**（加粗对已缓存弹幕无效）<br>**新增** `test/brand_logo_test.dart` 3 例 |
| 2026-10-05 | 第 14 轮 | **播放器交互修复**（用户连续 4 条反馈）：<br>**① 「选集」按钮"消失"** —— 诊断日志证明 `eps=34` 数据正常，**真因是横向溢出被裁**：底部控制行塞 7 个按钮，`Row` 无滚动也无 `Flexible`，超出部分直接画到屏幕外；上一轮我把命中区 32→48dp、图标 16→20 让每个按钮变宽，**加剧了溢出**。修法：选集**固定在左侧始终可见** + 其余按钮进横向滚动区<br>**② 快进/后退"没用"** —— 原来那两个键根本不是快进/快退，而是**上一集/下一集**（`skip_previous`/`skip_next`），且带 `eps != null && _index > 0` 守卫，从首页「继续观看」进入时 `episodes` 为 null → 两键**直接禁用**。按用户要求改为 **±10s**（`PlayerPage.kSeekStepSeconds`），不依赖 episodes<br>**③ 长按倍速** —— 原实现硬编码 2.5x 且有 bug（`_rate == 2.5 ? 1.0 : _rate` 在常速本身是 2.5x 时会误重置为 1.0x）；改为**可选档位**（1.5/2/2.5/3，默认 2x，存 `hold_speed`）+ 独立 `_holdingSpeed` 标志 + 长按期间不自动隐藏控制层<br>**④ 剧集进度** —— `Series.UserData` 实测恒为 `Played=false, PositionTicks=0`（进度在 Episode 上）→ 新增 `SeriesProgress.resolve` 纯函数（有未看完→续播最小集号；看完了→下一集；全新→第一集）+ `UnplayedItemCount` 解析；按钮显示**「继续播放 第 5 集」**（真机验证文案正确）<br>**⑤ 字幕字体** —— 真机日志 `[mpv/sub/ass] can't find selected font provider` → 补 `sub-fonts-dir=/system/fonts`、`sub-font`、`sub-codepage`<br>**新增** `test/series_progress_test.dart` 13 例（含反向注入验证）+ `sort_and_prefs_test.dart` 增 5 例 |
| 2026-10-05 | 第 15 轮 | **控制条按"是否有可选择性"显隐 + 轨道名可读化**（用户 3 条反馈）：<br>**① 用户规则**："如果存在唯一性那就可以隐藏，如果有可选择性那就可以显示" → 提取成 **3 个 public static 纯函数**（`showEpisodeButton` 需 >1 集 / `showSubtitleButton` 需 ≥1 条——因为字幕有"关闭"这个选项 / `showAudioButton` 需 ≥2 条——音轨没有"关闭"）。**两处判据故意不同**，有专门测试守住这个不变量<br>**② 轨道名可读化**：用户要"多音轨多字幕时显示出名称，像字幕有中字、双语、繁体等"。根因是**解析层只取了 `id`/`title`/`lang`，把 mpv `track-list` 的其它字段全丢了** → 实测某片 **3 条音轨 title 全为空**（`aac 2ch` / `6ch` / `eac3 6ch`），界面上是 3 条一模一样的「音轨 开」。补 `codec`/`demux-channels`/`default`/`external`/`forced`，新增 `KernelTrack.displayName`（语言码归一化 `chi`→中文 + 声道数人话化 + codec + 标记，且避免"简体中文 · 中文"重复）<br>**③ 跳片头移出控制条**：它是"设置一次就不再改"的偏好，放播放中控制条只是噪音 → 控制条移除（自动跳过逻辑不受影响），搬进「我的 → 播放设置」；同时把**长按倍速**也移进设置页<br>**新增** `test/track_display_test.dart` 19 例（含"三条轨道必须得到三个不同名字"的不变量） |
| 2026-10-05 | 第 16 轮 | **用户指出致命问题：「这些东西本来你应该能够从 emby 服务端全部拿到」—— 核实成立，系统纠正**（两个并行调研：Emby 官方 swagger 字段级研究 + 本仓库数据面审计）：<br>**① 删掉自写推断 91 行** —— `SeriesProgress.resolve`（遍历分集 `UserData` 猜"看到第几集"，2 次请求）→ 改用服务端 **`GET /Shows/NextUp?SeriesId=`**（**1 次请求**，实测返回 S1E9/E10/E11）。旧实现与旧测试一并删除，新增 `test/nextup_contract_test.dart`（**编译期守护**：删掉接口方法则 analyze 必红）<br>**② `MediaStream` 字段 9 → 25 个**（官方 swagger 确认共 56 个）—— 补 `Index`/`Title`/`ChannelLayout`/`IsForced`/`IsExternal`/`IsHearingImpaired`/`BitRate`/`SampleRate`/`Profile`/`Level`/`ExtendedVideoType`/`IsTextSubtitleStream` 等；新增 `MediaStream.label`（**优先用服务端 `DisplayTitle`**，实测服务端给 `Chinese Simplified (PGSSUB)`/`Mandarin EAC3 5.1 (默认)`，比我自拼的 `立体声 · aac` 好得多）<br>**③ ⚠️ 修正一处会「切错轨」的错误**：我曾把 `MediaStream.Index` 注释成"mpv `aid`/`sid` 的对照键"—— **错的**。Emby `Index` 是 ffmpeg **全局**流索引，mpv `aid`/`sid` 是**每类型独立从 1 编号**；同源的只有 mpv `track-list[].ff-index`。已补 `KernelTrack.ffIndex` 并改注释<br>**④ 实测推翻旧注释：「Emby 无原生片头检测」是错的** —— 本服务器 `ChapterInfo.MarkerType` 实测给出 `IntroStart@0s → IntroEnd@128s`；旧实现靠猜章节名含"片头"/"intro"，会**漏检**（"主题曲"/"OP"）且**误检**（"片头曲欣赏" → 跳过正片）。改为**优先 MarkerType，名称匹配降级为兜底**<br>**⑤ 省一次请求**：章节随 `PlaybackLaunch.chapters` 带来（服务端把章节放在 `MediaSources[].Chapters`），不再单独 `getChapters()`<br>**⑥ 修 2 处审计发现的回归**：`Studios` 的**非空断言**（违反 §5.3，会让整个详情页崩）→ `.whereType<>()`；"已看完"写死"重播**第 1 集**"→ 按 `unplayedItemCount==0` 区分，**重播最后一集**<br>**⑦ `RequiredHttpHeaders` / `defaultAudioIndex` 已透传**（`PlaybackLaunch` 新增字段，内核 `open` 早已支持 headers）<br>**新增** `test/intro_marker_test.dart` 8 例（含"名称匹配漏检/误检"两组对照）<br>**未采纳**（实测本服务器不支持）：`GET /Years` → **500**（保留双探针）、`GET /MediaSegments` → **404**（那是 Jellyfin 的 API） |
| 2026-10-05 | 第 17 轮 | **轨道对齐收官：把服务端轨道与内核轨道真正接起来**（承接第 16 轮审计指出的"数据层已就绪但消费层没接"）：<br>**① 新增 `lib/player/track_aligner.dart`** —— `TrackAligner.alignAudio/alignSubtitle` 用 **`ff-index`** 把服务端 `MediaStream` 与内核 `FacadeTrack` 对齐，产出 `AlignedTrack{kernelId, label, isDefault}`（= **服务端的好名字 + 内核的可执行 id**）。三级降级：精确 `ffIndex==Index` → 同类型顺序（跳过已占用）→ 内核信息兜底<br>**② 实测证明这条对齐不可省** —— 本服务器《刘阳的决心》：音轨 `Index=1/2/3` 与 `aid=1/2/3` **碰巧相同**，但**字幕 `Index=4` 而 `sid=1`** → 若用 `id` 匹配，`DefaultSubtitleStreamIndex=4` 会去找 `sid=4`（不存在），**字幕永远切不上**<br>**③ `ffIndex` 全链路打通** —— `KernelTrack.ffIndex`（解析 mpv `track-list[].ff-index`）→ `FacadeAudioTrack/SubtitleTrack.ffIndex` → `TrackAligner`<br>**④ 接上"死字段" `defaultAudioIndex`/`defaultSubtitleIndex`** —— 新增 `_applyServerDefaultTracks`：起播后**轮询等内核 `track-list`**（最多 3s；因为 `openUrl` 返回时轨道还没到，直接查会静默失败）再按对齐结果切轨。此前这两字段**零消费**，起播全靠 mpv 自己选（可能与服务端不一致）<br>**⑤ 弹层显示服务端名字** —— 音轨/字幕弹层改用对齐结果（如 `Chinese TRUEHD 5.1 (默认)`），默认轨加 `✔ 默认` 标记；内核自拼降级为兜底<br>**新增** `test/track_aligner_test.dart` **13 例**（含"用 id 会张冠李戴"的对照实验 + 条数/唯一性/非空三项不变量）<br>**顺带修**：`UI-DESIGN.md` §4 标题与表格被上轮误并成一行 |
| 2026-10-06 | 第 18 轮 | **v0.3.0 / v0.3.1 两次发布：正式签名 + 三 ABI 完整包**（用户指令："配置正式签名并生成，发布安卓的三个适配版本"）：<br>**① 发现 v0.3.0 的 APK 是 debug 签名** —— 实测下载附件含 `Android Debug`，且**已被下载 3 次**。根因：`flutter build apk --release` 在找不到签名配置时**静默回退 debug 签名**（只告警、退出码仍 0）→ **"构建成功" ≠ "可发布的包"**<br>**② 生成正式签名** —— RSA-4096 / 30 年 / PKCS12。⚠️ **PKCS12 要求 storePassword == keyPassword**（我首次故意用两个不同口令，JKS 允许但 PKCS12 不允许 → `KeytoolException: Given final block not properly padded`）<br>**③ keystore 放仓库外** —— `%USERPROFILE%\cineflow-keystore\`（物理上不可能被 `git add`）；CI 侧进 GitHub Secrets（base64 + 4 项）<br>**④ 三个 ABI 从"空壳"变"真能用"** —— 实测 v0.3.0 的 v7a/x86_64 包**缺 `libmpv.so` 与 `libcineflow_go.so`**：能装能开能浏览，**一点播放就报错**（`MPVLib.init` 抛 `UnsatisfiedLinkError`）。补齐 6 个原生库。**三 ABI 的 libmpv 同源**：从 `media_kit_libs_android_video` 的 jar 提取，并与仓库原 arm64 库**逐字节校验一致**（sha256 `adf83fde...`）—— 注意 `mpv-android` 官方构建**不是**同源（它 ffmpeg 动态链接且**不导出 `av_jni_set_java_vm`**，直接用会挂）<br>**⑤ 发布暴露 5 个独立缺陷**（详见 `AI-DISTRIBUTION.md` §7）：<br>&nbsp;&nbsp;· 仓库 Actions 默认权限 `read` → `gh release create` 必失败<br>&nbsp;&nbsp;· `GET /releases/tags/<tag>` **对草稿返回 404** → 每次重跑新建草稿<br>&nbsp;&nbsp;· `publish` job **缺 checkout** → changelog 从未被用作正文<br>&nbsp;&nbsp;· `upload-artifact` 多根路径 → artifact 内带 `dist/` 前缀 → 下载后 `dist/dist/*.apk` → 通配匹配不到<br>&nbsp;&nbsp;· **`gh release upload` 无法操作草稿**（它按 tag 解析，而草稿的 tag 端点 404；传 id 也被当 tag）→ 改走 **REST assets 端点**<br>**⑥ 新增 `tool/verify_signing.ps1`** —— 机械判定"是否 debug 签名"（DN + v2/v3），可进 CI；`release.yml` 加签名守卫，**发不出 debug 包**（D10）<br>**⑦ 真机终验**（装**从 GitHub 下载的**发布包，非本地构建）：arm64 → `versionName=0.3.1`、`[GoCore] 已加载`、无崩溃；v7a → `primaryCpuAbi=armeabi-v7a`、`[CineFlowMPV] mpv_initialize 成功`（补齐库之前是"未加载"）<br>**⑧ v0.3.1 移动 tag 4 次** —— 属 **D4 的明确例外**（该 tag **从未产出任何附件、0 下载**），用户当轮知情授权；边界已写入 `AI-DISTRIBUTION.md` §7.2（**仅适用于"从未分发过"的 tag**）。v0.2.0 / v0.3.0 操作前后均核对未动<br>**未做**：115 联调（无账号）、Media3 会话层、401 自愈 |
| 2026-10-06 | 第 19 轮 | **灰屏修复真正生效 + 地址识别真机验证 + 一处安全红线泄露（未推送即拦下）**（用户给出 `docs/local/UI-ADAPTATION-AUDIT.md` 与两个待办）：<br>**① 🚨 安全红线：真实服务器 IP 已被提交** —— `8084980` 的注释里有 `<服务器IP>:8096`（登录页 + 两个补丁脚本）。红线明令禁止"私密地址"入库。**关键判断：该提交尚未推送**（远端 master 仍是 `a3dfcd8`）→ 在推送前**重写历史脱敏**（IP → `emby.example.com`），真实地址**永不进入公开历史**。做法：`git reset --soft` 回退 → 脱敏 → 按原范围重建两个提交 → 删备份分支 → `reflog expire` + `gc --prune=now`<br>**② `check-secrets` 有"公网 IP"盲区**（这才是①能溜过去的原因）—— 原规则**只认私有网段**（`10.`/`192.168.`/`172.16-31.`/`127.`），公网 IP 直接放行。新增两条规则（带 scheme 的公网 IPv4、裸 `IP:端口`），排除 RFC 5737 文档网段与回环/保留段。**反向注入验证**：10 个样本（4 正 6 负）全符合预期，且**不误报** `4.10.0.40`（Emby 版本号）；门禁一度**命中自己的注释**（自命中），已修<br>**③ 灰屏修复此前没覆盖主场景**（两个独立缺口）：<br>&nbsp;&nbsp;· `_armStartTimeout()` 原先**只在 `_playEpisode`（换集）**里调用，而**首次进播放器走 `_start()`** —— 最常走的路径没有超时保护 → 现在 `_start` / `_playEpisode` / `_reopenAs` **三处都布防**（`_reopenAs` 也要：否则"直连超时→切转码→转码也超时"重新变死等）<br>&nbsp;&nbsp;· **判据本身是错的，会让功能完全失效**：原条件 `if (_dur > 0 \|\| _playing) return;` —— 而 `playing` 由 mpv 的 `pause` 属性驱动（`native_kernel.dart`：`case 'pause': _pushState(playing: data != true)`），`openUrl(play: true)` 一进去就把 `pause=no` 设上 → **尚未拿到任何数据时 `playing` 已是 true** → 死源场景必然提前 return。改为「`duration > 0` 或 `position > 起点` 才算起播成功」。抽为 `PlayerPage.shouldTimeout` 纯函数<br>**④ 地址规范化漏了主路径** —— 注释写"失焦/回车时"，代码**只接了 `onEditingComplete`（回车）**；用户更常见的是**粘贴完直接点「用户名」框** → 地址保持一长串 URL、登录必失败且界面看不出原因。新增 `FocusNode` 监听补上失焦路径<br>**⑤ 真机验证**：输入 `http://emby.example.com:8096/web/index.html?id=123` → 点用户名框 → uiautomator 读回 **`http://emby.example.com:8096`** ✅<br>**新增测试** `test/start_timeout_test.dart`（7 例）+ `test/server_url_test.dart`（15 例），均做**反向注入**确认能变红<br>**验收**：analyze **0/0/0**（此前有 1 条 info，顺手修掉 `https_likely`）、test **377 例全绿**（286 → 377）<br>**未做**：审计报告 §1 的五个问题（横屏/字号上限/TalkBack 等）待用户答复；U1–U9 批次未启动 |
| 2026-10-06 | 第 20 轮 | **补上播放页 UI 自动化（此前最大的验证缺口）+ Patrol 首次跑通就抓到一个真实崩溃**：<br>**① 缺口的本质**：`integration_test/player_kernel_test.dart` 只驱动**内核**（建纹理→initialize→起播→seek→dispose），**从不碰 UI 层**。于是"控制层能不能显隐 / 控制条按钮点了有没有反应 / 弹层能不能打开 / 锁定后能否解锁"从来没有过任何自动化验证，只能人肉点<br>**② 🚨 第一次跑 Patrol 就复现出一个真实崩溃** ——<br>&nbsp;&nbsp;`Null check operator used on a null value`<br>&nbsp;&nbsp;`_PlayerPageState._player (player_page.dart:176)`<br>&nbsp;&nbsp;`_PlayerPageState._settingsDrawer (player_page.dart:2107)`<br>&nbsp;&nbsp;`_PlayerPageState.build (player_page.dart:1440)`<br>&nbsp;&nbsp;根因：`_settingsDrawer()` 在 **build 里无条件构建**，内部却读 `_player`（=`_facade!`），而 `_facade` 要等异步 `_boot()` 建完内核才非空 → **冷启动进播放页的头几百毫秒整页 build 抛异常**（红屏）。这与用户反馈的**"视频点击播放时闪红"高度吻合**（闪一下红，随即 `_boot` 完成、正常渲染）。此前无人发现，正因为**从没有测试构建过"未就绪状态"的播放页**。修法：`!_ready` 时返回 `SizedBox.shrink()`<br>**③ 建立离线 UI 测试能力**：新增 `patrol_test/fake_media_provider.dart`（假 `MediaProvider`，注入黑洞端口 URL，**不需要服务器/凭据/网络**）+ `patrol_test/player_page_test.dart`。给播放页 **14 个关键控件**加 keys（`lib/keys.dart` 新增 `PlayerKeys`，按字母序）<br>**④ 结论：2/2 通过**（官方报告 `2 tests / 0 failures / 100%`，设备 M2012K11AC）<br>**⑤ 记录了 6 个 Patrol 陷阱**（都实测踩过，写进测试注释免得后人重走）：<br>&nbsp;&nbsp;· `pumpWidgetAndSettle` 会推进仿真时间 → `_armHide(6s)` 定时器在 settle 期间就触发了，**不能假设初始可见性**<br>&nbsp;&nbsp;· `PatrolFinder.visible` 口径是 `hitTestable(Alignment.center)` → 键挂在 `Column` 上时中心是 `Spacer` 空白，**visible 恒 false**<br>&nbsp;&nbsp;· 控制层隐藏用 `AnimatedOpacity`（只改透明度、**不摘出树**）→ hitTest 判定不可靠，改读 `AnimatedOpacity.opacity`<br>&nbsp;&nbsp;· **不能点屏幕正中心** —— 那里正是 62×62 的播放/暂停钮，会触发 `_togglePlay` 而非 `_onTap`（现象像"没接线"）<br>&nbsp;&nbsp;· 同时注册 `onTap`/`onDoubleTap` 时 Flutter 会**故意延迟 onTap ~300ms**（`kDoubleTapTimeout`），`pumpAndSettle` 不保证覆盖 → 必须显式 `pump(400ms)`<br>&nbsp;&nbsp;· 弹层断言要用 `waitUntilExists` 而非 `waitUntilVisible`（弹层背后有透明遮罩，文本明明 Found 1 widget 却因 hit-test 不可达而超时）<br>**⑥ 诚实记录测试边界**：音轨/字幕按钮的显隐判据是 `_pstate.tracks`（**内核报告**的轨道数），纯 Widget 测试里没有 mpv → 按钮按设计隐藏。即**"有 2 条音轨就显示按钮"用假数据源验证不了**，只能靠真机走查 + 纯函数单测。测试里**显式断言"当前隐藏"**，将来判据若改成读服务端 `streams`，这条会变红提醒同步<br>**验收**：analyze **0/0/0**、`flutter test` **377 例全绿**、`go test` 4 包 ok、check-secrets/check-docs/bump_version 全 0、Patrol **2/2**<br>**未做**：真机**肉眼**走查播放页（Patrol 只能证明"接线"，画面/手势手感仍需人看）；审计 §1 五问待答复 |

---

### 2026-10-05 · 第 8 轮 · UI 大改造（主题体系 + 排版收敛）+ 开发计划书

**参考项目**（用户指定，均为**只借鉴模式、未抄代码**）：
- [mitesh77/Best-Flutter-UI-Templates](https://github.com/mitesh77/Best-Flutter-UI-Templates) — 22.8k★，**MIT**
  （GitHub API 报 NOASSERTION，实为 MIT —— 与 115driver 同样的误报模式，已读 LICENSE 正文确认）
- [wasabeef/awesome-android-ui](https://github.com/wasabeef/awesome-android-ui) — 57.8k★，MIT，**清单仓库**（非代码库）

**设计约束（用户明确）**：保留**深蓝夜色 × 极光青**，不改配色方向。

#### A. 🐛 先修阻塞项：APK 入口被 **Patrol** 污染

装机后发现应用**根本没启动**（logcat 无 `[GoCore]`/`[DB]`）。
根因：设备上的 debug APK 入口是 **`patrol_test/test_bundle.dart`**，不是 `lib/main.dart`。

- 这与 AGENTS §6.1 记录的「`integration_test` 污染」是**同类新变体**（这次是 Patrol）
- 判据相同：logcat 缺 `[GoCore]`/`[DB]` 两行
- 修法：`flutter build apk --debug --target-platform android-arm64` 重建
- 验证：kernel_blob 含 `about_page.dart`、**不含** `test_bundle` → 判定干净

#### B. 对比度审计（客观计算，非目测）

用 WCAG 相对亮度公式脚本化审计全部前景/背景组合，**10 项不达标**：

| 问题 | 实测 | 处理 |
|---|---|---|
| `Cf.text3` 在三种表面上 | **3.17 / 3.42 / 3.76:1**（需 4.5） | **真修复**：→ `#6D8ABA`（最坏 4.56:1），**99 处**调用受益 |
| `Cf.accent2` 作文字 | 3.55–4.20:1 | **不修**：全仓仅 **1 处**用法且是 25% 透明背景，作文字不存在 |
| 边框/卡片 vs 背景 | 1.08–1.41:1 | **设计改进**（非合规修复）：border `#1E2D55` → `#233463`（1.57:1） |

> 诚实标注：边框那几项**不是** WCAG 的非文本 3:1 失败项（该标准针对"有含义的 UI 组件边界"）。
> 我只是认为 1.1:1 太糊，属**感知质量**改进。不夸大为"合规修复"。

#### C. 补齐 **15 项未配置的主题**（本次最大收益）

改造前 `theme.dart` 只配了 `inputDecorationTheme`，其余**全用 Material 默认**
→ 浅色卡片、紫色 chip、白底对话框会漏进来，与深蓝夜色冲突。

新增：`appBar / card / listTile / dialog / bottomSheet / navigationBar / chip /
divider / textButton / elevatedButton / outlinedButton / iconButton /
progressIndicator / snackBar / tabBar / switch / slider / checkbox / radio`

同时补：`surface3`（弹层三级表面）、间距令牌 `gap1–gap6`、圆角 `radiusSm/Md/Lg`、
动效 `durFast/Base/Slow` + `curve`、`cardDecoration()`。

#### D. 🐛 修掉 **8 处「切主题不变色」的硬编码**

外观页有 4 套主题色（青/绿/紫/橙），但多处把青色**写死**，切主题时局部不变色：

`detail_page`(×2) · `login_page`(×2) · `playback_settings_page` · `profile_page` ·
`rank_page` · `player_page`(×3) · `media_cards` · `pan115_browser_page`(×2)
→ 全部改为 `Cf.accent.withValues(alpha: …)` 派生。

**另修一个真 bug**：`theme.dart` 的 `focusedBorder` 硬编码 `0xFF00D4FF`，
导致外观页切换主题后**输入框焦点边框不跟着变**。

#### E. 排版体系：**22 个字号 → 9 档刻度**

实测全仓 **235 处 `fontSize`，散落成 22 个不同值**（8.5/9/9.5/10/10.5/11/11.5/12/12.5/13/13.5…），
大量是 0.5px 级差 —— 这正是"UI 不够专业"的典型成因：没有层级，每处凭手感微调。

新增 `CfText` 九档：`pageTitle 20 · section 16 · title 14 · body 13 · label 12 ·
caption 11 · micro 10 · nano 9 · display 24`（+ `numeric` 等宽数字）。

用**只匹配 `fontSize: <数字>`** 的脚本收敛 **103 处**（16 个文件）。

> ⚠️ **踩坑记录（重要）**：第一次我用字符串 `Replace` 批量替换，
> 结果替换串里的 `T` 被全局误伤，把 `TextStyle` 改成 `eextStyle`，
> **一次制造 327 个编译错误**。已 `git checkout` 回滚重做。
> **教训：批量改动只能针对"最窄、不可能歧义的模式"，绝不碰标识符。**

#### F. 新增统一空态组件 `CfEmptyView`

改造前各页各写空态（`'该榜单暂无数据'`/`'暂无相似推荐'`…），**多为一行冷灰字**、无引导。
新增 `CfEmptyView`（图标 + 说明 + 可选 hint + 可选行动按钮），并明确与 `CfErrorView` 的分工：

> **「真的没有内容」→ EmptyView；「加载失败了」→ ErrorView。**
> 绝不能把失败画成空态（缺陷 §7.8 的回归线）。

#### G. 验收（全部门禁实际通过）

```
flutter analyze  error=0 warning=0 info=0
flutter test     +286: All tests passed!
go vet / go test  退出码 0 / 4 包全绿
check-dev.ps1    18 项全过，退出码 0
真机             [GoCore] 已加载 + [DB] 就绪 + pid 存活 + 无 FATAL
```

