# 审查清单 · CineFlow

> 用法：审查时**逐节打勾**；命中否决项直接判驳回，不写"建议优化"。
> 与技能 `cineflow-review` 配套；否决项输出到 `文件:行号` + 依据条款。
> 变更历史只增不改，见文末日志。
> **本清单按本仓库实际技术栈（纯 Dart/Flutter，无 Go 层）裁剪**，见 [ADR 0002](decisions/0002-pure-dart-mvp.md)。

---

## §0 · L0 自动门禁（未过 = 直接驳回，不算审查意见）

> **⭐ 一条命令跑完全部 L0**：
> ```bash
> powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-dev.ps1
> ```
> 退出码 0 = 过。**有跳过项时必须写明"哪些没验证"**（如无设备跳过了真机冒烟）。
> 下面保留分项，便于单独排查。

- [ ] **`scripts/check-dev.ps1` 退出码 0**（或下方各项逐条通过）
- [ ] `flutter analyze` **0 error / 0 warning**（仅允许 §1 列出的 3 条 douban info）
- [ ] `flutter test` 全绿，报告里贴通过数（当前 **286 例**）
- [ ] `go vet ./...` 0 警告；`go test ./...` 全绿（当前 **143 例**，零 cgo 包）
- [ ] `powershell -File scripts/check-secrets.ps1 --staged` clean
- [ ] `powershell -File scripts/check-docs.ps1` clean
- [ ] `powershell -File tool/bump_version.ps1 -Check` 三处一致
- [ ] **APK 入口未被集成测试污染**（`kernel_blob` 含 main 入口）
      —— `flutter test integration_test` 之后必须重新 `flutter build apk`
- [ ] 若改了播放器：真机启动后 logcat 有 `[GoCore] 已加载` + `[DB] 就绪`；
      播放 → 返回 → `adb shell pidof com.cineflow.app` 存活
- [ ] 若改了播放内核：`flutter test integration_test/player_kernel_test.dart -d <id>` → 1 passed
- [ ] **`docs/AI-MEMORY.md` 已更新**（本轮台账 + 进度 + 工作区状态）

> ⚠️ `flutter analyze` 在**只有 info** 时也返回退出码 1。判定标准是输出里的
> "0 error / 0 warning"，不是退出码（AGENTS.md §3.1）。
>
> ⚠️ **门禁脚本失败时会打印"补救指引"**，看着像正常收尾——
> **必须看退出码**，不能看输出尾部（AGENTS §8.1）。
>
> ⚠️ **白屏的第一诊断**：`logcat` 里没有 `[GoCore] 已加载` / `[DB] 就绪` 这两行。
> 正常启动必然有——缺了就是入口被污染或初始化抛异常（AI-MEMORY §6.1）。

---

## §1 · 代码审查（L1）

- [ ] **任务外改动为零**：diff 文件清单与任务卡 `deliverables` 一一对应，无顺手重构/格式化/无关注释删除
- [ ] **没有跑过 `dart format`**（会改动 24/26 文件，制造数千行无关 diff，AGENTS §9）
- [ ] **死代码只提不删**：预先存在的死代码在 PR 里说明，未擅自删除；自己造成的孤儿导入/变量已清掉
- [ ] **错误处理**：无空 `catch {}`；网络失败可降级但**不得把失败伪装成空数据**（§4）
- [ ] **防御式解析**：模型层无对服务器字段的非空断言（`as String` 而非 `as String?` 即违规）；
      列表统一 `.whereType<Map<String, dynamic>>()`
- [ ] **测试覆盖**：成功 / 失败 / 边界 / 超时四类至少三类；**新测试反向注入过并看到红灯**（记录注入点）
- [ ] **测试真实性**：夹具像真实响应；断言不会因时序让 bug 不发生（清理类断言尤其）
- [ ] **UI 令牌**：颜色/间距只用 `Cf` 令牌（`lib/core/theme.dart`），未硬编码色值
- [ ] **文案**：全中文，风格对齐现有页面
- [ ] **未接入功能**：统一走 `showComingSoon(context, '功能名')`，不留死按钮、不假装已实现
- [ ] **资源与性能**：大列表分页/虚拟化；图片走缓存与尺寸裁剪
- [ ] **日志**：中文可读，不含认证信息、不含 Cookie/Token

---

## §2 · 抽象层与架构（L2，改接口/模块边界时）

- [ ] **`MediaProvider` 抽象层未被绕过**：UI 无新增的 `emby_provider.dart` 直接依赖
      （存量 8 处见 AGENTS §7.13，**只减不增**）
- [ ] **Emby 特有字段未泄漏到 UI 模型**：新字段先问"115 接入时它还有意义吗"
- [ ] 新功能已评估**要不要进 `MediaProvider`**：凡未来其它媒体源也需要的能力
      （媒体库/详情/播放/进度）必须先在 `media_provider.dart` 定义接口，再在 `EmbyProvider` 实现
- [ ] 接口新增/变更有 **ADR**（背景 → 决策 → 替代方案 → 影响 → 回退）且已入库 `docs/decisions/`
- [ ] `docs/architecture.md` 对应契约段同步更新
- [ ] 未引入 Go 桥接 / go_router / drift 等**已被 ADR 0002 否决的选型**（除非用户明确要求）
- [ ] 弹幕模块与媒体源解耦，匹配走统一媒体信息（阶段五）

