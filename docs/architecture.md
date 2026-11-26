# 架构与目录

## 整体数据流

```text
                       ┌────────────────────────── 容器 gwent-mirror ──────────────────────────┐
                       │                                                                       │
  Windows 游戏 ────────┤ desktop/main (Python 记牌器)                                          │
   Gwent.exe           │   pymem 读内存 → battleInfo → POST /battle/api/save ─┐                │
                       │                                                       │                │
  官网 playgwent.com ──┤ scripts/fetch_decks.py → POST /deck/api/post ─────────┤                │
                       │                                                       ▼                │
                       │   nginx :80                                  ┌───────────────────────┐ │
  浏览器 ──── HTTP ────►│   ├─ /          → Vue3 静态站点 (SPA)        │ Spring Boot :8081     │ │
                       │   ├─ /gmapi/*   → 127.0.0.1:8081             │  /deck/api/*          │ │
                       │   ├─ /api-pg/*  → www.playgwent.com (备用)   │  /battle/api/*        │ │
                       │   └─ /healthz                                │  /version/api/*       │ │
                       │   /src/assets/card/...（2800+ 卡图素材）      └──────────┬────────────┘ │
                       │                                                        │ JDBC           │
                       │                                              ┌─────────▼────────────┐  │
                       │                                              │ MySQL 8 (127.0.0.1)  │  │
                       │                                              └──────────────────────┘  │
                       └───────────────────────────────────────────────────────────────────────┘
```

容器内由 `supervisord` 托管三个进程：`mysqld` → `gwent-service`(Java) → `nginx`；
`docker/entrypoint.sh` 只在**首次启动**时建库、建账号、导入 SQL，然后 `exec supervisord`。
进程优先级与启动顺序见 [docker.md](docker.md#容器内进程模型)。

## 桌面端为什么不在容器里

记牌器不是"读日志"而是**读进程内存**：`pymem.Pymem("Gwent.exe")` 附加进程 →
用 `GameAssembly.dll` 基址 + 版本表里的偏移一路解引用 → 拿到 `GameInstance` →
再按偏移读出双方玩家、牌表、每张牌的位置/战力/人口。它只能在 Windows 上、且游戏正在运行时工作，
所以：

* 容器里只放**服务端 + 前端**，桌面端源码留在 `desktop/` 供 Windows 侧使用；
* 桌面端与服务器之间只靠 HTTP 通信（`/battle/api/save`、`/deck/api/getDecks`、`/version/api/getId`），
  协议由 `scripts/simulate_battle.py` 完整复现，因此容器里也能演示"上报 → 入库 → 前端可见"的完整链路；
* 桌面端的**图形界面**用 `desktop/gui_demo.py` 做离线复现（见 [usage.md](usage.md#桌面记牌器界面复现)），
  只替换内存读取层，界面渲染代码与素材全部是原版。

## 目录结构

```text
gwent-mirror-all/
├─ backend/                    # GwentMirrorService：Spring Boot 2.6.3 + MyBatis-Plus
│  ├─ src/main/java/com/ll/gwentmirror/
│  │  ├─ controller/           # DeckController / BattleController / VersionController / FileController
│  │  ├─ service/impl/         # 入库、分页、版本增量
│  │  ├─ mapper/ + resources/mapper/*.xml      # 手写 SQL（批量插入、包含匹配）
│  │  └─ utils/BeansUtils.java # 客户端 JSON → 实体（核心转换）
│  └─ GwentMirror.sql          # 表结构 + 477 个样例卡组（容器首启导入）
├─ frontend/                   # GwentMirror：Vue3 + Vite + Element Plus
│  └─ src/
│     ├─ api/gwentmirror.ts    # 后端调用（统一走 /gmapi 前缀）
│     ├─ stores/AllCards.ts    # allCard.json → 卡牌对象（离线可用）
│     ├─ views/DeckSearchView.vue  # 首页：卡牌检索 + 卡组虚拟滚动列表
│     ├─ views/DeckView.vue        # 单个卡组：分组、势力背景
│     ├─ views/CardView.vue        # 单张卡牌渲染（含悬浮大图）
│     └─ assets/card/…         # 2800+ 卡图/卡框/数字图标
├─ desktop/                    # GwentWanHuaMirror：Python 记牌器（Windows 专用）
│  ├─ gui_demo.py              # 离线复现图形界面并截图（替换内存层，不用开游戏）
│  └─ main/
│     ├─ GwentMirror.py        # 主控制窗（ttkbootstrap）
│     ├─ GwentGUI.py           # 对局内透明置顶悬浮窗
│     ├─ views/                # 背景板 / 标题栏 / 页签按钮 / 状态栏 / 卡牌列表五个画布
│     ├─ dao/services          # 内存寻址与卡牌数据装配
│     ├─ resources/images/     # deck_preview（UI 切图）+ GwentImg_preview（1369 张卡图缩略图）
│     └─ resources/fonts/      # 界面用的中文字体
├─ docker/                     # Dockerfile / nginx.conf / supervisord.conf / entrypoint.sh / my.cnf
├─ scripts/                    # build.sh / push-aliyun.sh / demo.sh / fetch_decks.py / simulate_battle.py
├─ docs/                       # 本目录（文档分册）
└─ docs/screenshots/           # 截图（前端 4 张 + 桌面端 2 张）
```

三个子目录各有一份自己的 README（`backend/`、`frontend/`、`desktop/`），
分别说明这一层做什么、怎么单独跑、和一体化容器怎么对接。

## 官网爬虫流水线

`scripts/fetch_decks.py`（源自 `desktop/main/othersFile/抓取卡组-官网.py`，改成纯命令行 + 线程池）：

1. `GET /deck/api/maxid` 拿到库内已有的最大官网卡组 id；
2. 拉官网 `guides/offset/0000/limit/500` 列表，筛出时间窗内且 id 更新的卡组；
3. 逐个拉详情，把 `srcCardTemplates` 拍平成 `sortedCtIds`，换算势力 id（monsters=2 / nilfgaard=4 / northernrealms=8 / scoiatael=16 / skellige=32 / syndicate=64）；
4. 批量 `POST /deck/api/post`。

## 前端检索路径

* 卡牌数据打包进 `src/assets/allCard.json`（1171 张），**不依赖官网接口**，离线也能渲染名称、战力、护甲、人口与卡图。
* 选卡 → `stores/UserOperationStore` 累积 card id → `GET /gmapi/deck/api/getDecksByIds?ids=...`。
  后端 `DeckMapper.getListByIds` 用 `LOCATE(#{cid}, cards) > 0 OR stratagem_card_id = #{cid}`
  做「卡组里包含这些牌」的匹配，按 `update_time` 倒序。
* 未选牌时走 `GET /gmapi/deck/api/getRandomDecksLast?num=50`：取 `create_time` 晚于最新版本水位的卡组，随机 50 个作为首屏推荐。
* 列表用 `vue-virtual-scroller` 的 `DynamicScroller` 做虚拟滚动，单页 1000px 高度内滚动加载，避免一次渲染上千个卡组。
* 卡图/CSS 在代码里是以 `/src/assets/...` **绝对路径**引用的，所以镜像把源码目录 `src/assets` 原样发布到
  `/usr/share/nginx/html/src/assets`，构建产物（js/css）也落在同一目录，路径与开发态完全一致。

更细的实现（渲染代码、虚拟滚动参数）见 [frontend/README.md](../frontend/README.md) 与 [frontend/docs/](../frontend/docs/)。