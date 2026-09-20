# LKM 网站部署教程

本文档说明如何把 LKM 网站(前端 Astro + 后端 FastAPI)通过 APISIX 统一入口部署到生产主机。

> 本文档用于**首次部署、升级和回滚**。已部署环境的日常命令见
> [OPS-CHEATSHEET.md](./OPS-CHEATSHEET.md)，文档职责见 [DOCUMENTATION.md](./DOCUMENTATION.md)。
> 示例中的域名、IP、用户名和密码均为占位符；不要把真实密钥写入本文档或提交到 Git。

## 部署前检查清单

- 服务器时间同步正常，公网安全组只开放实际需要的 `80/443` 和 SSH 端口。
- 已从 `.env.example` 创建 `.env`，并替换所有密码、JWT/TOTP/验证码密钥及内部 token。
- `docker compose config --quiet` 成功，且渲染结果中没有空的必填变量。
- 域名 DNS 已指向目标主机；无域名部署已接受自签证书的限制。
- 已确定 PostgreSQL、MinIO 和后端数据卷的备份位置及恢复负责人。
- 生产环境不会直接暴露 PostgreSQL、Redis、Pulsar、MinIO 管理端口或 Grafana 默认密码。

## 架构概览

单机 docker-compose 编排（支持k8s）,APISIX 为唯一对外入口(nginx 已移除):

| 服务 | 镜像 | 端口(对外) | 职责 |
|---|---|---|---|
| `apisix` | `apache/apisix:3.9.0-debian` | `80` / `443` | **唯一网关**:TLS 终止、HTTP→HTTPS 重定向、反代分流、gzip、CORS 白名单、限流 |
| `apisix-render` | `alpine:3.19` | 无 | 纯 shell sidecar:把证书内联进 apisix.yaml 并每 6h 重渲染(触发 APISIX reload) |
| `acme-webroot` | `nginx:1.27-alpine` | 无 | 微型静态 responder:仅服务 ACME `/.well-known/acme-challenge/`(非网关角色) |
| `certbot` | `certbot/certbot` | 无 | 申请与自动续期 Let's Encrypt 证书(webroot) |
| `astro` | `lkm-official-website:latest` | 仅内网 `4321` | 前端 SSR |
| `static` | `lkm-official-static:latest` | `8082` | 纯静态官网(独立静态文件服务器) |
| `backend` | `lkm-service:latest` | 仅内网 `8000` | FastAPI(REST `/api/v1`)+ 论坛域 GraphQL + lag 上报 |
| `auth` | `lkm-service:latest` | 仅内网 `8001` | AUTH 独立进程(`auth.main`) |
| `worker` | `lkm-service:latest` | 无 | jobs + user-invalidate 订阅。`python -m app.core.worker_default` |
| `worker-send` | `lkm-service:latest` | 无 | 发送订阅。`python -m app.core.worker_send` |
| `worker-notify` | `lkm-service:latest` | 无 | 对象事件登记订阅。`python -m app.core.worker_notify` |
| `worker-notification` | `lkm-service:latest` | 无 | 站内信生成订阅。`python -m app.core.worker_notification` |
| `worker-points-reward` | `lkm-service:latest` | 无 | points 奖励入账订阅。`python -m app.core.worker_points_reward` |
| `worker-points-stats` | `lkm-service:latest` | 无 | points 行为计数/成就订阅。`python -m app.core.worker_points_stats` |
| `worker-points-tasks` | `lkm-service:latest` | 无 | points 每日任务订阅。`python -m app.core.worker_points_tasks` |
| `worker-scheduler` | `lkm-service:latest` | 无 | cron 触发发布(`app.core.worker_scheduler`) |
| `worker-dlq` | `lkm-service:latest` | 无 | 死信落库(`app.core.worker_dlq`) |
| `worker-outbox` | `lkm-service:latest` | 无 | outbox relay(`app.core.worker_outbox`) |
| `postgres` | `timescale/timescaledb:latest-pg16` | 仅内网 `5432` | 后端数据库(biz `lkm` + auth `lkm_auth`);outbox 两表为 hypertable |
| `redis` | `redis:7-alpine` | 仅内网 `6379` | leader 租约、共享限流 / 缓存 |
| `pulsar` | `apachepulsar/pulsar:3.3.0` | 仅内网 `6650`/`8080` | **消息总线**(standalone,自带 ZK+BookKeeper;6650 broker / 8080 Admin REST)。**无状态化**启动包装,见下 |
| `minio` | `minio/minio:latest` | 仅容器内 `9000`/`9001` | S3 兼容对象存储:文件库文件与成员头像 |
| `lkmbot` | `lkm-bot:latest` | 仅经网关 `/bot/` 子路径 | 社区机器人面板(AstrBot fork)。**可选组件**(`--profile bot`);面板 `6185` 不发布到宿主 |
| `shipyard` | `soulter/shipyard-bay:latest` | 无 | bot 代码沙箱(旧版 Bay)。**可选组件**(`--profile bot`),挂 docker.sock |

> `worker*` 与 `backend`/`auth` 共用 `lkm-service:latest` 镜像,仅启动入口不同;各自常驻消费
> 一个 Pulsar 订阅(get 消费失败重投超限后进死信 topic `system/dlq`,由 `worker-dlq` 落库)。
> points 拆三个订阅(reward/stats/tasks)消费同一 `biz/points.apply` topic 实现扇出与故障隔离;
> `worker-notification`(M6.8)以第四个订阅消费同一 topic 生成站内信,同样独立记账、互不阻塞。

> **Pulsar 无状态化**:`pulsar` 由 `deploy/pulsar/entrypoint.sh` 包装启动——
> 每次启动**先清空数据目录**,broker 就绪后**幂等重建** `lkm` 租户与 `biz/auth/system` namespace;
> healthcheck 语义为「broker 就绪**且** namespace 已建」,故依赖它的 12 个应用服务按
> `service_healthy` 等它就绪即可(原一次性 `pulsar-init` 服务已随之删除:它只在首次 `up` 时跑,
> pulsar 重启后不会重跑,正是过去清卷后必须人工介入的根源)。
> **代价**:pulsar 内「**已发布但未消费**」的消息会在每次重启时丢失(未发布事件仍在 PG
> `outbox_events`,由 relay 重投;消费端按 `event_id` 幂等去重)。要真正持久,请改用官方 Helm
> chart(多 bookie、显式端口)或托管服务——单机 compose 里的 standalone 无法既自托管又持久
> (根因:embedded bookie 每次进程启动随机取端口,ledger 里记的 `IP:端口` 必然失效)。

