# 追剧日历 · 实测取证记录（Bangumi 不可达的完整证据链）
#
# 本文件是**证据留档**，不是实现文档。目的是让下一个人不必重踩。
# 所有结论都来自 2026-10-11 的真实请求。

## 一、Bangumi（api.bgm.tv）—— **Dart/Android 无法连接**

### 测试矩阵（同一时刻、同一台机器）
| 客户端 | TLS 实现 | 校验 | 结果 |
|---|---|---|---|
| Python urllib | **OpenSSL** | 开 | ✅ 200 / 77,596 B |
| Python urllib | **OpenSSL** | 关 | ✅ 200 / 77,596 B |
| curl.exe | **Schannel**（Windows 原生） | 开 | ❌ exit 35 `Connection was reset` |
| curl.exe | **Schannel** | 关 | ❌ exit 35 同上 |
| Dart dio | **BoringSSL** | 默认 | ❌ `HandshakeException: Connection terminated during handshake` |
| Dart dart:io 直发 | **BoringSSL** | 默认 | ❌ `SocketException: HTTP connection timed out` |
| **Android 真机 curl** | **Android/BoringSSL** | 默认 | ❌ HTTP 000 |
| Python **走代理 7897** | OpenSSL（代理转发） | 开 | ✅ 200 / 77,596 B |

### 结论
**Bangumi 的 WAF 按 "TLS 指纹" 拦截**，而不是按 IP：
- 同一个出口 IP：Python（OpenSSL）能过，curl（Schannel）不能过
- 走代理换出口 IP 后，Python 依然能过 ⇒ **不是 IP 封锁**
- Android 真机同样失败 ⇒ **不是 Windows 特有**

⇒ **Dart 侧无法修复**（改不了 BoringSSL 的 ClientHello 指纹）。

### 排除过的替代路径（全部实测失败）
| 尝试 | 结果 |
|---|---|
| `https://api.bgm.tv/calendar` | ❌ 握手被断 |
| `https://bgm.tv/calendar` | ❌ 握手被断 |
| `https://www.bgm.tv/` | ❌ 握手被断 |
| `http://api.bgm.tv/calendar`（明文，绕 TLS） | ❌ 连接超时 |
| 浏览器 UA + Accept + Referer 伪装 | ❌ 握手被断 |
| 显式 TLS 版本 / ALPN 组合 | ❌ 全部失败 |

### 曾经"成功"的假象
开发早期 Python 探测**连续 3 次成功**（0.7s / 77,594 B），
让我以为"只有 Dart 有问题"。后续发现：
- Python **一直**能连（现在仍能）
- 当时 Dart 也在同一 IP 上失败
⇒ 那个"成功"是**真的**，只是**不同 TLS 栈的结果不同**，
   不能用来推断"Dart 应该也能连"。

### 务实处置（已写进实现）
1. **保留 Bangumi 源**：它在**用户网络环境正常时可用**
   （用户可能走代理、或 BoringSSL 指纹未被拦）
2. **失败必须静默降级**：不能让 Bangumi 拖垮整个日历
   （已有"失败隔离"：单源失败只显示一行提示）
3. **不缓存失败**：否则一次失败会让日历空半小时
4. **不重试超过 1 次**：避免加重 WAF 判定

## 二、TVmaze —— ✅ 可用（真机 200 / 243 KB）

### 实测坑（必须处理，否则数据错）
1. **`?date=` 过滤的是"电视台本地日"，不是 `airdate`**
   请求 02-10 返回 168 条，其中 8 条 `airdate=02-09`；
   全部换算到电视台本地时区后偏离数 **0/168**。
   ⇒ 必须请求 **date±1**，再按 **UTC+8** 重新分桶。
2. **`/schedule/web` 的 show 在 `_embedded.show`**（顶层无 `show`）
   `/schedule` 则在顶层 `show`。**两个端点结构不同**。
   我第一版只读顶层 ⇒ 整源 0 条（真网测试抓到）。
3. **限额 20 次/10 秒/IP** ⇒ 9 天 × 2 端点 = 18 次，
   正好卡在边缘 ⇒ 已改**分批 + 批间 700ms**。

### 收益
修复后：**0 条 → 1,676 条**，7 天分布 267/223/274/274/269/265/104。

## 三、B站时间线 —— ✅ 可用（真机 200 / 8.9 KB）

### 实测坑
1. **`before`/`after` 硬上限 7**：`before=8` → `code=-400`
2. **`date` 字段没有年份**（`"10-5"`）⇒ `DateTime.tryParse` 必然失败
   必须用 **`date_ts`**（Unix 秒，北京时间当天 0 点）推日期
3. **`types=1,4`** 才含**国创**（`types=1` 只有番剧）
4. **必须带 `Referer: https://www.bilibili.com/`**

### 我犯的错
第一版直接用 `date` 字符串 ⇒ 全部解析失败 ⇒ 全归周一。
真网测试显示"56 条 → 合并后 8 条"（去重 86%），
**其中一半原因是 date 解析失败 + 我的去重 key 不含集数**。

## 四、去重：真网测试抓到**过度去重**

第一版 key = `(星期, 归一化标题)`，结果：
```
各源合计 56 条 → 合并后 8 条（去重 48 条 = 86%）
```
根因（看 B站原始数据）：
```
10-5  小车队大救援：自然护卫队  pub=第14话  season=298872
10-6  小车队大救援：自然护卫队  pub=第15话  season=298872  ← 同剧不同集
```
⇒ key **必须含日期/集数**。修正后去重率 **30%**（合理）。

⚠️ 教训：**"去重率高"看起来像好事，实际是数据丢失**。
   必须用"合并后不应少于一半"这类**下界断言**守住。

## 五、明确不做的源（都有实测证据）

| 源 | 证据 | 结论 |
|---|---|---|
| **爱奇艺** | MoviePilot 插件逆向的接口返回 `{"code":0, "extData":{"dataExtRisk":{"risk_level":2}}}`，**连 `data` 字段都没有** | 风控，不做 |
| **腾讯 / 优酷** | MoviePilot-Plugins 全量 tree（1,779 项）只有 `iqiyidiscover`/`tvdbdiscover`；优酷首页直接返回 `_____tmd_____/punish?x5secdata=...` | 无可靠接口，不做 |
| **trakt** | 无 client_id 一律 **403**；本机三种 header 组合全 403 | 需用户注册，不做 |
| **豆瓣** | 需 HMAC-SHA1 签名 + 客户端指纹伪装，且端点全是榜单、**无按日期** | 不做 |
| **TMDB** | key 有效（带 key 200 / 无 key 401），但**无按日端点**（`on_the_air` 不告诉你哪天） | 仅作辅助 |

## 六、TMDB key 有效性证明（用户提供的 key）
```
tv/on_the_air   带key=200  无key=401  ✅ 有效
tv/popular      带key=200  无key=401  ✅ 有效
configuration   带key=200  无key=401  ✅ 有效
search/tv       带key=200  results=20 ✅ 有效
account         带key=401（该端点需用户 OAuth，不代表 key 无效）
```
⚠️ **该 key 未写入仓库**（安全红线），仅存在于仓库外的探测脚本中。
