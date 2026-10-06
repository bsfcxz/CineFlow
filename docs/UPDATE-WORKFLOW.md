# 更新工作流 · AI 驱动的项目文档更新

> 本文件定义 **CineFlow 的文档/计划/契约类更新** 如何由 AI 协作完成。
> 代码更新走 `cineflow-workflow` 的六段流水线；本文件只管**文档与契约**这一类。
> 本文件自身也走本流程更新（G5：历史行只增不改）。

## 0. 更新范围

| 类型 | 触发条件 | 职责 Agent | 影响文件 |
|---|---|---|---|
| AGENTS.md 更新 | 角色/工作流/门禁/红线变化 | Captain + Docs | `AGENTS.md` |
| 看板更新 | 任务新增/完成/阻塞/取消 | Captain | `docs/task-board.md` |
| 架构决策更新 | 接口变更、模块边界调整、依赖引入 | Architect | `docs/decisions/`、`docs/architecture.md` |
| 接口文档更新 | `MediaProvider` 契约变化 | Architect | `docs/architecture.md`、`lib/data/media_provider.dart` |
| 审查清单更新 | 新增否决项、门禁变化 | Review + Docs | `docs/review-checklist.md` |
| 发布文档更新 | 发版、安装说明、合规说明 | Release + Docs | `README.md`、`CHANGELOG.md` |
| 技能更新 | 新增或调整技能（含新增能力、新工具） | Captain + Architect + Docs | `.github/skills/*/SKILL.md`、`docs/TECH-SKILLS.md`、`docs/OSS-SOURCES.md` |
| 开源借鉴更新 | 引用新参考项目、旧引用失效/许可变化 | Architect | `docs/OSS-SOURCES.md`、`docs/TECH-SKILLS.md` 对应章节 |
| 经验沉淀 | 踩坑、反模式、工具链变化 | Owner + Test | `docs/lessons/` |

## 1. 流程

```text
触发 → 收变更 → 任务卡 → 草案 → 审查 → 合并 → 记录
```

| 段 | 谁 | 做什么 |
|---|---|---|
| 触发 | 人类 / Captain / Review | 提出更新需求，或审查中发现"文档已漂移" |
| 收变更 | Captain | 明确目标与范围、收集上下文、识别受影响 Agent 与目录、判断是否需 ADR |
| 任务卡 | Captain | 按模板建卡（类型/验收标准/`non_goals`/影响文件），写进 `docs/task-board.md` |
| 草案 | Docs / Architect / Owner / Release | 只动被授权的文件 |
| 审查 | Review Agent | 按 `docs/review-checklist.md` §6 逐条；输出通过/驳回 + 必改项（文件:行号） |
| 合并 | Captain | 确认通过后合并、同步看板状态、折叠上下文 |
| 记录 | Docs / Captain | 版本号递增 + 变更日志 + 相关 ADR 链接 |

## 2. 任务卡模板

```yaml
id: CF-P4-DOCS-001
type: agents-update | doc-update | adr | checklist-update | code-update
title: 把降级契约纳入质量门禁
owner: docs
reviewers: [captain, review]
depends_on: []
context_files:
  - AGENTS.md
  - docs/UPDATE-WORKFLOW.md
  - docs/task-board.md
  - .github/skills/cineflow-workflow/references/gates.md
goal: AGENTS.md §8 与 §9 DoD 中新增"降级契约测试"必跑项，并同步审查清单
acceptance:
  - AGENTS.md §8 命令表含降级契约测试
  - AGENTS.md §9 DoD 新增对应勾选项
  - docs/review-checklist.md §4 增加勾选项
  - scripts/check-docs.ps1 通过（链接未断）
  - 版本号与变更日志已更新
non_goals:
  - 不修改其他章节
test_plan:
  - 人工检查 Markdown 链接有效性（scripts/check-docs.ps1）
  - 与 AGENTS.md 其他章节一致性比对
deliverables:
  - AGENTS.md
  - docs/review-checklist.md
status: todo
```

## 3. 上下文加载（禁止整仓）

1. `AGENTS.md`
2. 本文件
3. 当前任务卡
4. 被更新文件的当前版本
5. 相关 ADR / 架构契约段（接口变更时）

**禁止**一次性加载整个仓库；**禁止**在未加载当前版本的情况下直接出草案。

## 4. 质量门禁（合并前）

- [ ] 任务卡验收标准全部满足
- [ ] Review Agent 通过（`docs/review-checklist.md` §6）
- [ ] `scripts/check-docs.ps1` 通过（无断链、必文档齐全）
- [ ] 版本号已递增、`VERSION` 与 `CHANGELOG.md` 一致
- [ ] 变更日志已更新且历史行未删
- [ ] 无敏感信息（`scripts/check-secrets.ps1 --staged`）
- [ ] 未破坏 `MediaProvider` 抽象层
- [ ] 与 `AGENTS.md` 无冲突
- [ ] 涉及技能新增 → 已跑 `python scripts/discover_oss.py --area <领域>` 并核实，附「借鉴来源」清单
- [ ] 涉及第三方仓库 → `--verify` 结果与 `docs/OSS-SOURCES.md` 一致；GPL/AGPL 未合并源码
- [ ] 相关 ADR 已创建/更新（涉及架构变更时）
- [ ] 提示词模板（若涉及）与实际使用的角色提示同步

## 5. 版本规则

每个被更新文件自带变更日志表：

| 版本 | 日期 | 变更 | 负责人 |
|---|---|---|---|
| v1.0 | 2026-10-04 | 初始版本 | Captain |

- **主版本**：战略调整、架构重大变化
- **次版本**：新增章节、流程变化
- **修订号**：文字修正、链接更新、格式调整

## 6. 禁止事项

- 跳过任务卡直接改文件
- 跳过 Review 合并
- 引入未讨论的重大依赖
- 删除历史变更日志/看板历史
- 修改未授权目录
- 文档里写入真实 Token、Cookie、服务器地址、内网地址
- 分流比：`docs/decisions/` 的 ADR 不得脱节（有决策必有一份 ADR）
- Agent 提示词模板与角色清单不同步（改了角色就改 `docs/PROMPT-TEMPLATES.md`）
- 文档写得比代码乐观（"已实现"而代码里是 `showComingSoon`，见 AGENTS §7.10）

## 7. 快速启动提示词

```text
你正在 CineFlow 项目中工作。
请阅读 AGENTS.md 和 docs/UPDATE-WORKFLOW.md。
更新需求：{描述}
请以 Captain 身份判定更新类型，生成任务卡，分配 owner 与 reviewer（不要直接修改文件）。
输出：任务卡 YAML、上下文文件列表、验收标准、non_goals。
```

---

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本，定义文档/契约类更新的任务卡流水线、门禁与版本规则 |
| v1.1 | 2026-10-04 | 按本仓库实际技术栈改写：门禁命令改为 `scripts/check-docs.ps1` / `check-secrets.ps1`（原 `.sh` 在本机沙箱下不可执行）；更新范围表去掉计划书与桥接 proto 两项（无 Go 层，见 ADR 0002）；新增「文档不得比代码乐观」禁止项 |