请求分流(有域名走 443 / 无域名走 80):

```
浏览器 ──> APISIX(80 与 443)
              ├─ /api/        ──> backend:8000   (保持路径, WS upgrade 已开)
              ├─ /graphql     ──> backend:8000   (支持 WebSocket)
              ├─ /_astro/*    ──> astro:4321     (指纹静态资源, immutable 长缓存)
              ├─ /lkm/        ──> minio:9000     (对象存储预签名直传/下载, 保留全部 path+query)
              ├─ 其余         ──> astro:4321     (SSR)          ← 社区域名 lkm-ahz.ltd
              ├─ 全部         ──> static:80      (静态官网)      ← 官网域名 lkm-ahz.icu
              └─ /bot/*       ──> lkmbot:6185    (机器人面板,剥 /bot 前缀) ← 社群域子路径
```

后端 REST 前缀为 `/api/vN`,GraphQL 为 `/graphql`。APISIX 用 Docker 内嵌 DNS(`dns_resolver: ['127.0.0.11']` + `discovery_type: dns`)在运行时动态解析 `backend`/`astro`,不依赖启动期 DNS。

> `static` 服务(**纯静态官网**)不挂在 APISIX 的主域名路由下,由独立容器输出并映射到主机 `${LKM_STATIC_PORT:-8082}` 端口,可直接从 `http://<主机IP>:8082` 访问(经 APISIX 的域名路由亦可)。

## 前置条件

- 一台有公网 IP 的 Linux 主机,防火墙/安全组放行 `80` 与 `443` 端口。
  > MinIO 不开放独立公网端口:对象存储经 APISIX `/lkm/` 路径转发到 `minio:9000`(仅内网),
  > 浏览器访问经 APISIX 统一入口即可,无需在安全组另开 9000。
- **域名可选**:有域名走 `.env` 中 `LKM_COMMUNITY_DOMAINS` / `LKM_OFFICIAL_DOMAINS` 配置的地址 + Let's Encrypt 正式证书;**无域名可用公网 IP 直连**——
  此时走 **HTTP(80)+自签证书(443)** 模式(见下文「无域名/IP 直连」一节),浏览器访问 IP 即可。
- 已安装 Docker 与 Docker Compose 插件(`docker compose version` 可正常输出)。
- 如果需要 k8s 则需要安装 kubeadm 或使用发行版。
- 已有 k8s 集群的情况下只需要安装 kubectl 不需要安装全套。

## 一、获取代码

生产 Compose 使用五个仓库：根仓库作为编排入口，动态前端、静态官网、后端与社区机器人四个子项目各自独立：

```
LKM-Website/                  # 根仓库(含 docker-compose.yml 与本教程)
├── docker-compose.yml
├── DEPLOYMENT.md
├── deploy/
│   ├── initdb/               # PostgreSQL 首启初始化脚本(auth 独立库建库、timescaledb 扩展)
│   ├── apisix/               # 全站公网入口 APISIX 声明式路由/SSL 渲染/冒烟脚本
│   └── certbot/              # certbot 常驻入口脚本(webroot 申请与续期)
├── LKM-official-website/     # 前端仓库(含前端 Dockerfile)
├── LKM-official-static/      # 静态官网仓库(含 static.Dockerfile)
├── LKM-service/              # 后端仓库(含后端 Dockerfile)
└── LKM-bot/                  # 机器人仓库(AstrBot fork,含 Dockerfile;仅 --profile bot 用到)
```

示例:

```sh
git clone https://github.com/LKM-AHZ/LKM-Website.git
cd LKM-Website
git clone https://github.com/LKM-AHZ/LKM-official-website.git
git clone https://github.com/LKM-AHZ/LKM-official-static.git
git clone https://github.com/LKM-AHZ/LKM-service.git
git clone https://github.com/Alma1314/LKM-bot.git   # 仅启用机器人时需要
```

## 二、配置环境变量

在根目录创建 `.env` 文件(compose 会自动读取,**此文件已被 .gitignore 忽略,不要提交**):

