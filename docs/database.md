# 数据模型

7 张表，全部在 `backend/GwentMirror.sql` 里（含 477 个样例卡组，容器首启自动导入）。

## 表结构

| 表 | 说明 |
| --- | --- |
| `deck` | 卡组。`cards` 是逗号分隔的卡牌 id 串（客户端/爬虫上报的原始形态）；`id` = 卡组指纹；`deck_web_id` = 官网卡组 id；`total` = 命中次数 |
| `player` | 玩家，`service_id` 为主键，重复出现时 `repeated_times + 1` |
| `battle` | 一场对局：`game_id`、模式、结束原因、左右两条 `player_battle_info` |
| `player_battle_info` | 单侧战报：牌表 id、胜负、逐回合小分（JSON） |
| `card` | 卡牌缓存表（前端已改用 `allCard.json`，此表保留兼容） |
| `version` | 版本水位线，`/version/api/getId` 用它判断客户端卡组库是否要更新 |
| `other` | 杂项键值（运维用） |

字符集 `utf8mb4` / 排序规则 `utf8mb4_0900_ai_ci`（需要 MySQL 8，MariaDB 不支持该 collation）。

## 卡组指纹：同一套牌只存一行

客户端和爬虫都用「牌表集合的哈希」当主键，与出牌顺序无关：

```python
# desktop/main/tools/DataUtils.py
def transListCtIdToHash(decks):
    return hash(frozenset(decks))
```

入库统一走 `INSERT ... ON DUPLICATE KEY UPDATE`（`DeckMapper.xml`）：

```sql
INSERT INTO deck (...) VALUES (...)
ON DUPLICATE KEY UPDATE
  total  = total + 1,                                       -- 命中次数 +1
  name   = IF(time < VALUES(time), name,   VALUES(name)),    -- 只接受更新的版本
  author = IF(time < VALUES(time), author, VALUES(author)),
  time   = IF(time < VALUES(time), time,   VALUES(time));
```

同一套牌被不同玩家反复打出、或在官网反复爬到，只会让 `total` 增长并刷新最新的名称与时间，表不会膨胀。

## 战报拆解（一次事务写四张表）

`desktop/main/dao/CardDao.py:getBattleInfo()` 按固定偏移读游戏内存，拼出：

```jsonc
{
  "GameStatus": 3, "GameMode": 1, "GameId": 1732..., "BattleType": 2,
  "roundInfos": [{ "index": 0, "left_score": 12, "right_score": 8,
                   "starting_playerId": 1, "winner_playId": 1, "turn_index": 11 }, ...],
  "curr_round_index": 2, "winner_playId": 1, "end_game_reason": 0,
  "players": [
    { "player_name": "...", "service_id": 900000000000000001, "paragon_level": 0,
      "MMR": 9600, "rank": 0,
      "leader_id": 200087, "stratagem_id": 0, "faction_id": 4,
      "decks": [200087, 0, 202115, 201779, ...],   // leader + stratagem + 牌表
      "deckId": 1234567890123456789 }              // hash(frozenset(decks))
  ]
}
```

`RequestManager.sendBattleInfo()` 先做过滤：局内未结束、单人/观战模式、友谊赛/竞技场一律不上报；
「自动提交卡组」关闭时把 `decks` 清空（只统计对局、不采集牌表）。通过后 `POST /battle/api/save`。

服务端 `BeansUtils` 把这份 JSON 拆成 `player` / `deck` / `battle` / `player_battle_info` 四类实体，
由 `BattleServiceImpl.saveBattleInfo()` 在**一个事务**里写完：
先插 battle 拿主键 → 两个 pbi 插入拿 id → 回填 battle 的左右 id。

## 落库后长什么样

回放 3 场对局后（详见 [usage.md](usage.md#回放对局脚本)）：

```text
+---------------------+----------+
| tbl                 | n        |
+---------------------+----------+
| deck                | 497      |   -- 477 样例 + 19 条官网新卡组 + 1 条回放产生的 By.*
| battle              | 8        |   -- /battle/api/save 写入
| player              | 6        |   -- service_id 去重
| player_battle_info  | 16       |   -- 每场两条（左右各一）
| version             | 1        |
+---------------------+----------+
```

`battle` 里能看到一场对局把左右两条 `player_battle_info` 串了起来：

```text
id  game_id         game_status  game_mode  game_battle_type  left_pbi  right_pbi
1   1795512379954   3            1          2                 1         2
2   1795512380477   3            1          2                 3         4
```

## 常用 SQL

```sql
-- 卡组总数 / 官网水位
select count(*) from deck;
select max(deck_web_id) from deck;

-- 最近入库的 10 套牌
select id, name, author, deck_web_id, create_time from deck order by create_time desc limit 10;

-- 包含某张卡的卡组（后端 LOCATE 查询的等价写法）
select id, name from deck where locate('202140', cards) > 0 or stratagem_card_id = 202140;

-- 对局与左右战报
select b.id, b.game_id, b.left_player_battle_info_id, b.right_player_battle_info_id
from battle b order by b.id desc limit 5;
```

字段陷阱：

* `deck.cards` 是字符串不是关联表，所以「包含某张牌」只能用 `LOCATE`，数据量上万后全表扫会变慢；
* 战略卡 id 不一定出现在 `cards` 里（客户端单独报 `stratagem_card_id`），查询要 `or` 上它；
* `deck.id` 可能为负数（Python `hash()` 的取值），`BIGINT` 够用，不要用 `UNSIGNED`。