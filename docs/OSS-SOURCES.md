# 开源参考项目注册表（已核实）

> **引用规则**：写进任何文档/ADR 之前必须先用 `python scripts/discover_oss.py --verify <owner/repo>` 核实。
> 别凭记忆写仓库名——今天（2026-10-04）首次核实就发现两个 404、一个 0 star、一个 1 star。
> 新增候选用 `python scripts/discover_oss.py "关键词" [--area <领域>] --write` 自动发现，状态一律先标「待核」。

## 许可与「能不能抄」（硬规矩）

| 许可 | 能做什么 | 红线 |
|---|---|---|
| MIT / BSD / Apache-2.0 | 可借鉴实现、**可少量抄并保留版权声明**（Apache 还要带 NOTICE） | 抄之前保留原始版权头 |
| GPL-2/3、AGPL-3 | **只能借鉴架构、流程、接口理解** | ❌ 不得把源码并入本仓库（传染）；AGPL 连服务端调用都算，规定不同 processeship |
| NOASSERTION（无明确许可） | 只读想法、只借鉴自己写的协议理解 | ❌ 默认禁止复制任何代码；要抄先找作者确认 |

> ⚠ 待决：CineFlow 自身许可尚未确定（见 `docs/decisions/` 待办）。
> **只要还要发布闭源或换许可的可能，就一律不许合并 GPL/AGPL 代码**，这是不可逆的决定。

## 已核实清单（2026-10-04 用 discover_oss.py 实测）

> 标 **★在用** 的是本仓库当前真正引用过的参考；其余为候选池。
> `S1 桥接` 四行对应已废弃的路线（见 [ADR 0002](decisions/0002-pure-dart-mvp.md)），
> 保留仅为追溯，**不要再据此引入 Go 桥接**。