```sh
# 三个密钥必须为强随机值、互不相同(生产环境 LKM_ENV=production 会强制校验)
LKM_JWT_SECRET=<64 位以上随机串>
LKM_TOTP_ENCRYPTION_KEY=<64 位以上随机串>
LKM_VERIFICATION_CODE_PEPPER=<64 位以上随机串>

# PostgreSQL 数据库密码(必须设置)
POSTGRES_PASSWORD=<强随机密码>

# 可选:覆盖数据库用户名/库名(默认均为 lkm)
POSTGRES_USER=lkm
POSTGRES_DB=lkm

# Redis(compose 已默认指向 redis 服务,一般无需改动)
# 留空则后端回退到单机内存版限流(共享限流失效);生产建议保留 compose 默认值
# LKM_REDIS_URL=redis://redis:6379/0

# 域名与上传上限(**单一来源**:网关与后端都从这里派生)。
# 换域名只改这三个:render.sh 据此展开 APISIX 的 hosts / CORS 来源 / MinIO Host 改写 / 证书 SNI。
# LKM_COMMUNITY_DOMAINS=lkm-ahz.ltd      # 社群站(/api、/graphql、认证面、MinIO 预签名 host)
# LKM_OFFICIAL_DOMAINS=lkm-ahz.icu       # 官网静态站
# (bot 面板并入社群域子路径 /bot/,无独立域名配置项)
# bot 面板的子路径前缀(**单一来源**,默认 /bot):网关路由 uri/剥前缀正则、面板运行期 base
#   与前端构建期 base 三面都由它派生(改了这一处即全量跟随,细节见「LKM Bot」一节)。
# LKM_BOT_BASE_PATH=/bot
# 上传上限(字节):同一个值同时给后端校验与网关 client-control.max_body_size
# LKM_MAX_UPLOAD_BYTES=104857600
# bot 的上传上限**独立**(bot 单文件 512MB vs 社群站 100MB,共用会把 bot 上传打死)
# LKM_BOT_MAX_UPLOAD_BYTES=550000000

# 公网 Host 白名单(M6.1;compose 已给生产默认值,一般无需改动)。
# 必须含内网服务名与回环(backend,auth,localhost,127.0.0.1),
#   否则容器 healthcheck 直连 127.0.0.1 会被判 400 → 容器长期 unhealthy。
# LKM_ALLOWED_HOSTS=lkm-ahz.ltd,www.lkm-ahz.ltd,backend,auth,localhost,127.0.0.1
#
# 注:**没有** LKM_CORS_ORIGINS。生产不挂应用层 CORS —— backend/auth 无对外端口,流量必经
# APISIX,网关的 cors 插件是唯一权威(来源由上面的域名变量展开)。应用层 CORSMiddleware 只在
# 非生产挂载,供本地前端直连 :8000 跨域调试。

# MinIO 对象存储(必须设置密码;文件库与成员头像均存于此)
MINIO_ROOT_PASSWORD=<强随机密码>
# 可选:MinIO 管理员账号(默认 lkmadmin)
# MINIO_ROOT_USER=lkmadmin
# 可选:S3 桶名/对象 key 前缀(默认 lkm / files)
# LKM_S3_BUCKET=lkm
# LKM_S3_PREFIX=files

# S3 预签名直传/下载的公网地址(浏览器直连 MinIO 用)。
# 默认走站点公网地址经 APISIX /lkm/ 转发(MinIO 不打公网端口),一般无需改动。
# 若 MinIO 暴露了另外的公网端口,改成对应的地址即可。
# LKM_S3_PUBLIC_ENDPOINT_URL=https://lkm-ahz.ltd

# 可选:GitHub OAuth 登录(不启用可留空)
LKM_GITHUB_CLIENT_ID=
LKM_GITHUB_CLIENT_SECRET=

# 可选:RS256/JWKS 非对称签发(批 5)。不配则沿用上面的 HS256 对称密钥,行为不变。
# 启用后 auth 持私钥签发,backend 与 APISIX 网关只用公钥验签(验签方拿不到签发能力)。
#   1) sh deploy/jwt/gen-keys.sh        # 生成 deploy/jwt/keys/{jwt-private,jwt-public}.pem
#   2) 打开下面两行(值是**容器内**路径;compose 已把该目录只读挂到 /etc/lkm/jwt)
# LKM_JWT_PRIVATE_KEY_FILE=/etc/lkm/jwt/jwt-private.pem
# LKM_JWT_PUBLIC_KEY_FILE=/etc/lkm/jwt/jwt-public.pem
#   3) docker compose up -d --no-deps auth backend apisix-render apisix
#   4) 确认无回归后关掉 HS 回退完成切换(批 1 已重建库、无存量 token,可直接关)
# LKM_JWT_HS_FALLBACK=false
# 注:网关验签目前挂在后台会话端点 /api/v1/admin/auth/me(公开只读接口必须保持匿名);
#    公钥可经 https://<社群域名>/.well-known/jwks.json 获取。
```

生成随机密钥:

```sh
openssl rand -hex 48
```

> 若启用 GitHub OAuth,需在 GitHub App 后台把回调地址设为
> `https://lkm-ahz.ltd/api/v1/auth/oauth/github/callback`（若更换域名，OAuth 平台配置也必须同步）。

## 三、构建并启动

```sh
cd LKM-Website
docker compose up -d --build
```

首次构建需拉取基础镜像与依赖,可能耗时数分钟。启动顺序由 `depends_on` 健康检查保证:先 `postgres`、`redis`、`minio`、`pulsar` 就绪,再启动 `backend`/`auth` 与各 `worker`,前端 `astro`/`static` 就绪后网关 `apisix` 再启动。其中 `pulsar` 的 `healthy` **已蕴含**租户与 namespace 初始化完成(见上「Pulsar 无状态化」),故不存在等待一次性 init 容器的步骤。

## 三·六、网关：APISIX

接入层为 **APISIX standalone**（无 etcd，路由声明式来自 `deploy/apisix/apisix.yaml`）：

- `apisix-render` sidecar 读路由模板 + certbot 证书，渲染出内联 PEM 的 `ssls` 段写入共享卷（每 6h 或重启时重渲染），APISIX 监测文件变化自动 reload。
  它同时是**网关配置的单一模板展开点**：模板里只放占位，域名与请求体上限从环境变量展开——
  `LKM_COMMUNITY_DOMAINS`/`LKM_OFFICIAL_DOMAINS` → 各路由 `hosts`、CORS `allow_origins`、MinIO Host 改写、证书 SNI；
  `LKM_MAX_UPLOAD_BYTES` → 社群站各路由 `client-control.max_body_size`（与后端校验同源），
  `LKM_BOT_MAX_UPLOAD_BYTES` → **仅** bot 路由的同名项（bot 单文件上限 512MB，与社群站不可共用），
  `LKM_BOT_BASE_PATH` → bot 三条路由的 `uri` 与剥前缀正则（`proxy-rewrite.regex_uri`）的匹配串，
  与面板自身的 dashboard base / 前端构建期 base 同一来源（改一处三面跟随，见「LKM Bot」一节）。
  模板里若残留未展开占位，render 会**拒绝覆盖**上一版配置并在日志报错，不会把坏 YAML 喂给 APISIX。
- `acme-webroot` 是极小的 http-01 challenge 静态 responder（不承担网关路由）。
- **CORS 与登录限流的归属**：CORS 只在网关（应用层生产不挂，非生产才挂供本地跨域调试）；
  登录限流是**两层分工而非重复**——网关按 IP 粗粒度削峰（`policy: local`、60/60s），
  应用做账号级精确锁定（用户名级 + 真实 IP 级 Redis 滑动窗口，IP 取自网关注入的 `X-Real-IP`）。
  两层数值刻意不同，不要当成"重复"去同步。
- **nginx 已彻底移除**：全栈仅存的 nginx 镜像是 `acme-webroot` 与官网 `static` 两处**静态文件服务器**角色（非网关），二者与
  APISIX 是互补关系而非重叠。

**运行时冒烟/验收**（网关 up 后，在仓库根执行）：

```sh
sh deploy/apisix/smoke.sh 127.0.0.1          # 13 项：301(社群/官网)/健康/GraphQL/限流/MinIO/缓存/WS/…
SMOKE_HEAVY=1 sh deploy/apisix/smoke.sh      # 追加 100m 上传边界（真发 ~101MB）
SMOKE_BOT=1 sh deploy/apisix/smoke.sh        # 追加 /bot 面板可达（需先 --profile bot 起 lkmbot）
```

脚本用 `--resolve <域名>:<端口>:127.0.0.1` 保证 TLS SNI 正确（APISIX 按 SNI 选证书，直连 IP 无 SNI 会握手失败），并用 `--noproxy '*'` 绕过宿主机代理。

