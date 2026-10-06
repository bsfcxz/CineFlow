# AI 分发规范 · CineFlow

> **本文件约束 AI 代理的一切「对外分发」行为。**
> AI **不得**自行决定发版、打 tag、创建/修改/删除 Release —— 见 §1 铁律。
>
> 与其它文档的分工：
> | 文档 | 职责 |
> |---|---|
> | **本文件** | **分发纪律**：谁能发、什么时候发、必须经谁审批、什么绝不能做 |
> | [docs/AI-MEMORY.md](AI-MEMORY.md) | 每轮开发前必读 / 收工必写的进度与变更台账 |
> | `scripts/check-dev.ps1` | 开发收尾审查门禁（**开发**流程，不含分发） |
> | `.github/workflows/release.yml` | 分发的**唯一技术通道**（AI 不得绕过它手工发） |
> | [docs/changelog/](changelog/README.md) + [CHANGELOG-GUIDE.md](CHANGELOG-GUIDE.md) | 发布说明怎么写 |
>
> 冲突优先级：**用户当轮指令 > 本文件 > AGENTS.md > 其它**。

---

## 1. 🚫 铁律：AI 绝不做的事

违反其中任意一条 = **严重事故**（Release 是**不可撤回的对外动作**——
用户能看到、能下载、能被搜索引擎缓存，且 GitHub 的 tag 删除后仍可能残留引用）。

| # | 禁止 | 为什么 |
|---|---|---|
| **D1** | **绝不自作主张发版**。没有用户**当轮明确指令**（"发版"/"发布 X.Y.Z"/"上传 Release"），AI 不得打 tag、不得创建 Release、不得上传任何附件 | 发布是对外动作，时机由人决定 |
| **D2** | **绝不自增版本号后发版**。AI 可以建议版本号，但**必须由用户确认**具体数字后才能改 | 版本号是用户对外的承诺 |
| **D3** | **绝不删除、覆盖、替换任何**已有的 GitHub Release 或 tag —— 包括预发布、草稿、旧版本 | 见 §4；旧版本是用户回滚的唯一退路 |
| **D4** | **绝不 force push、绝不删 tag、绝不改历史 tag** | 会破坏所有已分发 APK 的可追溯性 |
| **D5** | **未经审批绝不执行** `gh release create/edit/upload/delete`、`git push --tags`、`git tag` 后 push | 见 §3 审批门 |
| **D6** | **绝不绕过 `release.yml`** 手工构建上传。不得用 `gh release upload` 临时补文件 | 唯一通道才可审计；手工上传会漏掉校验和与门禁 |
| **D7** | **绝不把 APK 提交进 git** | 30MB 二进制会永久撑大历史且无法真正删除（`.gitignore` 已排除 `/build/`） |
| **D8** | **绝不把符号表（`build/symbols/`）传进 Release** | 排查崩溃要用它，但没必要公开 |
| **D9** | **绝不在版本号未递增时发布** | 用户会装回旧包；`release.yml` 已内置拦截，AI 不得绕过 |
| **D10** | **绝不发布含未修复阻塞缺陷的包**（debug 签名/门禁红灯/测试不过） | 见 §5 检查清单 |

> AI 能做的是：**准备到"只差用户点一下"的程度**，然后**停下来等审批**。

---

## 2. 分发通道（唯一）

```
用户确认版本号
   ↓
① tool/bump_version.ps1 -Version X.Y.Z      # 三处同步
② docs/changelog/vX.Y.Z.md                  # 发布说明（事实源）
③ 跑 scripts/check-dev.ps1                  # 必须退出码 0
④ git commit && git push
⑤ git tag vX.Y.Z && git push origin vX.Y.Z   # ← 触发 release.yml
   ↓
release.yml（唯一通道，两段式）
   构建 arm64 APK（--split-per-abi + --obfuscate + 符号进 build/symbols/）
   → 校验 tag == VERSION == version.dart == pubspec（含递增校验）
   → 建 **draft** Release（正文取 docs/changelog/vX.Y.Z.md）
   → 上传 APK + checksums.txt
   → 附件数 ≥2 才 **转正**
   ↓
release-notes.yml 自动把 changelog 同步为 Release 正文
```

**产物命名**：`CineFlow-<版本>-arm64-v8a.apk` + `checksums.txt`（sha256）。

> ⚠️ 若 `git push --tags` 被 token 权限拒绝，走
> **Actions → release → Run workflow**，输入 tag —— **不要**改成手工 `gh release create`。

---

## 3. 🔒 审批门（每次分发前必须走）

**AI 必须先把下面这张表填好发给用户，等用户明确回复"批准"后才能继续。**

```markdown
## 待发布审批单（AI 填写，用户批准）

- 版本号：X.Y.Z（上一版：A.B.C）
- 是否递增：✅ 是（X.Y.Z > A.B.C）
- 三处一致性：bump_version.ps1 -Check 通过
- 开发门禁：scripts/check-dev.ps1 退出码 0（通过 N 项，跳过 M 项）
- 测试：flutter test N 例全绿 / go test M 例全绿
- 真机验证：已做 / 未做（未做则说明原因）
- changelog：docs/changelog/vX.Y.Z.md 已写（亮点：…）
- 将创建的 tag：vX.Y.Z
- 将上传的附件：CineFlow-X.Y.Z-arm64-v8a.apk (XX.X MB) + checksums.txt
- 已知限制（会写进 changelog）：debug 签名 / 仅 arm64 / …
- **是否保留全部历史 Release**：✅ 是（本操作不删除任何已有 Release）

👉 请回复「批准」后我才会执行 ⑤（打 tag 并推送）。
```

