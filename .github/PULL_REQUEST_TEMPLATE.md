## 改了什么

<!-- 一句话说明；涉及行为变化时写清「改前 vs 改后」。 -->

## 为什么改

<!-- 关联的缺陷编号（如 §7.15）、issue 或实测结论。 -->

## 验证

按 AGENTS.md §8.1 的必过项逐条勾：

- [ ] `flutter analyze` → 0 error / 0 warning（仅允许 3 条 douban info）
- [ ] `flutter test` → 全绿（当前 25 例）
- [ ] `powershell -File scripts/check-secrets.ps1 --staged` → clean
- [ ] `powershell -File scripts/check-docs.ps1` → 通过
- [ ] `pwsh -File tool/bump_version.ps1 -Check` → 三处版本一致
- [ ] 改了播放器 → 真机播一部片，返回后 `adb shell pidof com.cineflow.app` 仍存活

<!-- 贴实际输出，不要只写「已验证」。§8.3 禁止声称未执行的验证。 -->

## 影响范围

- [ ] 未把「加载失败」伪装成「暂无内容」（§5.5）
- [ ] 未新增 UI 对 `emby_provider.dart` 的直接依赖（§5.1，存量 8 处只减不增）
- [ ] 未跑 `dart format`（§9 明令禁止）
- [ ] 行为有变时已同步 README / docs/DEVELOPMENT.md

## 未验证的部分

<!-- 真机走查没走到哪几步、为什么。留空即表示全部走查过。 -->