## 三·七、Prefect 编排

复杂数据管道（首期为 `user_dim` 报表宽表对账/回填）由 Prefect flow 编排，APScheduler 仍只做简单 cron 触发入口。默认**不启用**——cron 消费者直调既有 ETL，行为与现状一致。

启动与接线：

```sh
# 1) 起 server/worker（独立 prefect 库，UI 不发布公网端口）
docker compose --profile prefect up -d
# 2) 根 .env 配齐并开启（见 .env.example Prefect 块），重建 jobs worker 使其改走触发：
#    LKM_PREFECT_ENABLED=true
#    LKM_PREFECT_API_URL=http://prefect-server:4200/api
#    LKM_PREFECT_DEPLOYMENT=user-dim-reconcile/reconcile
docker compose up -d --force-recreate worker
```

运维：

```sh
# Prefect UI：server 只 expose 4200，经 SSH 隧道访问
ssh -L 4200:127.0.0.1:4200 <server>   # 本地开 http://127.0.0.1:4200
# 查看 flow run
docker compose exec prefect-worker prefect flow-run ls
# 手动触发一次对账
docker compose exec prefect-worker prefect deployment run 'user-dim-reconcile/reconcile'
# 回填指定用户（在 worker 容器内以本地代码执行 flow）
docker compose exec prefect-worker python -m app.flows.user_dim --backfill --ids 1,2,3
```

- 触发失败 **fail-open 回落直调**，crash-safety 对账不会因编排层故障丢跑；`LKM_PREFECT_ENABLED=false` 即整体回退。
- flow 复用既有 ETL 入口，保持「命令数恒定 / 跨 auth+业务双会话 / 幂等」不变量。

## 三·八、ClickHouse 分析管道

日志 / 失败事件 / 审计的检索与分析，两路数据：**vector** 采集各容器 stdout/stderr 的结构化 JSON 日志 → `lkm.app_logs`；**Prefect flow** 周期把 `event_failures`（业务库）+ `audit_logs`（auth 独立库）按水位增量导出到 CH。默认**不启用**——导出 no-op、admin 分析查询端点返 503。

启动与接线：

```sh
# 1) 起 ClickHouse + vector（数据卷首启执行 deploy/clickhouse/init.sql 建库建表）
docker compose --profile clickhouse up -d
# 2) 根 .env 配齐并开启（见 .env.example ClickHouse 块），重建 backend/worker：
#    LKM_CLICKHOUSE_ENABLED=true
#    LKM_CLICKHOUSE_URL=http://clickhouse:8123
#    CLICKHOUSE_PASSWORD=<强随机>   # 同时用于 CH 服务、vector、后端
docker compose up -d --force-recreate backend worker
# 3) 可选：走 Prefect 触发导出（需先按三·七起 profile=prefect）
#    LKM_PREFECT_ANALYTICS_DEPLOYMENT=analytics-clickhouse-export/analytics-export
```

验收：

```sh
# 建表 + 日志已入库
docker compose exec clickhouse clickhouse-client --query "SHOW TABLES FROM lkm"
docker compose exec clickhouse clickhouse-client --query "SELECT count() FROM lkm.app_logs"
# 触发一次导出并核对计数；重跑计数不变（CH 侧 max(id) 水位幂等）
docker compose exec prefect-worker prefect deployment run 'analytics-clickhouse-export/analytics-export'
docker compose exec clickhouse clickhouse-client --query "SELECT count() FROM lkm.event_failures"
# admin 查询（须带后台 cookie；dataset ∈ app_logs / event_failures / audit_logs）
curl -s 'http://<host>/api/v1/admin/analytics/app_logs?limit=5' -b 'lkm_admin_access=<cookie>'
```

- 表 TTL：`app_logs` 30 天 / `event_failures` 180 天 / `audit_logs` 365 天（**固定值**；改 `deploy/clickhouse/init.sql` 后需重建数据卷 `docker compose --profile clickhouse down -v` 才生效）。
- CH 未启用 / 不可达时：admin 查询返 **503**（不返空列表），周期导出 no-op 不报错。
- 回退：`LKM_CLICKHOUSE_ENABLED=false`（默认）+ `docker compose --profile clickhouse down`，不影响主栈。

## 三·九、监控面板

Prometheus 抓 `backend` 的 `/metrics`，Grafana 预置「LKM 后端总览」面板。默认不启：

```sh
# 1) 拉起（根 .env 可设 LKM_GRAFANA_ADMIN_PASSWORD，默认 admin）
docker compose --profile monitoring up -d prometheus grafana

# 2) 打开面板（默认只绑回环，不对外暴露）
#    http://127.0.0.1:3000  →  面板「LKM 后端总览」
```

面板内容：QPS（按 handler）、延迟 P50/P95、5xx 错误率、**outbox 积压**
（`outbox_pending_count`）、**Pulsar 订阅 lag**（`pulsar_subscription_backlog`）、
GraphQL P95 与受控拒绝速率。

- 数据源与面板由 `deploy/grafana/provisioning` 预置（改面板改 `deploy/grafana/dashboards/lkm-overview.json`，30 秒自动重载）。
- **已知限制**：`/metrics` 只挂在单体 `backend`；auth 进程刻意不挂，故面板无 auth 的 QPS/延迟。
- 回退：`docker compose --profile monitoring down`（保留卷则历史保留；加 `-v` 一并清理）。

## 三·十、SigNoz 自托管 APM（可选）

链路追踪后端：应用 span → 本栈的 `otel-collector` → SigNoz → ClickHouse → UI。默认不启。

```sh
# 1) 拉起采集与追踪后端（两个 profile 都要：otel 是应用侧采集器，signoz 是后端）
#    并让应用开始产生 span
#    （根 .env：LKM_OTEL_ENABLED=true、LKM_OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318/v1/traces）
docker compose --profile otel --profile signoz up -d

# 2) 首次必须注册组织（SignNoz 的 opamp 下发配置需要 orgId；
#    未注册时 collector 会一直处于「只起 extension、不监听 4318」的状态）
curl -s -X POST http://127.0.0.1:8080/api/v1/register -H 'Content-Type: application/json' \
  -d '{"name":"Admin","email":"admin@example.com","password":"<强密码>","orgName":"LKM"}'
docker compose restart signoz-otel-collector   # 注册后立即重连，否则等 30s 重试

# 3) 打开 UI（只绑回环；SigNoz 无内置鉴权，勿直接暴露公网）
#    http://127.0.0.1:8080  →  Services / Traces
```

