# 镜像与容器

一个镜像里装四样东西：MySQL 8、JRE 11 + Spring Boot、nginx、supervisord。
外部只暴露 80（站点）和 8081（API）。

## 镜像信息

```text
crpi-jjrtzj5uuz1ioat1.cn-shanghai.personal.cr.aliyuncs.com/liunidie/gwentmirror-all-in-one:1.4.0
digest: sha256:4a0a2b76c963f652124b5e66508e8602b242fd9bc283b6209b02eded24b1ef87
size  : 1.06 GB
```

控制台：<https://cr.console.aliyun.com/cn-shanghai/instance/repositories>

已用「推上去 → 删本地 tag → 从仓库重新 pull → 起容器」的方式验证过：
`docker pull` 拿到的 digest 与推送一致，容器 `healthy`，`/gmapi/deck/api/getDecks` 返回 477 条样例卡组，
`fetch_decks.py` / `simulate_battle.py` 对这份线上镜像同样能跑通。

## 构建层次

`docker/Dockerfile` 是三层多阶段：

| 阶段 | 基础镜像 | 产出 |
| --- | --- | --- |
| backend-build | `maven:3.8.6-eclipse-temurin-8` | `target/*.jar` → `/app/backend/GwentMirror.jar` |
| frontend-build | `node:18-bookworm` | `npx vite build` 的 `dist/`，并把 `src/assets` 原样拷进 `dist/src/assets` |
| runtime | `ubuntu:22.04` | 装 `openjdk-11-jre-headless` `mysql-server` `nginx` `supervisor`，拼装上面两层的产物 |

运行镜像里 apt 装包做了 5 次重试（`Acquire::Retries`），因为 archive.ubuntu.com 偶发 502；
工作网络在国内时这一段可能要几分钟。

## 容器内进程模型

```text
PID 1  supervisord
       ├─ mysqld        (priority 10)  127.0.0.1:3306，不对外
       ├─ gwent-service (priority 20)  wait-for-mysql.sh → java -jar，:8081
       └─ nginx         (priority 30)  :80
```

`docker/entrypoint.sh` 只负责**首次启动**：初始化 datadir → 临时起 mysqld → 建库建账号 →
导入 `backend/GwentMirror.sql` → 设 root 密码 → 关掉临时实例 → `exec supervisord`。
数据目录已存在时跳过导入（见下方「重置」）。

`docker/wait-for-mysql.sh` 会等到 `gwent` 账号能 `SELECT 1` 才拉起 Java，避免后端先于数据库启动而崩。

## 端口

| 端口 | 说明 |
| --- | --- |
| **8080 → 80** | nginx：前端静态站点、`/gmapi/` 反代后端、`/healthz` |
| **8081 → 8081** | Spring Boot：`/deck/api/*`、`/battle/api/*`、`/version/api/*` |

## 环境变量

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GWENT_DB_NAME` | `GwentMirror` | 数据库名 |
| `GWENT_DB_USER` / `GWENT_DB_PASS` | `gwent` / `gwent123` | 后端连接账号 |
| `JAVA_OPTS` | `-Xms256m -Xmx512m` | JVM 参数 |
| `TZ` | `Asia/Shanghai` | 时区 |

## 连数据库

MySQL 只监听容器内 `127.0.0.1:3306`，不对外暴露。需要连库调试时：

```bash
docker exec -it gwent-mirror mysql -ugwent -pgwent123 GwentMirror -e "select count(*) from deck;"
```

## 数据卷与重置

```bash
docker volume inspect gwent-mysql            # 数据在命名卷里，重启容器不丢
docker rm -f gwent-mirror && docker volume rm gwent-mysql   # 回到初始样例数据
```

不挂 `-v` 时数据存在容器可写层，删容器即清空。

## 重新推送阿里云

```bash
# 用户名填阿里云账号全名，密码填 ACR 的「固定密码」
docker login --username=<阿里云账号全名> crpi-jjrtzj5uuz1ioat1.cn-shanghai.personal.cr.aliyuncs.com

./scripts/push-aliyun.sh          # = docker tag + docker push
```

`scripts/push-aliyun.sh` 支持 `REGISTRY / NAMESPACE / REPO / TAG / LOCAL_IMAGE` 环境变量覆盖，
默认命名空间 `liunidie`、仓库 `gwentmirror-all-in-one`。

> 若 push 报 `denied: requested access to the resource is denied`：先确认已登录该 registry，
> 且路径第一段是控制台里**已存在**的命名空间（个人版要先建命名空间 + 仓库，不会自动创建）。

## 日志

| 位置 | 内容 |
| --- | --- |
| `docker logs -f gwent-mirror` | supervisord + 三个子进程的 stdout |
| `/var/log/gwent/backend.log` | Spring Boot（含 MyBatis 的 SQL stdout，较啰嗦） |
| `/var/log/gwent/mysqld.err` | MySQL 错误日志 |
| `/var/log/gwent/nginx.err` | nginx 错误日志 |

排查时可临时关掉 `mybatis-plus.configuration.log-impl`，日志量会小一个数量级。