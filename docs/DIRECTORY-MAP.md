# 目录地图（CineFlow）

> **为什么单独成文**：AGENTS.md 有**工作区指令预算**（65536 字节），
> 超出会被截断，导致后面的章节代理读不到。
> 而目录结构**属于"环境可自助查询"的信息** —— 用 `glob` / `ls` / `rg --files`
> 几秒就能确认，把它常驻在指令里是纯浪费（mp-writing-for-agents 的
> 「环境是事实源，文档不该缓存便宜的查找」）。
>
> 本文件由 AGENTS.md §4 外移而来（2026-10-05）。**内容未改动**，
> 仅在顶部加了这段说明。目录地图仍然有用：它给出**"什么在哪一层、为什么"**，
> 这是 ls 看不出来的。

---


```
go/                              # ★ Go 核心逻辑层（ADR 0004）→ libcineflow_go.so
├── go.mod
├── bridge.go                    # C ABI 薄包装（含 import "C"，**不要在此写业务逻辑**）
└── internal/
    ├── rpc/                     # 零 cgo 路由：Dispatch + JSON 信封（可纯 Go 单测）
    │   ├── pan115_routes.go     #   ★ 115 的 13 个 FFI 方法路由
    │   └── pan115_session.go    #   ★ 115 进程内会话表（Go 侧不落盘凭据）
    ├── media/                   # 零 cgo 规则：IsPlayable/Normalize/Filters/Progress/Sort
    └── pan115/                  # ★ 115 webapi 协议层（零 cgo，可离线单测）
        ├── client.go            #   端点常量/固定 UA/扫码状态机/flexBool 宽容解析
        ├── login.go             #   扫码登录链路、错误码分类、WAF 识别、账号信息
        ├── files.go             #   文件列表（offset 分页）、宽容类型、目录判据、格式化
        ├── playback.go          #   取直链（缓存/失效）、**播放头唯一产出点**
        ├── ratelimit.go         #   全局 2 req/s 串行限速（账号安全）+ WAF A/B 分类
        ├── crypto_bridge.go     #   m115 加解密的唯一调用点
        └── m115/                #   ★ m115 加解密（移植自 115driver，MIT 署名齐全）
            ├── m115.go          #    公开 API：GenerateKey/Encode/Decode
            ├── rsa.go           #    115 内置 1024 位公钥 + 分块模幂
            ├── xor.go           #    seed/clientKey 常量与密钥派生
            ├── util.go          #    reverseBytes
            └── LICENSE-MIT-115driver  # MIT 全文（已剔除立场声明段）
lib/
├── main.dart                    # 入口 + Go/DB 自检（会话门控已迁到 router）
├── core/
│   ├── theme.dart               # 设计系统唯一来源：Cf 色彩令牌 / 渐变 / CfLogo
│   ├── uuid.dart                # UUID v4（设备 ID）
│   ├── version.dart             # ★ 版本号单一来源（kAppVersion/kClientVersion，镜像 VERSION）
│   ├── go_core.dart             # ★ Go 层 Dart 绑定（FFI + 内存释放 + 降级 + invokeAsync）
│   └── router.dart              # ★ go_router 路由表 + resolveRedirect（会话门控，纯函数）
├── data/
│   ├── media_provider.dart      # ★ MediaProvider 抽象接口（新增媒体能力先改这里）
│   ├── emby_provider.dart       # Emby REST 实现（含实测结论注释，改动前先读）
│   ├── models.dart              # ★ 中立媒体模型（MediaItem 等）+ Emby 线格式解析
│   ├── session_store.dart       # secure_storage：会话/服务器/搜索历史/播放偏好(cf_pref_*)
│   ├── home_repository.dart     # 首页聚合；单区块失败必须吞掉降级
│   ├── db/                      # ★ drift 本地库（ADR 0005）
│   │   ├── app_database.dart    #   表定义 + cacheGet/Put（TTL 在写入时固化）+ 播放历史
│   │   ├── app_database.g.dart  #   build_runner 生成，**不要手改**
│   │   └── db_provider.dart     #   连接与 appDbProvider（测试可 override 成内存库）
│   └── douban/                  # 豆瓣客户端（外部引入：douban_client/douban_http/douban_image/…）
├── state/
│   ├── providers.dart           # SessionNotifier(AsyncNotifier) / embyApiProvider / homeProvider
│   └── douban_providers.dart    # 豆瓣 providers（缓存注入 DriftDoubanCache）
├── danmaku/                     # ★ 弹幕（阶段五）
│   ├── danmaku_models.dart      #   数据模型 + `p` 两种布局解析 + 文本清洗
│   ├── danmaku_sign.dart        #   官方签名 base64(sha256(AppId+Ts+Path+Secret))
│   ├── danmaku_client.dart      #   HTTP + 双认证形态 + 错误分层 + 缓存
│   ├── danmaku_async.dart       #   异步生成轮询状态机（1.5s × 5min）
│   ├── danmaku_match.dart       #   Emby 条目名 → 番剧名/集号（纯逻辑）
│   ├── danmaku_layout.dart      #   轨道分配（追尾判据）+ 可见性计算
│   ├── danmaku_overlay.dart     #   CustomPainter 渲染层 + 开关按钮
│   ├── danmaku_config.dart      #   源配置 + 地址归一化/校验
│   ├── danmaku_providers.dart   #   riverpod 接线（失败不影响播放）
│   └── danmaku_settings_page.dart # 设置页（源/外观/屏蔽词/开关）
├── pan115/                      # ★ 115 网盘（阶段八，见 §6.8 与 ADR 0007）
│   ├── pan115_client.dart       #   Go 核心层的 Dart 门面（全部走 invokeAsync）
│   ├── pan115_store.dart        #   凭据安全存储 + provider 接线（凭据不落盘到 Go）
│   ├── pan115_login_page.dart   #   扫码登录（含风险提示；轮询串行 + 世代号作废）
│   ├── pan115_browser_page.dart #   文件浏览（面包屑/文件夹树，不假装成"季/集"）
│   └── pan115_player.dart       #   播放（★ 核心职责：把 headers 原样交给 media_kit）
├── pages/                       # 7 个页面：login/home/home_shell/detail/rank/search/profile
│                                #   （library_page.dart 已移除，见 ADR 0003）
├── player/
│   ├── player_page.dart         # ★ 播放器整页（控制层/手势/抽屉/进度上报）
│   └── player_routes.dart       # ★ 播放器路由 + extra 载荷 + 深链回退
└── widgets/                     # media_cards.dart（公共卡片 + showComingSoon）/ douban_detail_sheet.dart

test/
├── widget_test.dart             # 登录页冒烟测试（FakeStore 隔离平台通道）
├── sort_and_prefs_test.dart     # 默认倍速编解码闭环 + 偏好键（5 例）
├── home_repository_test.dart    # 首页四区块降级契约 + 全失败必须报错（6 例）
├── people_test.dart             # 演职员筛选/导演摘要/防御式解析（10 例）
├── server_filter_test.dart      # Genres/Years 参数 + POST UserData + EventName（16 例）
├── router_test.dart             # 路径构造 + 会话门控分支（15 例）
├── db_test.dart                 # drift 表语义：TTL/播放历史（17 例）
├── douban_cache_test.dart       # 缓存 TTL 契约（12 例，§7.4 回归线）
└── danmaku_*.dart               # ★ 弹幕 7 个文件共 161 例：
                                 #   签名 12 · 匹配 30 · 布局 34 · 客户端 42 ·
                                 #   异步 24 · 配置 25 · 持久化 14
                                 # （115 的测试在 Go 侧：go/internal/pan115 + m115，共 70 例）
tool/
├── build_apk.bat / .sh          # release 构建
├── build_go.sh                  # ★ Go 交叉编译到 jniLibs（按 ABI，自动探测 NDK）
├── patch_b.py / patch_c.py / patch_d.py  # ⚠️ 历史一次性补丁脚本，已执行完毕，禁止重跑
└── icon/icon_template.svg.frag  # 图标模板；_gen/ 是生成产物（含 Edge 垃圾文件，勿提交）
scripts/
├── check-secrets.ps1            # ★ 敏感信息门禁（反向注入验证过）
├── check-docs.ps1               # ★ 必需文档 + Markdown 断链门禁
└── discover_oss.py              # GitHub 开源发现与核实（--verify）
.github/
├── skills/                      # 本地工作流资产（不入库，见 .gitignore）
│   ├── cineflow-workflow/       # 六段流水线 / 铁律 R1–R9 / references（gates·task-cards·context-budget）
│   ├── cineflow-review/         # L0–L3 分级审查、否决项、输出格式
│   ├── cineflow-tech-skills/    # 技术技能包 / references（emby-api·player-media·douban·degradation-and-device）
│   ├── cineflow-oss-search/     # 开源发现、许可边界、references/search-playbook
│   └── cineflow-release/        # 发版规范：版本号三处同步、changelog、APK 上传
├── workflows/                   # CI：ci.yml（analyze/test/门禁）、release.yml、release-notes.yml
├── ISSUE_TEMPLATE/              # YAML issue forms（bug / feature）+ config.yml
└── PULL_REQUEST_TEMPLATE.md
docs/
├── DEVELOPMENT.md               # 架构决策与踩坑实录（改行为后需同步）
├── architecture.md              # ★ 分层与 MediaProvider 契约（按实际代码写）
├── CHANGELOG-GUIDE.md           # 变更日志写作法
├── changelog/                   # ★ 发布说明（每版一份，Release 正文的事实源）
├── decisions/                   # ADR：0001（已废弃）· 0002（纯 Dart MVP，现行）
└── lessons/                     # 踩坑经验索引与写作规范
../cineflow.html                 # 计划书（工作区根目录，非本工程内）
```

**技能与文档的关系**：`.github/skills/` 是**作业口径**（怎么做），`docs/` 是**仓库内证据**
（契约、清单、看板、台账）。改流程改技能，改契约改 `docs/`——两者不一致时以 `docs/` 与代码为准。