- **资源占用大**：SigNoz 自带一套 ClickHouse + ZooKeeper（与日志分析用的 `profile: clickhouse`
  **不是同一套**，两者 schema 不兼容，刻意各自独立）。建议空闲内存 ≥4GB。
- **配置单一来源**：`deploy/signoz/` 是 SigNoz 官方 **v0.128.0** `deploy/{docker,common}` 的
  vendor 副本（上游 main 已改用 Foundry 安装，故钉死 tag）。**不要手改这些文件**——升级即整目录替换；
  环境差异（主机名解析）用 compose 网络别名吸收，不改配置。
- **已知限制**：
  - `signoz-init-clickhouse` 需容器出网拉 `histogramQuantile` UDF；离线环境下会跳过，
    ClickHouse 照常可用，只有用到该函数的查询（部分告警/面板）会报函数缺失。
  - `signoz-otel-collector` 的 OTLP 端口（4317/4318）**不发布到宿主**，仅经应用侧 collector 进入；
    外部代理需自行经网关加鉴权后再放行。
- 回退：`docker compose --profile signoz down`（数据在 `signoz_*` 命名卷里，加 `-v` 一并清理）。

## 三·十一、LKM Bot 社区机器人(可选,`--profile bot`)

`LKM-bot/` 是 AstrBot 的 fork，提供 IM 平台接入与机器人面板。**默认不随主栈启动**——面板是大镜像
（含 nodejs/ffmpeg）。面板挂在**社群域的子路径 `/bot/`**（不再是独立子域名），并由社区后台
「机器人」菜单以同源 iframe 内嵌；它自带的 `/api/v1/*` 与社区站同前缀，靠网关 `proxy-rewrite`
**剥掉 `/bot` 前缀**隔离（剥掉后面板进程仍以根路径服务，社区站 backend 路由不受影响）。

```sh
# 1) .env：配面板初始密码（留空则面板自生成随机密码并打到日志）
#    LKM_BOT_DASHBOARD_PASSWORD=<强随机>
# 2) SSO 免登（可选但推荐）：配好 RS256 密钥（含公钥），见「RS256 网关验签」一节
#    sh deploy/jwt/gen-keys.sh         # 未配则面板回落自带登录页，其余功能不受影响
# 3) 起 bot（网关 /bot 路由随主栈起时已生效，无需重启 apisix）
docker compose --profile bot up -d --build
# 4) 验收
SMOKE_BOT=1 sh deploy/apisix/smoke.sh 127.0.0.1
```

访问方式（二选一，同一个面板）：

- **社区后台 →「机器人」菜单**（推荐）：管理员已登录后台即免登进入（SSO）。
- 直接开 `https://lkm-ahz.ltd/bot/`：无后台会话时落到面板自带登录页（账号/密码见首启日志或
  上面的 `.env`）。

回退：`docker compose --profile bot down`（bot 数据在宿主机目录里，不受 `-v` 影响）。

**子路径前缀是单一来源**：面板涉及三处前缀，全部由 `.env` 的 `LKM_BOT_BASE_PATH`（默认 `/bot`）
派生，改这一处即全量跟随，不要再分别改：

| 消费点 | 形态 | 来源 |
| --- | --- | --- |
| 网关路由 `uri` 与剥前缀正则 | 无尾斜杠 | `render.sh` 展开 `__BOT_BASE_PATH__`（compose 传 `APISIX_BOT_BASE_PATH`；k8s 取 `lkm-gateway-config/LKM_BOT_BASE_PATH`）|
| 面板运行期 `ASTRBOT_DASHBOARD_BASE_PATH` | 无尾斜杠 | compose 展开同一变量；k8s 的 lkmbot 部署读 `lkm-gateway-config/LKM_BOT_BASE_PATH` 同一个键 |
| 前端构建期 `VITE_BASE_PATH` | **带尾斜杠** | compose `build.args` 展开同一变量 |

**首次构建**：面板前端 `dist` **由镜像内构建**（多阶段 Dockerfile），因此构建机需要能访问
npm registry。`LKM-bot/Dockerfile` 的 `ARG VITE_BASE_PATH` 默认值是 `/`（上游语义：镜像与部署
位置无关），**挂子路径的部署必须显式传参** —— compose 已从 `LKM_BOT_BASE_PATH` 传入，故
`docker compose --profile bot build lkmbot` 构建出的 dist 带正确 base；直接 `docker build`
不带参数得到的是根 base 包，挂到子路径下静态资源会 404。构建用 `pnpm build:subpath`
（跳过 `vue-tsc`，类型检查在开发侧做）。

**systemd 单元不参与本部署**：`deploy/systemd/lkmbot.service` 是 LKM-bot standalone（系统包
管理器 / AUR，见 `LKM-bot/docs/*/deploy/astrbot/sys-pm.md`）安装路径的 `systemd --user` 单元，
本站用 compose / k8s，**不使用**它（从 `LKM-bot/scripts/` 迁到此处归档，以免看起来像本项目的
部署面）。

**SSO 票据的协议值是单一来源**：`LKM_BOT_SSO_AUDIENCE` / `LKM_BOT_SSO_ISSUER` 由 compose 的
`x-bot-sso-env` 锚点**只写一次**默认值、同时注入 auth（签发侧）与 lkmbot（消费侧）；k8s 侧为
`lkm-config-botsso` 一张表，两侧读同一个键（`lint-imports` 之外，另有静态测试锁两侧默认值一致）。
消费侧**现在会校验 `iss`**——此前签发时写入 `iss` 却从不校验，等于放行任何持同一 audience 的
签发方；不符或缺失一律 302 回面板登录页（fail-safe，不会变成 5xx）。另外三个协议值
（`type`/`ttl`/`account_level`）刻意不做部署变量，理由见 `.env.example` 的「LKM Bot」段。

**端口面**——只经网关：

- 面板 `6185` **不发布到宿主**，对外只经 APISIX 的 `/bot/*` 路由（含面板 WebSocket）。
- OneBot v11 `6199` 同样不发布，按 NapCat 的位置二选一：
  - **同机容器**（推荐）：让 NapCat 加入 `lkm` 网络，连 `ws://lkmbot:6199/ws`，无需开端口。
  - **异机**：自行加端口映射（建议绑内网网卡，如 `127.0.0.1:6199:6199`）并在 bot 配置里设 token；
    不要把 6199 挂到 `/bot` 路径上（`/ws` 与面板同 host，鉴权与协议都不同）。