---

## §3 · 安全与合规（L1 必查、L3 全量）

- [ ] 无真实 Token / Cookie / 密码 / 私钥 / 服务器地址 / 内网 IP 进入提交
- [ ] `*.example` 之外没有真实凭据文件；凭据放 `.local` / `.env`（已 gitignore）
- [ ] Token 存 `flutter_secure_storage`，不落明文、不打日志
- [ ] `android/.gitignore` 仍忽略 `key.properties` / `*.keystore` / `*.jks`
- [ ] 用户自定义 HTTP 地址有默认 HTTPS 提示；非 HTTPS 有明确警告
- [ ] 依赖变更已评估许可与体积（GPL/AGPL 不得合并源码，见 `docs/OSS-SOURCES.md`）

---

## §4 · 降级与错误呈现（本仓库专项，L1）

> 这一节来自真实缺陷（AGENTS §7.8 / §7.9）：网络故障曾被伪装成"暂无内容"。

- [ ] **「加载失败」与「真的没有内容」可区分**：失败时显示 `CfErrorView` + 重试，
      不得显示"该库暂无内容"/空首页
- [ ] 首页单区块失败**只降级该区块**，其余照常渲染
- [ ] 全部区块失败时经 `HomeData.fatalError` 报错，而不是渲染空首页
- [ ] 「重试」按钮**真能恢复**（这是它唯一的价值，常被漏测）
- [ ] 降级逻辑有对应单测（参考 `test/home_repository_test.dart`）

---

## §5 · 协议实现专项（凡触碰 `emby_provider.dart`）

- [ ] **新增 Emby 端点/字段前已 curl 实测**，结论写进方法注释（脱敏：只写协议形状，不写真实值）
- [ ] `authHeader()` 仍恒定带 `Version`（缺了服务端 500，删了必炸）
- [ ] 未用 `IsFolder` 判断剧集（`Series` 也是 `IsFolder=true`，文件夹浏览只认 `BoxSet`）
- [ ] `/Latest` 解析兼容 map/List 两种形状，且保留客户端 `isPlayable` 复筛
- [ ] Similar 路径是 `/Items/{id}/Similar?userId=`（带 `/Users/{uid}` 会 404）
- [ ] 收藏/看过用 `/Users/{uid}/FavoriteItems/{id}`（取消加 `/Delete`），不是 `/Favorites/`
- [ ] 多版本：服务端**始终返回全部 MediaSources**，客户端必须按 id 复选
- [ ] `SortOrder` 由客户端显式指定，不依赖服务端默认（默认方向对"最近添加"是反的）
- [ ] 未凭文档或记忆实现转码（本服务器实测不具备转码能力，见 AGENTS §7.12）

---

## §6 · 文档 / ADR / 变更日志（L1 必查）

- [ ] 每个被更新文件自带变更日志表，历史行未删
- [ ] `VERSION` 已递增（规则见 AGENTS §8）
- [ ] `CHANGELOG.md` / 对应文档变更日志已更新，写法符合 `docs/CHANGELOG-GUIDE.md`
- [ ] Markdown 相对链接有效（`scripts/check-docs.ps1`）
- [ ] **新增技能**：附「借鉴来源」清单（仓库 + stars/更新时间/许可 + 借鉴点 + 边界），
      每条都经 `python scripts/discover_oss.py --verify` 核实；陈旧引用已更正进 `docs/OSS-SOURCES.md`
- [ ] 引用第三方仓库时：GPL/AGPL 只借鉴架构与流程，**不得合并源码**（ADR 里说明如何自行实现）
- [ ] ADR 五段齐全（背景/决策/替代方案/影响/回退条件）
- [ ] `docs/task-board.md` 状态与本次合并同步（`todo→done` 或说明原因）
- [ ] 真机截图/验证说明写进了 PR（UI 类）
- [ ] **文档不比代码乐观**：README/AGENTS 里"已实现"的说法与代码一致（§7.10 是历史教训）

---

## §7 · 发布审查（L3）

- [ ] 版本号三处一致（`VERSION` / `CHANGELOG.md` 最新条目 / 任务卡引用）
- [ ] `scripts/check-secrets.ps1` **全量**通过，不是只扫暂存区
- [ ] 打包产物齐全 + checksums
- [ ] 变更日志第一屏自检：用户知不知道要不要动手
- [ ] 需用户动手的步骤可照做（命令 / 菜单路径已核对前端实际文案）
- [ ] 已知限制/未完成项已在变更日志里坦白（如 debug 签名、无 WakeLock）

---

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本；L0–L3 分级、七节清单（代码/桥接/安全/架构/**115 预留专项**/文档/发布） |
| v1.1 | 2026-10-04 | §6 新增「新增技能必须附已核实的借鉴来源清单」与「GPL/AGPL 不得合并源码」两条驳回项 |
| v1.2 | 2026-10-04 | **按本仓库实际技术栈裁剪**：删除 §2 桥接审查与 §5 115 预留专项（本仓库无 Go 层，见 ADR 0002）；新增 §4「降级与错误呈现」专项（源自缺陷 7.8/7.9）与 §5「协议实现专项」（Emby 实测坑）；§0 门禁命令改为 PowerShell 脚本与 Flutter 侧 |