**用户回复必须是明确的肯定**（"批准"/"可以"/"发吧"）。
含糊回复（"嗯"、"看着办"）→ **再问一次**，不得自行解释为批准。

审批门适用于：**首次发布**、**补传附件**、**重跑工作流**、**发布预发布版**。

---

## 4. ⚠️ 「上传时不删除原有 Release」——强制要求

这是用户的**明确要求**，也是本仓库的分发底线：

### 必须做到
- **每次发布都是新增**：新 tag + 新 Release，**旧的保持原样**
- **不删旧 tag**：`v0.2.0` 发过就永久保留，即使已过时
- **不改旧 Release 正文/标题/附件**：包括修正错别字——宁可发新版本
- **不用 `--clobber` 覆盖已发布的附件**：`--clobber` 只允许用在
  **同一次工作流重跑**（draft → 转正之前），**不得**对已转正的 Release 使用
- **不做"重新上传覆盖同名版本"**：版本号变了就是新 Release

### 为什么
1. **旧版本是用户回滚的唯一退路**。删了旧包，遇到新版本 bug 就只能干等。
2. **已分发的 APK 无法召回**。用户手上、第三方镜像里的副本删不掉，
   删 Release 只会让"来源"与"实际存在"脱节，反而更难排查。
3. **校验和要对得上**。`checksums.txt` 是给用户验完整性的；
   覆盖上传会让旧的校验和失效，用户以为文件被篡改。

### 允许的例外（且仅此一类）
- **draft（草稿）Release** 在**转正之前**可以修改/重跑/删除——
  它从未对用户可见。工作流失败后重跑整个流程是**正确做法**（`--clobber` 就是为此设计的）。

### 如果不小心违反了
1. **立刻停止**，不要再做任何 Release 操作
2. 向用户报告：删了/改了什么、原始内容是什么、可否恢复
3. tag 还在的话，Release 可以用 `gh release create <tag> --notes-file docs/changelog/<tag>.md` 重建
   —— 但**必须先经用户批准**
4. 把该场景追加到 §7 变更日志

---

## 5. 发布前检查清单（AI 逐条打勾，缺一不可发）

- [ ] **用户已明确批准**本次发布（§3 审批单已回"批准"）
- [ ] 版本号**递增**（不是等于、不是小于上一版）
- [ ] `tool/bump_version.ps1 -Check` 通过（三处一致）
- [ ] `scripts/check-dev.ps1` **退出码 0**
- [ ] `flutter test` 全绿 + `go test ./...` 全绿
- [ ] `scripts/check-secrets.ps1` clean（**公开仓库，必跑**）
- [ ] `scripts/check-docs.ps1` 通过
- [ ] `docs/changelog/vX.Y.Z.md` 已写并合入（Release 正文的事实源）
- [ ] changelog 的「升级须知」**包含 debug 签名与仅 arm64 两条限制**
- [ ] 若改了播放器：真机走查已过（CI 覆盖不到手势/硬解/布局）
- [ ] 确认**不会删除任何已有 Release**（§4）
- [ ] 真机装上本次 release APK 验过（不是只验 debug 包）
- [ ] 发布后：Releases 页确认**旧版本仍在**、新附件齐全、正文是 changelog

---

## 6. 当前限制（发版时必须如实写进 changelog）

| 限制 | 影响 | 依据 |
|---|---|---|
| **debug 签名** | 仅供自用与体验，**不能正式分发、不能上架商店** | 缺陷 7.16 |
| 仅 **arm64-v8a** 单架构 | 32 位设备与模拟器装不上 | 构建配置 |
| 无 401 自愈 | token 失效需重新登录 | 缺陷 7.7 |
| 无 WakeLock | 播放中可能熄屏 | 缺陷 7.11 |
| 无 Media3 会话层 | 无通知栏控制 / 蓝牙耳机键 / 后台播放 | K3 未做 |
| 115 非公开接口 | 有账号风控风险 | ADR 0007 |

> ⚠️ **debug 签名这条每次都要提**。用户拿去装发现"未知来源"警告是预期行为，
> 但必须**提前说明**，不能让人以为下载到了损坏的包。

---

## 7. 违规记录 / 变更日志

| 日期 | 事件 | 处置 |
|---|---|---|
| 2026-10-05 | 建立本规范 | 用户明确要求：**上传到 GitHub 不删除原有 Release；每次上传前必须增加版本号且经用户审批** |

---

## 8. 参考

- [GitHub: Managing releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
- [GitHub CLI: `gh release`](https://cli.github.com/manual/gh_release)
- [Semantic Versioning 2.0.0](https://semver.org/lang/zh-CN/)（本项目用 `X.Y.Z`，不带预发布标识）
- 仓库内：[`.github/workflows/release.yml`](../.github/workflows/release.yml) ·
  [`.github/skills/cineflow-release/SKILL.md`](../.github/skills/cineflow-release/SKILL.md) ·
  [docs/CHANGELOG-GUIDE.md](CHANGELOG-GUIDE.md)
