# 快速开始

从零到能在浏览器里点开卡组，三条路任选一条。

## 环境要求

| 方式 | 需要 |
| --- | --- |
| 跑现成镜像（推荐） | Docker 20+（Windows 用 Docker Desktop 即可） |
| compose 构建 | Docker + 约 3 GB 磁盘（maven/node 基础镜像） |
| 源码本地开发 | JDK 8+、Maven 3.6+、Node 18+、MySQL 8 |

镜像本身已含 MySQL 8、JRE 11、nginx，宿主机**不需要**装数据库或 Java。

## 方式 A：直接跑已构建好的镜像

```bash
docker run -d --name gwent-mirror \
  -p 8080:80 -p 8081:8081 \
  -v gwent-mysql:/var/lib/mysql \
  crpi-jjrtzj5uuz1ioat1.cn-shanghai.personal.cr.aliyuncs.com/liunidie/gwentmirror-all-in-one:1.4.0
```

浏览器打开 <http://localhost:8080>（会自动跳到卡组检索页 `/search`）。
后端 API 直连地址 <http://localhost:8081>。

* 首次启动约 **30~60 秒**：初始化 MySQL 数据目录 → 导入 `backend/GwentMirror.sql`（7 张表 + 477 个样例卡组）→ 拉起后端与 nginx。
* 健康检查：`curl http://localhost:8080/healthz` 返回 `ok`；容器状态显示 `healthy`。
* 端口被占用时把 `-p 8080:80` 换成别的宿主机端口即可（例如 `-p 18080:80`）。

镜像拉不动、或想自己重建，见 [docker.md](docker.md)。

## 方式 B：docker compose（含构建）

```bash
git clone https://github.com/1053278842/GwentMirrorAllInOne.git
cd GwentMirrorAllInOne
docker compose up -d --build
docker compose logs -f
```

`docker-compose.yml` 里已经写好镜像地址、端口、数据卷和环境变量；
`--build` 会现场编译前后端（首次约 8~15 分钟，取决于拉基础镜像的速度）。

## 方式 C：从源码自己构建镜像

<a id="from-source"></a>

```bash
./scripts/build.sh                              # 默认 tag gwentmirror-all-in-one:1.4.0
IMAGE=myrepo/gwent:dev ./scripts/build.sh       # 自定义 tag
```

构建是三层多阶段：`maven` 编 jar → `node` 编前端 → `ubuntu 22.04` 装 MySQL8/nginx/JRE11 组装运行镜像。
各层职责见 [docker.md](docker.md#构建层次)。

## 起完之后自检

```bash
curl -s http://localhost:8080/healthz                    # ok
curl -s http://localhost:8080/gmapi/deck/api/maxid       # 官网卡组水位，如 406954
curl -s "http://localhost:8080/gmapi/deck/api/getRandomDecksLast?num=1" | head -c 200
docker exec gwent-mirror mysql -ugwent -pgwent123 GwentMirror -e "select count(*) from deck;"
```

四条都对得上，说明「nginx → 后端 → MySQL」整条链路通了。

## 本地开发（不用容器）

```bash
# 后端：JDK8+ 与本地 MySQL，改 application.yml 的 datasource
cd backend && mvn spring-boot:run

# 前端：/gmapi 与 /localapi 都指向 localhost:8081
cd frontend && npm install && npm run dev
```

`frontend/vite.config.ts` 里 `/gmapi` 默认指向作者的线上环境（`117.50.175.251:8081`），
本地调试改成 `http://localhost:8081` 即可（或直接用 `/localapi` 前缀）。

两层的细节分别在 [backend/README.md](../backend/README.md)、[frontend/README.md](../frontend/README.md)。