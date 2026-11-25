#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GwentMirror —— 官网卡组抓取脚本（GwentWanHuaMirror/othersFile/抓取卡组-官网.py 的容器化版本）

原脚本依赖 GUI 的全局配置与 multiprocessing.Pool，这里改成纯命令行 + 线程池，
既能在宿主机跑，也能在容器里跑：

  python3 fetch_decks.py --base-url http://localhost:8081 --since-days 7 --limit 60

流程：
  1. GET  {server}/deck/api/maxid            -> 本地库里已有官网卡组 id 的最大值
  2. GET  https://www.playgwent.com/en/decks/api/guides/offset/0/limit/500
                                            -> 官网最新卡组列表，过滤出比 maxid 新的
  3. GET  https://www.playgwent.com/en/decks/api/guides/{id}
                                            -> 单卡组详情，转成 DeckJson
  4. POST {server}/deck/api/post             -> 批量入库（ON DUPLICATE KEY 累加 total）
"""
import argparse
import datetime as dt
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

GWENT_API = "https://www.playgwent.com/en/decks/api"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

FACTION_MAP = {
    "monsters": 2,
    "nilfgaard": 4,
    "northernrealms": 8,
    "scoiatael": 16,
    "skellige": 32,
    "syndicate": 64,
}


def http_json(url, payload=None, timeout=30):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method="POST" if payload is not None else "GET",
        headers={"User-Agent": UA, "Content-Type": "application/json; charset=UTF-8"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
    return json.loads(raw) if raw.strip() else None


def transListCtIdToHash(decks):
    """与原脚本一致：无顺序依赖的卡组指纹，用作 deck.id（主键去重）。"""
    return hash(frozenset(int(x) for x in decks))


def parse_time(text):
    for fmt in ("%Y-%m-%dT%H:%M:%S+0000", "%Y-%m-%dT%H:%M:%S+00:00", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return dt.datetime.strptime(text, fmt)
        except ValueError:
            continue
    return dt.datetime.utcnow()


def fetch_deck_info(deck_id):
    try:
        detail = http_json(f"{GWENT_API}/guides/{deck_id}")
    except Exception as e:  # noqa: BLE001
        print(f"  ! {deck_id} 拉取失败: {e}")
        return None

    src = detail["deck"]["srcCardTemplates"]
    card_ids = list(src.values()) if isinstance(src, dict) else list(src)

    info = {
        "deckId": transListCtIdToHash(card_ids),
        "sortedCtIds": card_ids,
        "leaderCtId": detail["leaderId"],
        "stratagemCtId": (detail.get("stratagem") or {}).get("id") or 0,
        "time": int(parse_time(detail["modified"]).timestamp() * 1000),
        "deckName": detail.get("name") or "",
        "deckAuthor": detail.get("author") or "",
        "webDeckId": detail["id"],
        "factionId": FACTION_MAP.get((detail.get("faction") or {}).get("slug", ""), 0),
    }
    print(f"  + {info['webDeckId']:>8}  {info['deckName'][:40]:<40} "
          f"{len(card_ids):>3} 张  faction={info['factionId']}")
    return info


def main():
    ap = argparse.ArgumentParser(description="抓取官网卡组并写入 GwentMirror")
    ap.add_argument("--base-url", default="http://localhost:8081")
    ap.add_argument("--since-days", type=int, default=30, help="抓取最近多少天内发布的卡组")
    ap.add_argument("--limit", type=int, default=60, help="最多抓取多少个卡组")
    ap.add_argument("--workers", type=int, default=5)
    ap.add_argument("--dry-run", action="store_true", help="只抓取不入库")
    args = ap.parse_args()

    base = args.base_url.rstrip("/")
    since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=args.since_days)

    print(f"[crawl] 目标服务 : {base}")
    print(f"[crawl] 时间范围 : 最近 {args.since_days} 天")

    try:
        max_web_id = int(http_json(f"{base}/deck/api/maxid") or 0)
    except Exception as e:  # noqa: BLE001
        if not args.dry_run:
            sys.exit(f"无法连接服务端 {base}: {e}")
        max_web_id = 0
        print(f"[crawl] 服务端不可达（dry-run 模式继续）: {e}")
    print(f"[crawl] 库内最大官网卡组 id: {max_web_id}")

    listing = http_json(f"{GWENT_API}/guides/offset/0000/limit/500")
    candidates = []
    for guide in listing.get("guides", []):
        created = parse_time(guide["createdAt"])
        if created.replace(tzinfo=dt.timezone.utc) < since:
            continue
        if int(guide["id"]) <= max_web_id:
            continue
        candidates.append(int(guide["id"]))

    candidates = sorted(candidates, reverse=True)[: args.limit]
    print(f"[crawl] 发现 {len(candidates)} 个新卡组，开始抓取详情 ...")
    if not candidates:
        print("[crawl] 没有新卡组，结束。")
        return

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = [r for r in pool.map(fetch_deck_info, candidates) if r]

    print(f"[crawl] 详情抓取完成: {len(results)}/{len(candidates)}")
    if args.dry_run or not results:
        return

    http_json(f"{base}/deck/api/post", payload=results)
    print(f"[crawl] 已批量写入服务端: {len(results)} 个卡组")
    newest = http_json(f"{base}/deck/api/getRandomDecksLast?num=3") or []
    for d in newest[:3]:
        print(f"        {d.get('deckName')} / {d.get('deckAuthor')}")


if __name__ == "__main__":
    main()