**请求体上限独立**：bot 允许单文件 512MB，而社区站是 100MB，故用 `LKM_BOT_MAX_UPLOAD_BYTES`
（默认 550000000）单独展开到 `/bot` 路由——两个值**不要**合并成同一个变量。

**数据目录**：`./LKM-bot/data`（宿主机 bind，非命名卷）。必须 bind 的原因见下条沙箱共享目录；
副作用是该目录归 root 所有，非 root 运维删除需 sudo。

**⚠️ 不要在面板里用「WebUI 在线更新」**：该功能会下载上游 registry 的 dist（**根 base**）覆盖
`data/dist`，而它的优先级高于镜像内置的 dist —— 一旦覆盖，`/bot/` 下的静态资源与 API 前缀全部
失配（面板白屏）。升级面板请走**重建镜像**（`docker compose --profile bot build lkmbot`）。

**⚠️ 面板里的平台回调地址要带 `/bot` 前缀**：`callback_api_base`（面板「配置」里）用于给外部
IM 平台回调用，需填 `https://lkm-ahz.ltd/bot`，否则回调会打到社区站 backend（`/api/v1/webhooks/...`
同前缀）。

**升级注意**：`/bot` 路由不新增证书域，故不再需要单独首签子域证书——`render.sh` 的证书域集合
只剩社群/官网两个（旧部署里残留的 `bot.lkm-ahz.ltd` 证书目录可删）。

**代码沙箱（shipyard，同一 profile）**：

- ⚠️ **安全面**：shipyard 挂 `/var/run/docker.sock`（≈把宿主机 root 交给容器），因此它只在
  `--profile bot` 下启用、用完即 `down`；它 spawn 的沙箱容器落在独立网络 `lkm-bot-sandbox`，
  刻意**不接** `lkm`，否则沙箱里跑的模型生成代码就能直连 postgres/redis/minio。
- ⚠️ **与 bot 默认 booter 不匹配**：bot 默认 `sandbox.booter=shipyard_neo`，而本服务是**旧版 Bay**。
  要生效需在面板「配置 → 沙箱」把 booter 改成 `shipyard`，endpoint 填 `http://shipyard:8156`，
  access token 填 `LKM_BOT_SHIP_ACCESS_TOKEN`。不改则沙箱功能不生效（`computer_use_runtime`
  默认 `none`，不影响 bot 其余功能）。
- `LKM_BOT_SHIP_DATA_DIR` 必须是**宿主机绝对路径**（Bay 原样交给 Docker API 做 bind），默认取
  `${PWD}/LKM-bot/data/shipyard/ship_mnt_data`，故 compose 必须在仓库根执行。

## 三·五、无域名 / 公网 IP 直连(可选)

没有域名时,用公网 IP 直连(如 `http://<公网IP>`)。需把域名配置
替换为你的公网 IP,并把访问方式从「强制 HTTPS」改为「HTTP 为主 + 自签证书兜底」。

改造点(改了如下文件,按你机器 IP 替换,勿再 clone 到默认域名配置):

```sh
# 1. 根仓库 docker-compose.yml:后端域名变量改成 IP(HTTP)
LKM_RP_ID: <公网IP>
LKM_ORIGIN: http://<公网IP>
LKM_GITHUB_REDIRECT_URI: http://<公网IP>/api/v1/auth/oauth/github/callback
LKM_FRONTEND_CALLBACK: http://<公网IP>/login/success

# 2. 前端
#    src/data/config.yaml:site 改为 http://<公网IP>
#    如启用了开发服务器 Host 限制，将 <公网IP> 加入对应 allowlist

# 3. deploy/apisix/apisix.yaml:各路由 hosts 列（IP 无法配 hosts，需另加按 priority 兜底的路由）；
#    deploy/apisix/config.yaml 的 redirect.https_port 与 dns 解析按需调整
```

> **注**：网关为 APISIX，无域名/IP 直连改造只需改上述第 3 步（`deploy/apisix/` 下两个YAML），未在本教程展开。

- **certbot 服务可停**(`docker compose stop certbot`):无域名不签正式证书,其会循环空跑 renew 报错污染日志。
- **403 后台明文限制**:admin 后台 cookie 带 `Secure`,**纯 HTTP(80)下浏览器不发送** → 后台登录会话无法保持。
  后台请走 **`https://IP`**(自签证书,浏览器首次点"继续访问/信任")。普通用户前台走 JWT,HTTP 下正常。
- 浏览器访问 `http://<公网IP>` 即可查看站点。

## 四、首次签发 HTTPS 证书

`apisix-render` 首次渲染时若发现无证书,会生成自签占位证书(保证 APISIX 能带 TLS 启动)。正式签发:

```sh
docker compose run --rm --entrypoint certbot certbot certonly --webroot \
  -w /var/www/certbot -d lkm-ahz.ltd

# 触发 apisix-render 立即重渲染（把新证书内联进 ssls 段），APISIX 监测到文件变化自动 reload
docker compose restart apisix-render
```

签发成功后证书落在 `certbot_conf` 卷(`/etc/letsencrypt`),重渲染后 443 端口即使用正式证书。
(平时无需手动:`apisix-render` 每 6h 重渲染一次,会顺带拾取续期后的新证书。)

## 五、验证

```sh
# 首页
curl -I https://lkm-ahz.ltd/

# HTTP 应 301 到 HTTPS
curl -I http://lkm-ahz.ltd/

# 后端健康检查
curl https://lkm-ahz.ltd/api/v1/health
# 期望: {"code":0,"msg":"OK","data":{"status":"ok"}}

# GraphQL(示例查询)
curl -X POST https://lkm-ahz.ltd/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ __typename }"}'

# 静态资源缓存头(应含 Cache-Control: public, immutable)
curl -I https://lkm-ahz.ltd/_astro/<某资源路径>

# 成员头像(头像已对象存储化,key 形如 avatars/<uid>/v<ms>.webp,经 /avatar/{user_id} 读取)
curl -I https://lkm-ahz.ltd/api/v1/avatar/<user_id>
# 期望: 200(头像由后端从 S3 流式返回)

# 证书链与有效期
openssl s_client -connect lkm-ahz.ltd:443 </dev/null 2>/dev/null | openssl x509 -noout -dates
```

## 六、证书续期(自动)

