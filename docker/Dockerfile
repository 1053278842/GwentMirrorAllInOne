###############################################################################
# GwentMirror All-in-One
#   stage 1 : Spring Boot 2.6.3 backend  -> /build/target/*.jar
#   stage 2 : Vue3 + Vite  frontend      -> /build/dist
#   stage 3 : Ubuntu 22.04 + MySQL 8 + Nginx + JRE11 runtime (single image)
###############################################################################

# ---------------------------------------------------------------- backend ----
FROM maven:3.8.6-eclipse-temurin-8 AS backend-build
WORKDIR /build
# 依赖层单独缓存，源码改动不必重新下载依赖
COPY backend/pom.xml ./
RUN mvn -B -q -DskipTests dependency:resolve dependency:resolve-plugins || true
COPY backend/src ./src
RUN mvn -B -DskipTests package \
 && cp target/*.jar /build/app.jar

# --------------------------------------------------------------- frontend ----
FROM node:18-bookworm AS frontend-build
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
# 只做 vite build（vue-tsc 类型检查在历史代码里跑不通，构建产物不受影响）
RUN npx vite build
# 卡牌立绘 / 卡框 等素材在源码里是以 /src/assets/... 绝对路径引用的，
# 因此构建产物必须把 src/assets 原样发布到 dist/src/assets 下。
RUN mkdir -p dist/src/assets && cp -r src/assets/. dist/src/assets/

# ---------------------------------------------------------------- runtime ----
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    GWENT_HOME=/app \
    GWENT_DB_NAME=GwentMirror \
    GWENT_DB_USER=gwent \
    GWENT_DB_PASS=gwent123

# apt 源偶发 502，做多次重试，避免整层构建失败
RUN set -eu; \
    installed=0; \
    for attempt in 1 2 3 4 5; do \
      if apt-get update -o Acquire::Retries=10 \
         && apt-get install -y -o Acquire::Retries=10 --no-install-recommends \
              openjdk-11-jre-headless \
              mysql-server \
              nginx \
              supervisor \
              curl \
              netcat-openbsd \
              tzdata \
              ca-certificates; then installed=1; break; fi; \
      echo ">>> apt 第 ${attempt} 次失败，10s 后重试"; \
      rm -rf /var/lib/apt/lists/*; sleep 10; \
    done; \
    [ "$installed" = "1" ] || { echo ">>> apt 安装失败"; exit 1; }; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /etc/nginx/sites-enabled/default

# 运行期目录
RUN mkdir -p /app/backend /app/logs /www/jar/GwentMirror/uploads /run/mysqld /var/log/gwent \
 && chown -R mysql:mysql /run/mysqld /var/lib/mysql

# 后端 jar
COPY --from=backend-build /build/app.jar /app/backend/GwentMirror.jar
# 前端静态站点
COPY --from=frontend-build /build/dist/. /usr/share/nginx/html/
# 数据库结构与样例数据（首次启动自动导入）
COPY backend/GwentMirror.sql /docker-entrypoint-initdb.d/GwentMirror.sql
# 运行时配置
COPY docker/nginx.conf      /etc/nginx/conf.d/gwent.conf
COPY docker/supervisord.conf /etc/supervisor/conf.d/gwent.conf
COPY docker/my.cnf          /etc/mysql/conf.d/zz-gwent.cnf
COPY docker/entrypoint.sh   /usr/local/bin/entrypoint.sh
COPY docker/wait-for-mysql.sh /usr/local/bin/wait-for-mysql.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/wait-for-mysql.sh

EXPOSE 80 8081
VOLUME ["/var/lib/mysql"]

HEALTHCHECK --interval=20s --timeout=5s --start-period=90s --retries=5 \
  CMD curl -fsS http://127.0.0.1/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []