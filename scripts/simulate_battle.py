#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GwentMirror —— 对局数据回放脚本（模拟"昆特记牌器"客户端上报）

桌面端 GwentWanHuaMirror 的 RequestManager.postBattleInfo() 会把从游戏进程内存里
读到的 battleInfo 直接 POST 到服务器的 /battle/api/save。本脚本在没有 Windows 游戏
客户端的环境（例如 Linux 容器 / CI）里，用完全相同的 JSON 结构回放一批对局，
用来验证「客户端脚本 -> 后端入库 -> 前端卡组站」这条链路。

用法：
  python3 simulate_battle.py --base-url http://localhost:8081 --matches 5
  python3 simulate_battle.py --base-url http://localhost:8080/gmapi --matches 3 --print-json

JSON 结构参考：
  backend/.../utils/BeansUtils.java  (battleInfoJsonMapToPlayerList 等)
  desktop/main/dao/CardDao.py        (getBattleInfo 从内存读取的字段名)
"""
import argparse
import json
import random
import sys
import time
import urllib.error
import urllib.request

HEADERS = {
    "User-Agent": "GwentMirror-Replay/1.0",
    "Content-Type": "application/json; charset=UTF-8",
}

# enums/GameEnum.py 中的取值
EGameStatus_ENDED = 3
EGameMode_Client = 1
EBattleType_Ranked = 2
EBattleEndReason_Normal = 0


def http_json(url, method="GET", payload=None, timeout=30):
    data = None
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=HEADERS, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
    return json.loads(raw) if raw.strip() else None


def deck_hash(card_ids):
    """与客户端一致：Python 的 hash(frozenset(ids))；只含 int，结果稳定。"""
    return hash(frozenset(int(x) for x in card_ids))


def pick_seed_decks(base_url, limit=50):
    """从服务器已有卡组里挑真实卡组当作对局双方的牌表，保证前端能正常渲染。"""
    decks = http_json(f"{base_url}/deck/api/getDecks") or []
    decks = [d for d in decks if d.get("sortedCtIds") and len(d["sortedCtIds"]) > 5]
    if not decks:
        sys.exit("服务器上没有可用的卡组数据，请先启动容器或执行 fetch_decks.py")
    random.shuffle(decks)
    return decks[:limit]


def build_battle(deck_a, deck_b, index, player_a, player_b, mmr_a, mmr_b, game_id, unique_decks=False):
    """拼出与桌面端 getBattleInfo() 完全一致的报文。"""

    def player_entry(deck, name, service_id, mmr, mutate=False):
        cards = [int(deck.get("leaderCtId") or 0), int(deck.get("stratagemCtId") or 0)]
        body = [int(c) for c in deck["sortedCtIds"]]
        if mutate and len(body) > 6:
            # 模拟"自己组的牌"：替换掉两张牌，得到一个新的卡组指纹，
            # 这样入库时不会命中 existing 卡组的 ON DUPLICATE KEY。
            body = body[:-2] + [int(deck_b["sortedCtIds"][0]), int(deck_b["sortedCtIds"][1])]
        cards += body
        return {
            "player_name": name,
            "service_id": service_id,
            "paragon_level": 0,
            "MMR": mmr,
            "rank": 0,
            "leader_id": int(deck.get("leaderCtId") or 0),
            "stratagem_id": int(deck.get("stratagemCtId") or 0),
            "faction_id": int(deck.get("factionId") or 0),
            "decks": cards,           # leader + stratagem + 牌表，客户端原样上报
            "deckId": deck_hash(cards),
        }

    winner = 1 if index % 2 == 0 else 2
    return {
        "GameStatus": EGameStatus_ENDED,
        "GameMode": EGameMode_Client,
        "GameId": game_id,
        "BattleType": EBattleType_Ranked,
        "roundInfos": [
            {"index": 0, "left_score": 12, "right_score": 8, "starting_playerId": 1,
             "winner_playId": 1, "turn_index": 11},
            {"index": 1, "left_score": 6, "right_score": 14, "starting_playerId": 2,
             "winner_playId": 2, "turn_index": 9},
            {"index": 2, "left_score": 21, "right_score": 17, "starting_playerId": 1,
             "winner_playId": winner, "turn_index": 14},
        ],
        "curr_round_index": 2,
        "winner_playId": winner,
        "end_game_reason": EBattleEndReason_Normal,
        "players": [
            player_entry(deck_a, player_a, 900000000000000001 + index, mmr_a, mutate=unique_decks),
            player_entry(deck_b, player_b, 900000000000000002 + index, mmr_b),
        ],
    }


def main():
    ap = argparse.ArgumentParser(description="回放昆特对局数据到 GwentMirror 服务")
    ap.add_argument("--base-url", default="http://localhost:8081",
                    help="后端地址，容器内为 http://localhost:8081，对外为 http://localhost:8080/gmapi")
    ap.add_argument("--matches", type=int, default=5, help="回放对局数量")
    ap.add_argument("--player-a", default="GwentMirror_Demo_A")
    ap.add_argument("--player-b", default="GwentMirror_Demo_B")
    ap.add_argument("--print-json", action="store_true", help="打印第一条报文")
    ap.add_argument("--sleep", type=float, default=0.2, help="每条之间的间隔秒数")
    ap.add_argument("--unique-decks", action="store_true",
                    help="把玩家 A 的牌表换掉两张牌，生成新卡组指纹（模拟玩家自己组的牌，入库可见）")
    args = ap.parse_args()

    base = args.base_url.rstrip("/")
    print(f"[replay] 目标服务: {base}")
    decks = pick_seed_decks(base)
    print(f"[replay] 取到 {len(decks)} 个种子卡组，开始回放 {args.matches} 场对局 ...")

    ok = 0
    for i in range(args.matches):
        deck_a = decks[i % len(decks)]
        deck_b = decks[(i + 7) % len(decks)]
        game_id = int(time.time() * 1000) + i
        battle = build_battle(
            deck_a, deck_b, i, args.player_a, args.player_b,
            mmr_a=9600 + i * 7, mmr_b=9450 + i * 5, game_id=game_id,
            unique_decks=args.unique_decks,
        )
        if args.print_json and i == 0:
            print("[replay] 示例报文:")
            print(json.dumps(battle, ensure_ascii=False, indent=2)[:1600], "...\n")
        try:
            http_json(f"{base}/battle/api/save", method="POST", payload=battle)
            ok += 1
            win = battle["winner_playId"]
            print(f"[replay] #{i + 1} gameId={game_id} "
                  f"{battle['players'][0]['player_name']} vs {battle['players'][1]['player_name']} "
                  f"-> 胜者 player{win}")
        except urllib.error.HTTPError as e:
            print(f"[replay] #{i + 1} 失败: HTTP {e.code} {e.read()[:200]!r}")
        except Exception as e:  # noqa: BLE001
            print(f"[replay] #{i + 1} 失败: {e}")
        time.sleep(args.sleep)

    print(f"[replay] 完成: {ok}/{args.matches} 条上报成功")
    try:
        latest = http_json(f"{base}/deck/api/getRandomDecksLast?num=5") or []
        print("[replay] 服务器上最新的卡组（前端首屏随机推荐的来源）:")
        for d in latest[:5]:
            print(f"   - {d.get('deckName')} / {d.get('deckAuthor')} / "
                  f"faction={d.get('factionId')} cards={len(d.get('sortedCtIds') or [])}")
    except Exception as e:  # noqa: BLE001
        print(f"[replay] 读取最新卡组失败: {e}")


if __name__ == "__main__":
    main()