- `certbot` 容器每 12 小时执行 `certbot renew`,证书文件原地更新。
- `apisix-render` 容器每 6 小时重渲染一次 `apisix.yaml`(内联新证书),APISIX 监测文件变化自动 reload。
  该重渲染同时刷新 upstream DNS 解析(standalone 为静态解析,后端容器换 IP 靠此自愈)。

无需人工干预;证书与续期状态都在 `certbot_conf` 卷,容器重建不丢。

## 七、常用运维

```sh
# 查看状态
docker compose ps

# 查看日志
docker compose logs -f apisix       # 网关(唯一对外入口,访问日志在此)
docker compose logs -f backend
docker compose logs -f worker       # 任务队列消费
docker compose logs -f worker-send  # 发送队列
docker compose --profile bot logs -f lkmbot   # 机器人面板(可选组件)

# 重启单个服务
docker compose restart backend

# MinIO Web 控制台(9001)仅在容器内网,未对外映射;需要浏览器访问时,
# 在 docker-compose.yml 的 minio 服务临时加 `ports: ['9001:9001']` 后 `docker compose up -d minio`,
# 访问 http://<主机IP>:9001,账号见 .env 的 MINIO_ROOT_USER/PASSWORD。或用镜像内置的 mc 命令行:
docker compose exec minio mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
docker compose exec minio mc ls local/lkm   # 列出默认桶内容

# 更新代码后重新构建并重启
git pull
docker compose up -d --build
```

## 八、Kubernetes 部署（可选，与 compose 并列）

除本教程的 compose 形态外，仓库另提供一套 **Kustomize 清单**把整栈搬到 k8s，
入口是 [`deploy/k8s/README.md`](deploy/k8s/README.md)：

```sh
# Secret 与网关证书（从根目录 .env 与自签证书生成）
sh deploy/k8s/gen-secret.sh | kubectl apply -f -
sh deploy/k8s/gen-tls.sh    | kubectl apply -f -
# 建命名空间（Secret 要落进来）
kubectl apply -f deploy/k8s/base/namespace.yaml
# 应用（--load-restrictor 必需：清单直接引用 deploy/ 下的既有资产，不复制副本；
# 且 `apply -k` 不接受该标志，故先渲染再 apply）
kubectl kustomize deploy/k8s/overlays/kind --load-restrictor LoadRestrictionsNone | kubectl apply -f -
```

- **覆盖范围**：与本文的 compose 栈逐服务一一对应（网关 + 应用层 + 全部有状态中间件），
  不是另一套架构。两套编排并列、互不依赖，可随时回退。
- **单一来源**：路由模板、initdb 脚本、ClickHouse DDL、OTel 配置等仍只有一份文件，
  compose 与 k8s 共用；`render.sh` 把运行时差异（上游 DNS、服务名后缀）从环境变量展开。
- **差异与坑**：启动顺序用 Job/initContainer 替代 `depends_on`、可选组件由 `--profile`
  改为副本数、证书改 Secret 载体、探针必须用 `exec`（`httpGet` 的 Host 是 Pod IP，
  会被 `LKM_ALLOWED_HOSTS` 判 400）等，逐条列在 `deploy/k8s/README.md`。
- **bot 也是可选组件**：`deploy/k8s/base/app/lkmbot.yaml` 默认 `replicas: 0`，启用用
  `kubectl -n lkm scale deploy/lkmbot --replicas=1`（镜像 `lkm-bot:latest` 需自行构建/推仓）。
  **shipyard 沙箱在集群内不交付**（Bay 依赖 Docker API 在宿主 spawn 兄弟容器，与 k8s 模型不兼容），
  需要沙箱时指向集群外的 Bay，见 `deploy/k8s/README.md`「已知限制」。
- 本地无集群时可用 kind 验收：`sh deploy/k8s/overlays/kind/setup.sh`。

## 数据库

### 默认方案：docker 内置 PostgreSQL(TimescaleDB)

`docker compose up` 会自动拉取 `timescale/timescaledb:latest-pg16` 镜像并启动;后端首次启动时自动建表(默认通道 `LKM_USE_ALEMBIC=false` 走 `create_all`,见后端 README),无需手动初始化。

**为什么是 TimescaleDB 版**:`outbox_events`/`outbox_archived` 被装配为 **hypertable**(按 `created_at` 自动时间分区 + 冷历史列式压缩 + 保留策略兜底),详见《执行路线图》§8 #40。该引擎是 PG16 的超集,其余功能与 `postgres:16-alpine` 无差别;`prefect-postgres`、`infisical-db` 仍是原镜像。

两点部署注意:

- **hypertable 的每个唯一索引必须含分区列** → 这两张表的主键是 `(created_at, id)`。因此**从旧数据卷升级不能就地生效**:`create_all` 通道只增不改(PK 是破坏性变更),需重建数据卷 `docker compose down -v`(注意会清空 `lkm`/`lkm_auth` 全部数据)后重起。开发期无生产数据,按蓝图「不做存量迁移」口径直接重建。
- 引擎不可用时(如误用普通 PG 镜像或手工安装的主机 PG)**不会导致启动失败**:`init_db` 会告警并降级为**普通表**——主键多一列 `created_at` 无副作用,outbox 投递语义完全不变,只是失去分区裁剪/压缩。

连接数据库:

```sh
docker compose exec postgres psql -U lkm -d lkm
```

常用 SQL:

```sql
\dt          -- 列出所有表
\d users     -- 查看某张表结构
```

手动执行迁移(一般不需要,后端启动已自动执行):

```sh
docker compose exec backend alembic upgrade head
docker compose exec backend alembic current
```

备份与恢复:

```sh
# 备份
docker compose exec -T postgres pg_dump -U lkm lkm > backup_db_$(date +%F).sql

# 恢复
docker compose exec -T postgres psql -U lkm -d lkm < backup_db.sql
```

### 可选方案：主机手动安装 PostgreSQL

若需复用主机已有数据库实例,可在主机直接安装 PostgreSQL 并让后端连接外部库。

> **注意**:此路径下**没有 TimescaleDB**,outbox 两表会降级为普通表(启动时告警、不影响功能,但没有分区裁剪与压缩)。要用 hypertable 请装 `timescaledb` 版并预加载 `shared_preload_libraries`,或直接用上面的 docker 方案。

1. 安装并启动:

```sh
sudo apt update && sudo apt install -y postgresql postgresql-contrib
sudo systemctl enable --now postgresql
```

2. 建库建用户:

