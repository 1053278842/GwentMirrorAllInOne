# 相对上游的改动

三个原始仓库直接跑不起来，整合时修了 9 处。每条都标了「为什么」，
方便你判断要不要把改动同步回上游。

## 后端

| 文件 | 问题 | 处理 |
| --- | --- | --- |
| `backend/.../entity/Deck.java` | `cardList` 是运行期派生字段，MyBatis-Plus 却当成 `card_list` 列查，`/deck/api/getDecks` 全部 500（`Unknown column 'card_list'`） | 加 `@TableField(exist = false)` |
| `backend/.../controller/DeckController.java` | `getRandomDecksLast` 用 `sorted((a,b) -> new Random().nextInt())` 当比较器，违反 TimSort 契约，数据一多就抛 `Comparison method violates its general contract!` → 500 | 改成先转 DTO 再 `Collections.shuffle` |
| `backend/.../mapper/PlayerMapper.xml` | MySQL 8.0.2 起 `RANK` 是保留字，插入玩家时 SQL 语法错误，`/battle/api/save` 全链路 500 | 给 `rank` 加反引号 `` `rank` `` |

## 前端

| 文件 | 问题 | 处理 |
| --- | --- | --- |
| `frontend/src/views/CardSearchView.vue` | HEAD 版本误把整个 `DeckSearchView` 页面复制了过来，还 `import` 了它自己（组件自我嵌套），首页顶部会无限嵌套渲染、整页元素重叠 | 恢复为提交 `710ddc1` 中的原始「卡牌检索栏」实现 |
| `frontend/src/views/DeckSearchView.vue` | 模板多了一个 `</template>`，`vite build` 直接失败（`Element is missing end tag`） | 删除多余结束标签 |
| `frontend/src/views/DeckSearchView.vue` | `loading` 只置 `true` 从不置 `false`，全屏 LOADING 遮罩会永久盖住页面 | 数据到达/请求失败时关闭遮罩 |
| `frontend/src/views/CardView.vue` | 20 处 `url("src/assets/...")` 少了开头的 `/`，生产环境被解析成 `/src/assets/src/assets/...` 全部 404 | 统一改为 `url("/src/assets/...")` |
| `frontend/index.html` | `lang="en"` 会触发浏览器自动翻译，卡牌英文原文本被机器翻译破坏 | 改 `lang="zh-CN"` + `translate="no"` |
| `frontend/src/assets/main.css` | Vue 模板没重置 `body` 默认外边距，铺满视口时露出一圈白边 | 追加 `html,body{margin:0}` 等容器化补充样式 |
| `frontend/src/router/index.ts` | 没有 `/` 路由，直接访问根路径白屏 | 增加 `/ → /search` 重定向 |

## 桌面端

源码没改。新增两个文件：

| 文件 | 作用 |
| --- | --- |
| `desktop/gui_demo.py` | 只替换 `pymem` 内存层，用原版界面代码离线复现并截图 |
| `desktop/README.md` + `desktop/docs/` | 说明 |

素材补充（不是改动，是从上游仓库补下来的）：`resources/images/deck_preview`（57 张 UI 切图）、
`resources/images/GwentImg_preview`（1369 张卡图缩略图）、`resources/images/favicon`。

## 新增的编排文件

| 文件 | 作用 |
| --- | --- |
| `docker/Dockerfile` | 三层多阶段构建 |
| `docker/entrypoint.sh` | 首次启动建库导入，之后交 supervisord |
| `docker/supervisord.conf` `nginx.conf` `my.cnf` `wait-for-mysql.sh` | 进程托管与配置 |
| `scripts/build.sh` `push-aliyun.sh` `demo.sh` `demo.ps1` | 构建/推送/一键演示 |
| `scripts/fetch_decks.py` | 由 `desktop/main/othersFile/抓取卡组-官网.py` 改写（去 GUI 依赖、加线程池） |
| `scripts/simulate_battle.py` | 按记牌器报文结构回放对局 |

## 刻意没做的

* 没有改前端的视觉与交互（只修了坏掉的部分）；
* 没有动 `desktop/main/othersFile/` 里的一次性抓取脚本（含 `chromedriver.exe`）；
* 没有把桌面端塞进容器（它必须附加 Windows 游戏进程，见 [architecture.md](architecture.md#桌面端为什么不在容器里)）；
* 没有给接口加鉴权——这是整合，不是二次开发。