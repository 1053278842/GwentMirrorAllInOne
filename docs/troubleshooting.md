# 已知问题与排查

## 起不来

**容器一直 `starting` / `unhealthy`**

```bash
docker logs gwent-mirror --tail 50
```

- 日志停在「初始化 MySQL 数据目录」：首次初始化要 20~40 秒，等；
- 日志报 `mysqld: Can't create/write to file`：数据卷权限问题，删卷重来
  （`docker rm -f gwent-mirror && docker volume rm gwent-mysql`）；
- 日志停在「等待 MySQL 就绪」：`docker exec gwent-mirror tail /var/log/gwent/mysqld.err`。

**8080 被别的程序占了**

```bash
docker run -d --name gwent-mirror -p 18080:80 -p 18081:8081 ...   # 换宿主端口即可
```

容器内的 80/8081 不用改，nginx 反代的目标是容器内的 `127.0.0.1:8081`。

**`/healthz` 通但页面 404**

nginx 已起，但静态资源没挂上——确认镜像构建时 `dist` 拷进去了：
`docker exec gwent-mirror ls /usr/share/nginx/html`。

## 页面/图片

**卡图全裂**

卡图是 `/src/assets/card/...` 绝对路径，镜像里必须存在 `dist/src/assets`。
本地构建时确认 `cp -r src/assets/. dist/src/assets/` 这一步执行过（Dockerfile 里有）。

**页面一直转 LOADING**

原版 `DeckSearchView` 的 `loading` 只置 `true` 不置 `false`，已在 [changes.md](changes.md) 修掉。
如果你用的是上游代码，手动改 `deckJsonToViewData()` 末尾加 `loading.value = false`。

**首屏偶尔滚动错位**

卡组列表用 `vue-virtual-scroller` + 变高估算，窗口尺寸剧烈变化时偶发错位，刷新即恢复（原实现如此）。

## 数据

**官网抓不到卡组**

`playgwent.com` 随时可能下线。届时 `fetch_decks.py` 不可用，但容器自带 477 个样例卡组仍可完整演示。
先跑一次 `--dry-run` 看官网接口是否还活着。

**`/api-pg/*` 反代失败**

容器无外网时该路由不可用；前端卡牌数据已内置，不影响页面渲染。

**重跑脚本后没看到新卡组**

`getRandomDecksLast` 只返回 `create_time` 晚于版本水位的卡组。若水位记录比新卡组还新，
新卡组不会出现在首屏随机里，但用卡牌检索仍能搜到。

## 构建/推送

**`docker build` 在 apt 那层失败**

archive.ubuntu.com 偶发 502，Dockerfile 里已做 5 次重试；仍失败就重跑一次（前面层有缓存）。

**push 阿里云报 `denied: requested access to the resource is denied`**

先确认已 `docker login` 该 registry，且路径第一段是控制台里**已存在**的命名空间
（个人版要先建命名空间 + 仓库，不会自动创建）。

**`npm run build` 失败**

它会先跑 `vue-tsc` 类型检查，历史代码有类型报错。用 `npx vite build`（镜像里就是这么做的）。

## 桌面端

**记牌器一启动就弹「检测到游戏未启动」**

它靠 `pymem` 附加 `Gwent.exe`，没游戏进程就退出。没有游戏时用 `desktop/gui_demo.py` 看界面。

**游戏更新后读不到数据**

`version.json` 的 `address` 与游戏版本强绑定，点主窗「更新」页去服务器拉新的版本记录。

**只带了缩略图，没有高清原画**

仓库里只有 `deck_preview`（57 张 UI 切图）和 `GwentImg_preview`（1369 张缩略图），
**没有** `GwentImg原图`（约 300 MB）；需要原图时用
`desktop/main/othersFile/从gwent获取图片.py` 重新抓。

**主窗被裁掉一行**

原始 geometry 是 250×280，启动页内容比它高（「分辨率」第二行会被裁掉）；
`gui_demo.py` 截图时宽度保持 250、高度按内容自适应，所以你看到的是完整布局。

## 桌面端不能在容器里跑

记牌器需要 Windows + 读 `Gwent.exe` 内存，镜像只打包服务端与前端。
它的上报协议由 `scripts/simulate_battle.py` 完整复现，
界面由 `desktop/gui_demo.py` 离线复现（只替换内存层）。