```sh
sudo -u postgres psql -c "CREATE USER lkm WITH PASSWORD '<强密码>';"
sudo -u postgres psql -c "CREATE DATABASE lkm OWNER lkm;"
```

3. 允许 Docker 容器连接:

- 编辑 `/etc/postgresql/*/main/postgresql.conf`,将 `listen_addresses` 改为 `'*'`。
- 在 `/etc/postgresql/*/main/pg_hba.conf` 末尾追加一行:

```
host all lkm 172.16.0.0/12 scram-sha-256
```

- 重启:

```sh
sudo systemctl restart postgresql
```

4. 修改 `docker-compose.yml`:删除 `postgres` 服务,并把 `backend` 的数据库连接指向宿主机:

```yaml
  backend:
    environment:
      LKM_DB_HOST: 172.17.0.1   # 宿主机在 docker 网桥上的地址
      LKM_DB_PORT: 5432
      LKM_DB_NAME: lkm
      LKM_DB_USER: lkm
      LKM_DB_PASSWORD: <与建库时一致>
```

然后重新启动:

```sh
docker compose up -d backend
```

> docker 内置库零配置、随仓库走、备份简单,推荐默认使用;主机手动安装适用于复用已有数据库实例或需要更细管控的场景。

## 数据持久化

- 数据库在 `postgres_data` 卷(postgres 容器 `/var/lib/postgresql/data`)。
- Redis 在 `redis_data` 卷(redis 容器 `/data`,已开启 AOF `appendonly yes`;内容多为可重建的限流/缓存数据,一般无需单独备份)。
- 文件库上传文件与成员头像存在 **MinIO** 对象存储(`minio_data` 卷);后端以 S3 兼容接口读写。
- 博客 git 仓库(`blog_repos/`)在 `backend_data` 卷,挂载到后端容器 `/data`(`files_store` 为存量迁移源,运行时不写)。
- 备份示例:

```sh
# 数据库
docker compose exec postgres pg_dump -U lkm lkm > backup_db_$(date +%F).sql

# MinIO 对象(含文件库与头像)
docker compose exec minio sh -c 'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc mirror --preserve m/lkm ./minio_backup_$(date +%F)'

# 后端卷(博客 git 仓库)
docker run --rm -v lkm_backend_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/backend_files_$(date +%F).tar.gz -C /data .
```

## MinIO 首次初始化(建桶)——必做!

**后端 S3 存储不会自动创建 MinIO 桶**。新部署的 MinIO 里没有 `lkm` 桶,文件库上传与头像读写会全部 404/失败。
启动前先建桶:

```sh
# 建桶(桶名=LKM_S3_BUCKET,默认 lkm)
docker exec <minio容器名> sh -c 'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc mb --ignore-existing m/lkm'
```

> 头像与文件库对象都在该桶内;上传/上传后由后端写回 MinIO,无需再手动预置。

## 迁移存量到 MinIO

首次从「本地磁盘存储」切换到 MinIO 时,若本地文件库已有存量,在**切换前**(`LKM_STORAGE_BACKEND=s3` 生效前)执行一次性迁移脚本把本地数据搬进 MinIO(幂等,空数据安全跳过):

```sh
cd LKM-service
# 需先配好指向 MinIO 的 LKM_STORAGE_BACKEND=s3 及 s3_* 连接参数
./.venv/Scripts/python.exe -m scripts.migrate_files_to_s3       # 文件库存量
```

## 常见问题

- **后端反复重启(Exited 3)**:通常是密钥缺失或过短。确认 `.env` 中三个密钥已设置为强随机值,并 `docker compose up -d` 重读。
- **上传大文件被拒**:APISIX 路由已设 `client-control.max_body_size: 104857600`(100m),与后端 `max_upload_bytes` 对齐;更大文件需同时改 `deploy/apisix/apisix.yaml` 与后端配置。
- **数据库**:使用 PostgreSQL(`timescale/timescaledb:latest-pg16` 服务,卷持久化)。后端经 `LKM_DB_*` 环境变量以 `postgresql+asyncpg` 连接;首次启动时自动建表(默认走 `create_all` 通道)。**换库/改 schema 后需重建数据卷**(`docker compose down -v`,见「数据库」章节)。
- **换域名**:网关侧只需在 `.env` 改 `LKM_COMMUNITY_DOMAINS` / `LKM_OFFICIAL_DOMAINS`(hosts、CORS 来源、MinIO Host、证书 SNI 全量跟随,见「单一来源」),再 `docker compose up -d apisix-render` 重渲染(bot 面板随社群域走,无需额外 DNS/证书);此外还要改后端**自身身份**类配置 `LKM_ALLOWED_HOSTS`/`LKM_ORIGIN`/`LKM_RP_ID`/`LKM_GITHUB_REDIRECT_URI`/`LKM_FRONTEND_CALLBACK`/`LKM_S3_PUBLIC_ENDPOINT_URL` 与前端 `PUBLIC_SITE_URL`/`PUBLIC_BASE_PATH`,并重新签发证书。

- **头像/文件上传 404**:MinIO 桶未创建(S3 不自动建桶)。先 `mc mb .../lkm` 建桶(见上文「MinIO 首次初始化」)。

- **上传返回 403 SignatureDoesNotMatch**:boto3 对 MinIO 默认生成 SigV2 签名,MinIO 不认 → 需在 s3.py 预签名 client 显式 `signature_version="s3v4"` + `addressing_style="path"` + 给 region。且预签名 URL 的 host 必须与浏览器实际访问的 host 一致(`LKM_S3_PUBLIC_ENDPOINT_URL`)。

- **上传经 APISIX 后 400 Bad Request**(而直连 MinIO 正常)**:MinIO 路由的 Host 必须落为公网站点(SigV4 预签名按公网 host 签)(`deploy/apisix/apisix.yaml` 的 `minio` 路由用 `pass_host: rewrite` + `upstream.upstream_host`;用插件 `proxy-rewrite.host` 会被 pass_host 以 nil 覆盖 → 空 Host → MinIO 400)。

- **MinIO 建议经 APISIX 转发而非开公网 9000**:compose 里 minio 保持仅内网,由 APISIX `/lkm/` 路径转发;安全组只需放行 80/443。

- **后台登录后操作报「需要 MFA」**:登录不再强制 2FA(对齐 GitHub),仅后台危险操作(板块审核等)要求 2FA;通过后信任 1 小时。首次需在后台完成 2FA 设置。
