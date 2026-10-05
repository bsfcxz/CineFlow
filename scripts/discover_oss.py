#!/usr/bin/env python3
"""发现可用的 GitHub 参考项目（新增技能 / 遇到不会的技术时必跑）。

用法:
    python scripts/discover_oss.py "flutter go ffi bridge" \
        [--lang go] [--min-stars 50] [--per-page 20] [--json] [--write]

    # 核验证 bary：核实某个仓库是否活?、许可、最近提交（引预之前必核）
    python scripts/discover_oss.py --verify getlantern/lantern SheltonZhu/115driver

    # 按领域配置文件里的预设搜索式跑一遍
    python scripts/discover_oss.py --area bridge --write

说明:
- 未设 GITHUB_TOKEN 时用匿名接口（搜索 10 次/分），够用；设了更好:
    export GITHUB_TOKEN=xxx（或其他 repo 名 eth_tkn）
- 本脚本只负责"找候选 + 给证据"，**不下结论**。入选与否由 Architect + Captain 按
  docs/review-checklist.md 判定（协议合规、是否有 AGENTS.md/CLAUDE.md、是否能跑通）。
- 引预之前必须 --verify：不要凭记忆写仓库名。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

API = "https://api.github.com"

# 领域预设搜索式（与 docs/TECH-SKILLS.md 的 S1-S9 对应）
AREA_QUERIES = {
    "bridge": ["flutter golang ffi binding", "flutter go bridge dart ffi", "gomobile bind dart flutter"],
    "emby": ["emby client flutter", "jellyfin emby client flutter media_kit", "emby api client go"],
    "player": ["media_kit libmpv flutter", "flutter player libass ass subtitle", "tv remote dpad flutter player"],
    "danmaku": ["dandanplay danmaku api", "弹幕 api self-host dandanplay compatible", "mpv danmaku plugin"],
    "115": ["115driver go", "115 网盘 api driver", "openlist storage driver"],
    "multiply": ["flutter desktop tv responsive player", "flutter isolate ffi blocking ui"],
}

FIELDS_SOURCE = "资料来源：GitHub Search API；stars/更新日期以实际返回为准。"


def _get(url: str, token: str | None) -> tuple[int, dict | list]:
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "cineflow-oss-search")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        body = {}
        try:
            body = json.loads(e.read().decode("utf-8", "replace"))
        except Exception:
            pass
        return e.code, body
    except Exception as e:  # 网络问题
        return 0, {"message": str(e)}


def months_since(iso: str) -> float | None:
    if not iso:
        return None
    try:
        dt = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return (datetime.now(timezone.utc) - dt).days / 30.44


def score(repo: dict) -> float:
    """让候选可以按'能否参考'排序：stars 取对数抑制强者通吃，搭配新鲜度与许可。"""
    s = math.log10(max(repo.get("stargazers_count", 0), 1)) * 10
    m = months_since(repo.get("pushed_at") or repo.get("updated_at"))
    if m is None:
        s -= 5
    elif m <= 3:
        s += 12
    elif m <= 12:
        s += 7
    elif m <= 24:
        s += 2
    else:
        s -= 6
    lic = (repo.get("license") or {}).get("spdx_id") or ""
    if lic in {"MIT", "Apache-2.0", "BSD-3-Clause", "GPL-3.0", "MPL-2.0"}:
        s += 4
    elif lic in {"NOASSERTION", ""}:
        s -= 3
    else:
        s -= 1
    if repo.get("open_issues_count", 0) > 0:
        s += 1  # 有 issue 才有坑可读
    return round(s, 1)


def search(query: str, token: str | None, lang: str | None, per_page: int) -> list[dict]:
    q = query
    if lang:
        q = f"{q} language:{lang}"
    url = f"{API}/search/repositories?{urllib.parse.urlencode({'q': q, 'sort': 'stars', 'order': 'desc', 'per_page': per_page})}"
    code, data = _get(url, token)
    if code == 403:
        print("[限速] GitHub 匿名搜索限速（10 次/分）。等 60s 重试，或 export GITHUB_TOKEN=...", file=sys.stderr)
        return []
    if code == 0:
        print(f"[网络失败] {data.get('message')}", file=sys.stderr)
        return []
    if code != 200:
        print(f"[失败] HTTP {code}: {data.get('message', '')}", file=sys.stderr)
        return []
    items = data.get("items", []) if isinstance(data, dict) else []
    return items


def verify(repos: list[str], token: str | None) -> int:
    bad = 0
    print(f"{'仓库':<44}{'stars':>8}{'最近提交':>12}  {'许可':<16}{'未合 issue':>10}")
    print("-" * 96)
    for full in repos:
        code, r = _get(f"{API}/repos/{full.strip()}", token)
        if code != 200:
            print(f"{full:<44} -> 核实失败 HTTP {code} {r.get('message','')}")
            bad += 1
            continue
        pushed = (r.get("pushed_at") or "")[:10] or "?"
        lic = ((r.get("license") or {}).get("spdx_id") or "NOASSERTION")
        print(f"{r.get('full_name', full):<44}{r.get('stargazers_count', 0):>8}{pushed:>12}  {lic:<16}{r.get('open_issues_count',0):>10}")
        m = months_since(r.get("pushed_at"))
        if m is not None and m > 30:
            print("    └ 警示：超过 30 个月未更新，参考前先确认是否还适用（API 可能已变）。")
        if lic == "NOASSERTION":
            print("    └ 警示：无明确许可，抄代码前必须确认（AGENTS.md §4.1 与合规要求）。")
            bad += 1
        time.sleep(0.4)
    print("-" * 96)
    print(FIELDS_SOURCE)
    return bad


def main() -> int:
    ap = argparse.ArgumentParser(description="GitHub 参考项目发现与核实")
    ap.add_argument("query", nargs="*", help="搜索关键词（空格分隔成一个查询串）")
    ap.add_argument("--area", help="按领域预设跑： " + ", ".join(AREA_QUERIES))
    ap.add_argument("--lang", help="限定语言，如 go / dart / rust")
    ap.add_argument("--min-stars", type=int, default=30)
    ap.add_argument("--per-page", type=int, default=15)
    ap.add_argument("--verify", nargs="+", metavar="OWNER/REPO", help="核实指定仓库")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--write", action="store_true", help="把候选追加到 docs/OSS-SOURCES.md（标为待核）")
    a = ap.parse_args()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")

    if a.verify:
        return verify(a.verify, token)

    queries: list[str] = []
    if a.area:
        if a.area not in AREA_QUERIES:
            print(f"[失败] 未知领域 {a.area}；可用：{', '.join(AREA_QUERIES)}", file=sys.stderr)
            return 2
        queries = AREA_QUERIES[a.area]
    elif a.query:
        queries = [" ".join(a.query)]
    else:
        ap.print_help()
        return 2

    seen: dict[str, dict] = {}
    for q in queries:
        print(f"== 查询：{q} ==", file=sys.stderr)
        for r in search(q, token, a.lang, a.per_page):
            fn = r.get("full_name")
            if fn and fn not in seen:
                seen[fn] = r
        time.sleep(0.6)

    rows: list[dict] = []
    for r in seen.values():
        if (r.get("stargazers_count") or 0) < a.min_stars:
            continue
        m = months_since(r.get("pushed_at"))
        rows.append({
            "repo": r.get("full_name"),
            "stars": r.get("stargazers_count", 0),
            "months": round(m, 1) if m is not None else None,
            "license": ((r.get("license") or {}).get("spdx_id") or "NOASSERTION"),
            "issues": r.get("open_issues_count", 0),
            "score": score(r),
            "desc": (r.get("description") or "")[:70],
            "url": r.get("html_url"),
        })
    rows.sort(key=lambda x: -x["score"])

    if not rows:
        print("[结果] 没有满足条件的候选。放宽 --min-stars 或换关键词。")
        return 1

    if a.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        print(f"{'仓库':<44}{'stars':>7}{'月内更新':>9}{'分':>6}  {'许可':<14}说明")
        print("-" * 118)
        for x in rows:
            months = "?" if x["months"] is None else f"{x['months']:.0f}"
            print(f"{x['repo']:<44}{x['stars']:>7}{months:>9}{x['score']:>6}  {x['license']:<14}{x['desc']}")
        print("-" * 118)
        print("排分思路：stars 取对数 + 新鲜度（3 月内 +12，超 2 年 -6）+ 许可明确与否。仅供参考，**入选要人工裁定**。")
        print(FIELDS_SOURCE)

    if a.write:
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "OSS-SOURCES.md")
        if not os.path.exists(path):
            print(f"[失败] 找不到 {path}", file=sys.stderr)
            return 1
        stamp = datetime.now().strftime("%Y-%m-%d")
        lines = [f"\n### 自动发现候选 · {stamp}（{', '.join(queries)}）\n",
                 "| 仓库 | stars | 最近(月) | 许可 | 用途/借鉴点（待补） | 状态 |",
                 "|---|---|---:|---|---|---|"]
        for x in rows[:8]:
            m = "?" if x["months"] is None else f"{x['months']:.0f}"
            lines.append(f"| [{x['repo']}]({x['url']}) | {x['stars']} | {m} | {x['license']} | 待补 | 待核 |")
        lines.append("\n> 由 scripts/discover_oss.py 生成，尚未核实与评审；借用前必须 --verify 并写进 ADR。\n")
        with open(path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines))
        print(f"[已追加] {len(rows[:8])} 条候选写入 {path}（状态：待核）。")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
