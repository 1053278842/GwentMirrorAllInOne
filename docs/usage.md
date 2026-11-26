# 用起来是什么样

从起容器到看见「脚本把数据灌进去、网页上能搜到」的完整流程。

## 五步走完

| 步骤 | 做什么 | 谁来做 |
| --- | --- | --- |
| 1 | `docker run` 起容器，等 30~60 秒 | 你 |
| 2 | 打开 <http://localhost:8080>，首屏就是 50 套随机卡组 | 你 |
| 3 | 点输入框选几张牌（如 Geralt of Rivia），列表变成「包含这些牌」的卡组 | 你 |
| 4 | 跑 `scripts/fetch_decks.py` 抓官网新卡组，或 `simulate_battle.py` 回放对局 | 你 |
| 5 | 刷新页面，新卡组出现在随机列表里 / 用卡牌检索能搜到 | 你 |

第 4 步的两个脚本只依赖 Python 标准库，在宿主机直接跑，不需要进容器。

## 抓官网卡组

```bash
python3 scripts/fetch_decks.py --base-url http://localhost:8080/gmapi --since-days 30 --limit 20
```

```text
[crawl] 目标服务 : http://localhost:18080/gmapi
[crawl] 时间范围 : 最近 30 天
[crawl] 库内最大官网卡组 id: 406954
[crawl] 发现 20 个新卡组，开始抓取详情 ...
  +   408945  Ursine Ritual                             27 张  faction=32
  +   408946  Renfri                                    27 张  faction=32
  +   408953  Fome Opressora                            27 张  faction=2
  +   408935  Waylay trap disco sensation               27 张  faction=16
  +   408943  調和デッキ                                     27 张  faction=16
  ...
[crawl] 详情抓取完成: 20/20
[crawl] 已批量写入服务端: 20 个卡组
```

参数：

| 参数 | 说明 |
| --- | --- |
| `--base-url` | 服务端地址，`/gmapi`（经 nginx）或 `:8081`（直连）都行 |
| `--since-days` | 只抓最近 N 天发布的卡组 |
| `--limit` | 最多抓多少个 |
| `--workers` | 详情并发数，默认 5 |
| `--dry-run` | 只抓不入库，服务端不可达也能跑 |

## 回放对局（脚本效果）

<a id="回放对局脚本"></a>

```bash
python3 scripts/simulate_battle.py --base-url http://localhost:8080/gmapi --matches 3 --unique-decks
```

```text
[replay] 目标服务: http://localhost:18080/gmapi
[replay] 取到 50 个种子卡组，开始回放 3 场对局 ...
[replay] #1 gameId=1795512708437 GwentMirror_Demo_A vs GwentMirror_Demo_B -> 胜者 player1
[replay] #2 gameId=1795512708691 GwentMirror_Demo_A vs GwentMirror_Demo_B -> 胜者 player2
[replay] #3 gameId=1795512708941 GwentMirror_Demo_A vs GwentMirror_Demo_B -> 胜者 player1
[replay] 完成: 3/3 条上报成功
```

`--unique-decks` 会把玩家 A 的牌表换掉两张牌，得到一个新的卡组指纹——
对应「玩家自己组的牌」，前端能直接搜到这张新卡组（`name = By.<玩家名>`）。
不加这个参数时，回放的牌表和已有卡组一致，只会让 `deck.total` 累加。

## 落库结果

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

怎么在网页上确认「脚本真的生效了」：

1. 抓完卡组后刷新首页——随机 50 套里会出现官网那种多语种名字（俄语/日语/葡萄牙语）；
2. 用某个只在新卡组里出现的卡去检索，命中数会从 0 变成 1；
3. `getRandomDecksLast` 取的是「`create_time` 晚于版本水位」的卡组，新写入的都在内。

## 桌面记牌器界面复现

<a id="桌面记牌器界面复现"></a>

记牌器启动时先 `pymem.Pymem("Gwent.exe")` 附加进程，取不到就直接弹「检测到游戏未启动」并退出，
所以在没有游戏的机器上跑不起来。`desktop/gui_demo.py` 的做法是**只换掉内存读取层**：

| 层 | 处理 |
| --- | --- |
| `pymem` | 注入一个假模块（`read_longlong`/`read_bytes` 全返回 0），避免附加进程 |
| `services.CardService.get_all_cardTemplates()` | 换成「从 `resources/data/decks.json` 挑一副完整卡组摊平」的替身 |
| 联合信息（当前玩家 / 双方 playerId / 牌库实例 id 区间） | 固定值 |
| `GwentGUI` / `views/*`（背景板、标题、页签、状态栏、卡牌列表） | **原样使用** |
| 素材（`deck_preview/*.png`、`GwentImg_preview/*.jpg`、字体） | **原图** |

所以截出来的就是真实界面（见 [screenshots.md](screenshots.md)）。

```bash
cd desktop
pip install pillow ttkbootstrap pywin32        # tkinter 随 Python 自带
python gui_demo.py --target both               # 主窗 + 悬浮窗各截一张
python gui_demo.py --target overlay --tab 手牌  # 指定页签：卡组/牌库/墓场/放逐/手牌/场地
python gui_demo.py --target overlay --enemy     # 敌方视角
```

截图默认写到 `docs/screenshots/`；`--out-dir` 可改。
悬浮窗本身是 `overrideredirect + WS_EX_LAYERED` 的透明窗口，脚本会先垫一层深色背景再截图，
避免把桌面/浏览器一起拍进去。

## 一条命令跑完上面所有步骤

```bash
./scripts/demo.sh          # Linux/macOS
.\scripts\demo.ps1         # Windows PowerShell
```

它会依次：清旧容器 → 起镜像 → 等健康 → 抓 20 套官网卡组 → 回放 5 场对局 → 打印各表行数。