# 贡献指引

感谢你愿意花时间改进 CineFlow。

## 开工前先读

1. **[AGENTS.md](AGENTS.md)** —— 项目红线、硬性约定、已知的坑、**缺陷台账 §7**（你要修的可能已在案）。
2. **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** —— 架构决策与踩坑实录。
3. **[docs/review-checklist.md](docs/review-checklist.md)** —— 提交前自查清单。

几条最容易踩的：

- **不要跑 `dart format`**：当前代码库未遵循它，一次格式化会改动 24/26 个文件，
  制造数千行无关 diff。只对你手改的片段保持可读性。
- **不要把「加载失败」伪装成「暂无内容」**：失败要显示错误页 + 重试。
- **UI 不要新增对 `emby_provider.dart` 的直接依赖**（存量 8 处只减不增），
  新能力先定义到 `lib/data/media_provider.dart`。
- **未接入的功能走 `showComingSoon`**，不要留死按钮、也不要假装已实现。

## 提交前必过

```bash
flutter analyze            # 必须 0 error / 0 warning
flutter test               # 必须全绿（当前 25 例）
powershell -File scripts/check-secrets.ps1 --staged
powershell -File scripts/check-docs.ps1
pwsh -File tool/bump_version.ps1 -Check      # 版本号三处一致
```

改了播放器还要真机验：播放 → 返回 → `adb shell pidof com.cineflow.app` 必须存活
（这是 libmpv dispose 崩溃的回归线）。

## 安全

**任何真实凭据（Token / Cookie / 密码 / 服务器地址 / 密钥）都不得进提交。**
这是公开仓库，提交前请自行脱敏。发现仓库里有凭据请私下反馈，不要开公开 issue。

## 许可

本项目采用 Apache-2.0。你提交的代码即视为按此许可授权。