| 领域 | 仓库 | stars | 最近提交 | 许可 | 借鉴点 | 能不能抄代码 | 状态 |
|---|---|---:|---|---|---|---|---|
| S1 桥接（已废弃路线） | [getlantern/lantern](https://github.com/getlantern/lantern) | 16083 | 2026-10-03 | GPL-3.0 | 桌面 `dart:ffi` + 移动 gomobile 平台通道双路径、Protobuf 线协议、按端 Makefile | ❌ 只借鉴架构 | 已核实 |
| S1 桥接（已废弃路线） | [csnewman/flutter-go-bridge](https://github.com/csnewman/flutter-go-bridge) | 102 | 2024-05-30 | MIT | `go generate` 双向绑定、异常自动映射 | ✅ 可参考（注意停更 2 年） | 已核实 |
| S1 桥接（已废弃路线） | [leehack/flutter_golang_ffi_example](https://github.com/leehack/flutter_golang_ffi_example) | 57 | 2024-05-26 | NOASSERTION | `src/ + lib/ + 平台目录` 脚手架、`ffigen.yaml` | ⚠ 只看结构 | 已核实 |
| S1 桥接（已废弃路线） | [fossabot/golang-flutter-app-ffi](https://github.com/fossabot/golang-flutter-app-ffi) | 0 | 2023-05-15 | MIT | 最小 Makefile 形态 | ⚠ 已停更，仅作思路 | 已核实 |
| S2 Emby | **★在用** [zzzwannasleep/LinPlayer](https://github.com/zzzwannasleep/LinPlayer) | 325 | 2026-09-21 | AGPL-3.0 | `core/cmd/diffcheck/corpus/` 的 Emby 踩坑语料（服务端过滤不可信、`/Latest` 裸数组、认证头必带 Version）；本仓库多个方法注释直接引用其结论 | ❌ 只读现象结论，禁止合并源码 | 已核实 |
| S2 Emby | **★在用** [edde746/plezy](https://github.com/edde746/plezy) | 3595 | 2026-10-01 | **GPL-3.0** | `lib/services/jellyfin_client/parts/browse.dart` 的 `fetchSortOptions`（排序方向 `title→asc`/`rating→desc`/`addedAt→desc`）、`library_query_translator.dart` 的参数拼装 | ❌ 只借鉴工程决策，禁止合并源码 | 已核实 |
| S2 Emby | [jellyfin/jellyfin-web](https://github.com/jellyfin/jellyfin-web) | — | — | GPL-2.0 | Jellyfin 与 Emby 同源，查询参数语义的权威参考 | ❌ 只查语义 | 待核（stars/日期未取） |
| S2 Emby | [Moonfin-Client/Moonfin-Core](https://github.com/Moonfin-Client/Moonfin-Core) | 788 | 2026-10-03 | GPL-2.0 | 播放后端按平台自适应（Android TV Media3 / Apple TV MPVKit / 其余 media_kit）、TV D-pad | ❌ 只借鉴选型矩阵 | 已核实 |
| S2 Emby | [MCDFsteve/NipaPlay](https://github.com/MCDFsteve/NipaPlay) | 173 | 2026-02-02 | GPL-3.0 | Flutter 本地弹幕播放器、多端移植 | ❌ 只借鉴结构与反 verf | 已核实 |
| S3 播放 | [media-kit/media-kit](https://github.com/media-kit/media-kit) | 1830 | 2026-08-30 | MIT | 播放封装、平台支持矩阵 | ✅ 可直接依赖 | 已核实 |
| S3 播放 | [mpv-player/mpv](https://github.com/mpv-player/mpv) | 37221 | 2026-10-03 | NOASSERTION（实为 GPL-2.0） | option 与 `mpv.conf` 语义权威 | ⚠ 作为依赖引用，不抄源码 | 已核实 |
| S4 弹幕 | [Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) | 574 | 2026-09-26 | MIT | mpv 弹幕扩展、时间轴与样式参数 | ✅ 可抄（带版权声明） | 已核实 |
| S4 弹幕 | [huangxd-/danmu_api](https://github.com/huangxd-/danmu_api) | 3225 | 2026-10-02 | AGPL-3.0 | 兼容弹弹play 协议的自建服务 | ✅ 可作调用方；❌ 二次开发需开源部署侧 | 已核实 |
| S4 播放/弹幕 | [okami-horo/DDPlayTV](https://github.com/okami-horo/DDPlayTV) | 3 | 2026-04-06 | Apache-2.0 | 多内核、libass ASS、关键字/正则屏蔽、远端源本地 HTTP 代理改善 seek | ✅ 许可安全；项目体量小，只取思路 | 已核实 |
| S5 115 | [SheltonZhu/115driver](https://github.com/SheltonZhu/115driver) | 207 | 2026-09-14 | **MIT**（GitHub API 误报 NOASSERTION） | 115 **webapi**（cookie）协议实现、UA 绑定问题、MCP/CLI、AGENTS.md 范式 | ⚠ **可提取协议事实**；但走的是**逆向 webapi**，本项目不采用该路线（见 ADR 0007） | 已核实（2026-10-05 复核许可） |
| S5 115 | [power721/115driver](https://github.com/power721/115driver) | 1 | 2026-09-13 | 同上游 | **是 `SheltonZhu/115driver` 的 fork（`fork:true`）**，非独立实现 | ❌ 不作独立证据源 | 已核实 |
| S5 115 | [lvzhenbo/115-plus-desktop](https://github.com/lvzhenbo/115-plus-desktop) | — | — | **MIT** | ★ 基于 **115 官方开放平台**的完整第三方客户端（Rust/Tauri）——许可安全且路线与本项目一致，**替代 GPL-3.0 的 boxplayer 作为首选参考** | ✅ 可提取协议事实 | 已核实 |
| S5 115 | [gaozhangmin/boxplayer](https://github.com/gaozhangmin/boxplayer) | 6976 | 2026-09-29 | **GPL-3.0**（README 徽章标 MIT 是**错的**，其徽章 URL 指向 `gaozhangmin/aliyunpan`） | 115 开放平台调用范例（设备码+PKCE、`video/play`、UA 绑定注册表） | ⚠ **强 copyleft：绝不可抄代码**（会传染本项目为 GPL）；**仅提取协议事实** | 已核实（2026-10-05 核实真实 LICENSE） |

## 已作废（核实失败，禁止再引用）

| 仓库 | 结果 | 备注 |
|---|---|---|
| `go-flutter/go-flutter` | HTTP 404 | 旧文档里的桌面 Go 插件方案，仓库不可达；不要用这个名字写进 ADR |
| `moonfin/moonfin` | HTTP 404 | 真名是 `Moonfin-Client/Moonfin-Core` |
| `detiam/NipaPlay-Reload` | 存在但 0 star | 引用请用 `MCDFsteve/NipaPlay`（173 star，GPL-3.0） |

## ⚠ 在用但许可需注意

| 仓库 | 实测结果 | 处置 |
|---|---|---|
| [chicring/Themby-Release](https://github.com/chicring/Themby-Release) | 61★，最近提交 **2024-08-20**（停更超 2 年），许可 **NOASSERTION**（无明确许可） | 本仓库 `ACKNOWLEDGEMENTS.md` 与 `docs/DEVELOPMENT.md` 借鉴了它的**控制层布局与进度上报协议**（属"借鉴想法与协议理解"范畴，未合并任何源码）。按本文件许可规矩，**不得复制其任何代码**；若将来要抄，必须先联系作者确认。停更较久，引用前重新核实 |

> 教训：搜索引擎摘要里的仓库名（尤其镜像站 ghub.com / github.de 的条目）会失真，一定 API 核实。
> 教训二：**`--verify` 要连许可一起看**——`plezy`（3595★，很活跃）实为 **GPL-3.0**，
> 只借鉴工程决策、不能并源码；`Themby-Release` 是 NOASSERTION，比"停更"更值得警惕。

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本：15 个已核实仓库 + 许可分层规矩 + 3 条作废记录（全部经 discover_oss.py 实测） |
| v1.1 | 2026-10-04 | 新增 **★在用** 标记；补录本仓库真正引用过的三个参考（`LinPlayer`、`plezy`、`Themby-Release`）并**实测其许可与更新时间**：`plezy` 为 GPL-3.0（3595★，活跃）、`Themby-Release` 为 NOASSERTION 且停更超 2 年 → 新增「在用但许可需注意」小节；S1 桥接四行标注「已废弃路线」；修正 `Moonfin-Core` stars 787→788 |
