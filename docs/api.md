# 接口

所有接口都在 8081；浏览器侧统一走 `/gmapi/*`，由 nginx 去掉前缀转发到 8081。

## 卡组

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/deck/api/getDecks` | 取最多 5000 个卡组（客户端本地卡组库同步用） |
| GET | `/deck/api/getDecksByIds?ids=1,2,3&page=0` | 按包含的卡牌检索卡组，`page=0` 不分页 |
| GET | `/deck/api/getRandomDecksLast?num=50` | 版本水位之后的最新卡组，随机取 N 个 |
| GET | `/deck/api/maxid` | 库内最大的官网卡组 id（爬虫增量用） |
| POST | `/deck/api/post` | 批量写入爬虫卡组（`List<DeckJson>`） |

`getDecksByIds` 的返回按 `update_time` 倒序；`page>0` 时每页 5 条。
`getRandomDecksLast` 的 `num=0` 表示「不分页、全量返回」。

## 对局

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/battle/api/save` | 接收记牌器战报 |

报文结构（字段与 `desktop/main/dao/CardDao.py:getBattleInfo()` 一一对应）：

```jsonc
{
  "GameStatus": 3, "GameMode": 1, "GameId": 1732..., "BattleType": 2,
  "roundInfos": [{ "index": 0, "left_score": 12, "right_score": 8,
                   "starting_playerId": 1, "winner_playId": 1, "turn_index": 11 }, ...],
  "curr_round_index": 2, "winner_playId": 1, "end_game_reason": 0,
  "players": [
    { "player_name": "...", "service_id": 900000000000000001, "paragon_level": 0,
      "MMR": 9600, "rank": 0, "leader_id": 200087, "stratagem_id": 0, "faction_id": 4,
      "decks": [200087, 0, 202115, 201779, ...],   // leader + stratagem + 牌表
      "deckId": 1234567890123456789 }              // hash(frozenset(decks))
  ]
}
```

服务端拆成 `player` / `deck` / `battle` / `player_battle_info` 四张表，一个事务写完
（细节见 [database.md](database.md#战报拆解一次事务写四张表)）。
没有游戏的机器可以用 [scripts/simulate_battle.py](../scripts/simulate_battle.py) 造同样的报文。

## 版本

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/version/api/getId` | 返回当前版本记录（客户端判断是否更新卡组库） |

返回 `version` 表的整行：`id / address / addressGOG / addressGY / name / startTime / canAutoUpdate / orderMode …`。
客户端拿 `address` 当读内存的基址偏移，`canAutoUpdate=0` 时会提示手动更新。

## 历史遗留

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/download` | 下载 `GwentMirror.7z` 客户端包 |
| POST | `/upload` | 上传客户端包（Linux 落 `/www/jar/GwentMirror/uploads/`） |
| GET | `/good` | 探活/统计埋点，往 `other` 表计数 |

## 快速验证

```bash
# 直连后端
curl -s http://localhost:8081/deck/api/maxid
curl -s "http://localhost:8081/deck/api/getRandomDecksLast?num=3" | head -c 300
curl -s -X POST http://localhost:8081/version/api/getId

# 经 nginx（浏览器同源路径）
curl -s http://localhost:8080/gmapi/deck/api/maxid
```

## 已知问题

* `getDecksByIds` 用 `LOCATE` 做子串匹配，卡组量上万后是全表扫描，没有索引可用；
* `/download`、`/upload` 依赖写死的 Linux 路径 `/www/jar/GwentMirror/uploads/`，容器里已预建该目录；
* 没有鉴权：接口全部匿名可用，`/deck/api/post` 也是（公网部署需要自己在 nginx 上加限制）。