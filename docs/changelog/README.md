# 发布说明（Release notes）

> 每版一份 `vX.Y.Z.md`，文件名即 git tag 名（去掉 `v` 前缀前先对齐）。
> 本目录是 **Release body 的事实源**：`.github/workflows/release-notes.yml`
> 会把这里的每份文件同步成同名 tag 的 GitHub Release 正文。

## 为什么走「文件 + 同步」而不是手工填 Release

- 发布说明随代码走 PR 评审，不再是发版后补写的口头产物；
- 换人或隔了半年回来，能从 git 里查到「当时这版到底说了什么」；
- 远程会话（AI/CLI）没有编辑 Release 的 API 权限，但能合 PR——借这条通道即可完成全流程。

对应 Release 还不存在的文件会被跳过，等 Release 创建后再触碰该文件即会自动同步。

## 与 CHANGELOG.md 的分工

| 文件 | 写给谁 | 粒度 |
|---|---|---|
| `docs/changelog/vX.Y.Z.md` | **用户**——决定要不要更新、更新后去试什么 | 每版一份，产品更新说明 |
| `CHANGELOG.md`（仓库根） | **开发者/代理**——快速看版本演进与缺陷修复 | 累计历史，偏工程视角 |

两者都要写，但**用户向的说明只在本目录**。

## 撰写规范

动笔前必读 [docs/CHANGELOG-GUIDE.md](../CHANGELOG-GUIDE.md)。一句话概括：
先用 `git log` 盘点保证不漏 → 挑 1～3 个亮点按「痛点 → 现在 → 入口」写 →
修复只写用户能认出的症状 → 其余交给文末 compare 链接。

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本：建立 docs/changelog/ 目录约定（release-notes 随发版同步），并写入 v0.2.0 首个公开版说明 |
