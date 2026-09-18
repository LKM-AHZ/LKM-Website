# LKM 网站部署教程

本文档说明如何把 LKM 网站(前端 Astro + 后端 FastAPI)通过 APISIX 统一入口部署到生产主机。

> **当前实际部署为「测试 IP 直连」模式**:无正式域名,对外走测试 IP `124.220.55.235`(HTTP 为主 +
> 自签证书兜底)。下文把「正式域名 + Let's Encrypt」作为可选路径,与「三·五 无域名/公网 IP 直连」
> 一节并列;当前线上的镜像与配置已按测试 IP 部署。

## 架构概览

单机 docker-compose 编排,APISIX 为唯一对外入口(**全栈唯一网关**;nginx 已彻底移除):

| 服务 | 镜像 | 端口(对外) | 职责 |
|---|---|---|---|
| `apisix` | `apache/apisix:3.9.0-debian` | `80` / `443` | **唯一网关**:TLS 终止、HTTP→HTTPS 重定向、反代分流、gzip、CORS 白名单、限流 |
| `apisix-render` | `alpine:3.19` | 无 | 纯 shell sidecar:把证书内联进 apisix.yaml 并每 6h 重渲染(触发 APISIX reload) |
| `acme-webroot` | `nginx:1.27-alpine` | 无 | 微型静态 responder:仅服务 ACME `/.well-known/acme-challenge/`(非网关角色) |
| `certbot` | `certbot/certbot` | 无 | 申请与自动续期 Let's Encrypt 证书(webroot) |
| `astro` | `lkm-official-website:latest` | 仅内网 `4321` | 前端 SSR |
| `static` | `lkm-official-static:latest` | `8082` | 纯静态官网(独立静态文件服务器) |
| `backend` | `lkm-service:latest` | 仅内网 `8000` | FastAPI(REST `/api/v1`)+ 论坛域 GraphQL + lag 上报 |
| `auth` | `lkm-service:latest` | 仅内网 `8001` | AUTH 独立进程(`app.main_auth`) |
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
| `postgres` | `postgres:16-alpine` | 仅内网 `5432` | 后端数据库(biz `lkm` + auth `lkm_auth`) |
| `redis` | `redis:7-alpine` | 仅内网 `6379` | leader 租约、共享限流 / 缓存 |
| `pulsar` | `apachepulsar/pulsar:3.3.0` | 仅内网 `6650`/`8080` | **消息总线**(standalone,自带 ZK+BookKeeper;6650 broker / 8080 Admin REST)。**无状态化**启动包装,见下 |
| `minio` | `minio/minio:latest` | 仅容器内 `9000`/`9001` | S3 兼容对象存储:文件库文件与成员头像 |

> `worker*` 与 `backend`/`auth` 共用 `lkm-service:latest` 镜像,仅启动入口不同;各自常驻消费
> 一个 Pulsar 订阅(get 消费失败重投超限后进死信 topic `system/dlq`,由 `worker-dlq` 落库)。
> points 拆三个订阅(reward/stats/tasks)消费同一 `biz/points.apply` topic 实现扇出与故障隔离;
> `worker-notification`(M6.8)以第四个订阅消费同一 topic 生成站内信,同样独立记账、互不阻塞。

> **Pulsar 无状态化(2026-09-17)**:`pulsar` 由 `deploy/pulsar/entrypoint.sh` 包装启动——
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
              └─ 其余         ──> astro:4321     (SSR)
```

后端 REST 前缀为 `/api/v1`,GraphQL 为 `/graphql`。APISIX 用 Docker 内嵌 DNS(`dns_resolver: ['127.0.0.11']` + `discovery_type: dns`)在运行时动态解析 `backend`/`astro`,不依赖启动期 DNS。

> `static` 服务(**纯静态官网**)不挂在 APISIX 的主域名路由下,由独立容器输出并映射到主机 `${LKM_STATIC_PORT:-8082}` 端口,可直接从 `http://<主机IP>:8082` 访问(经 APISIX 的 `.icu` 域名路由亦可)。

## 前置条件

- 一台有公网 IP 的 Linux 主机,防火墙/安全组放行 `80` 与 `443` 端口。
  > MinIO 不开放独立公网端口:对象存储经 APISIX `/lkm/` 路径转发到 `minio:9000`(仅内网),
  > 浏览器访问经 APISIX 统一入口即可,无需在安全组另开 9000。
- **域名可选**:有域名走 `lkm.s12mc.xyz` + Let's Encrypt 正式证书;**无域名可用公网 IP 直连**——
  此时走 **HTTP(80)+自签证书(443)** 模式(见下文「无域名/IP 直连」一节),浏览器访问 IP 即可。
- 已安装 Docker 与 Docker Compose 插件(`docker compose version` 可正常输出)。

## 一、获取代码

三个仓库需按如下目录结构放置(根仓库为编排入口,两个子项目各自独立):

```
LKM-Website/                  # 根仓库(含 docker-compose.yml 与本教程)
├── docker-compose.yml
├── DEPLOYMENT.md
├── dev.bat / dev.ps1 / dev.sh
├── deploy/
│   ├── initdb/               # PostgreSQL 首启初始化脚本(auth 独立库建库)
│   ├── apisix/               # 全站公网入口 APISIX 声明式路由/SSL 渲染/冒烟脚本
│   └── certbot/              # certbot 常驻入口脚本(webroot 申请与续期)
├── LKM-official-website/     # 前端仓库(含前端 Dockerfile)
└── LKM-service/              # 后端仓库(含后端 Dockerfile)
```

示例:

```sh
git clone https://github.com/Alma1314/LKM-Website.git
cd LKM-Website
git clone https://github.com/LKM-AHZ/LKM-official-website.git
git clone https://github.com/LKM-AHZ/LKM-service.git
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
# 换域名只改这两个:render.sh 据此展开 APISIX 的 hosts / CORS 来源 / MinIO Host 改写 / 证书 SNI。
# LKM_COMMUNITY_DOMAINS=lkm-ahz.ltd      # 社群站(/api、/graphql、认证面、MinIO 预签名 host)
# LKM_OFFICIAL_DOMAINS=lkm-ahz.icu       # 官网静态站
# 上传上限(字节):同一个值同时给后端校验与网关 client-control.max_body_size
# LKM_MAX_UPLOAD_BYTES=104857600

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
# LKM_S3_PUBLIC_ENDPOINT_URL=http://124.220.55.235

# 可选:GitHub OAuth 登录(不启用可留空)
LKM_GITHUB_CLIENT_ID=
LKM_GITHUB_CLIENT_SECRET=
```

生成随机密钥:

```sh
openssl rand -hex 48
```

> 若启用 GitHub OAuth,需在 GitHub App 后台把回调地址设为
> `https://lkm.s12mc.xyz/api/v1/auth/oauth/github/callback`。

## 三、构建并启动

```sh
cd LKM-Website
docker compose up -d --build
```

首次构建需拉取基础镜像与依赖,可能耗时数分钟。启动顺序由 `depends_on` 健康检查保证:先 `postgres`、`redis`、`minio`、`pulsar` 就绪,再启动 `backend`/`auth` 与各 `worker`,前端 `astro`/`static` 就绪后网关 `apisix` 再启动。其中 `pulsar` 的 `healthy` **已蕴含**租户与 namespace 初始化完成(见上「Pulsar 无状态化」),故不存在等待一次性 init 容器的步骤。

## 三·六、网关：APISIX（M5 7.2.4，全栈唯一网关）

接入层为 **APISIX standalone**（无 etcd，路由声明式来自 `deploy/apisix/apisix.yaml`）：

- `apisix-render` sidecar 读路由模板 + certbot 证书，渲染出内联 PEM 的 `ssls` 段写入共享卷（每 6h 或重启时重渲染），APISIX 监测文件变化自动 reload。
  它同时是**网关配置的单一模板展开点**：模板里只放占位，域名与请求体上限从环境变量展开——
  `LKM_COMMUNITY_DOMAINS`/`LKM_OFFICIAL_DOMAINS` → 各路由 `hosts`、CORS `allow_origins`、MinIO Host 改写、证书 SNI；
  `LKM_MAX_UPLOAD_BYTES` → 各路由 `client-control.max_body_size`（与后端校验同源）。
  模板里若残留未展开占位，render 会**拒绝覆盖**上一版配置并在日志报错，不会把坏 YAML 喂给 APISIX。
- `acme-webroot` 是极小的 http-01 challenge 静态 responder（不承担网关路由）。
- **CORS 与登录限流的归属**：CORS 只在网关（应用层生产不挂，非生产才挂供本地跨域调试）；
  登录限流是**两层分工而非重复**——网关按 IP 粗粒度削峰（`policy: local`、60/60s），
  应用做账号级精确锁定（用户名级 + 真实 IP 级 Redis 滑动窗口，IP 取自网关注入的 `X-Real-IP`）。
  两层数值刻意不同，不要当成"重复"去同步。
- **nginx 已彻底移除**：旧网关曾以 `profiles: ["nginx-gateway"]` 作回退路径保留，但它已与 APISIX 路由分叉
  （如 `/api/` 未开 WS upgrade → `/api/v1/ws/events` 经回退路径不可用），成为一份会腐烂的第二真相源；
  回退机制改由 git 承担（`git revert` / 检出历史 tag 得到的是「当时一致」的整套配置）。
  全栈仅存的 nginx 镜像是 `acme-webroot` 与官网 `static` 两处**静态文件服务器**角色（非网关），二者与
  APISIX 是互补关系而非重叠。

**运行时冒烟/验收**（网关 up 后，在仓库根执行）：

```sh
sh deploy/apisix/smoke.sh 127.0.0.1          # 13 项：301/健康/GraphQL/官网/限流/MinIO/缓存/WS/…
SMOKE_HEAVY=1 sh deploy/apisix/smoke.sh      # 追加 100m 上传边界（真发 ~101MB）
```

脚本用 `--resolve <域名>:<端口>:127.0.0.1` 保证 TLS SNI 正确（APISIX 按 SNI 选证书，直连 IP 无 SNI 会握手失败），并用 `--noproxy '*'` 绕过宿主机代理。2026-09-14 真机全栈验证 13/13 绿，详见 `LKM社区开发方案/执行路线图.md` §7.2.4 / §8 #19。

## 三·七、Prefect 编排（M5 7.2.5，profile=prefect）

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

## 三·八、ClickHouse 分析管道（M5 7.2.6，profile=clickhouse）

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

## 三·九、监控面板（M6.12，profile=monitoring）

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

## 三·五、无域名 / 公网 IP 直连(可选)

没有域名时,用公网 IP 直连(如 `http://124.220.55.235`)。需把默认写死的域名 `lkm.s12mc.xyz`
替换为你的公网 IP,并把访问方式从「强制 HTTPS」改为「HTTP 为主 + 自签证书兜底」。

改造点(改了如下文件,按你机器 IP 替换,勿再 clone 到默认域名配置):

```sh
# 1. 根仓库 docker-compose.yml:后端域名变量改成 IP(HTTP)
LKM_RP_ID: 124.220.55.235
LKM_ORIGIN: http://124.220.55.235
LKM_GITHUB_REDIRECT_URI: http://124.220.55.235/api/v1/auth/oauth/github/callback
LKM_FRONTEND_CALLBACK: http://124.220.55.235/login/success

# 2. 前端
#    src/data/config.yaml:site 改 http://124.220.55.235
#    astro.config.ts:allowedHosts 加 "124.220.55.235"

# 3. deploy/apisix/apisix.yaml:各路由 hosts 列（IP 无法配 hosts，需另加按 priority 兜底的路由）；
#    deploy/apisix/config.yaml 的 redirect.https_port 与 dns 解析按需调整
```

> **注**：网关自 M5 7.2.4 起为 APISIX，无域名/IP 直连改造只需改上述第 3 步（`deploy/apisix/` 下两个
> YAML），未在本教程展开。

- **certbot 服务可停**(`docker compose stop certbot`):无域名不签正式证书,其会循环空跑 renew 报错污染日志。
- **403 后台明文限制**:admin 后台 cookie 带 `Secure`,**纯 HTTP(80)下浏览器不发送** → 后台登录会话无法保持。
  后台请走 **`https://IP`**(自签证书,浏览器首次点"继续访问/信任")。普通用户前台走 JWT,HTTP 下正常。
- 浏览器访问 `http://124.220.55.235` 即可查看站点。

## 四、首次签发 HTTPS 证书

`apisix-render` 首次渲染时若发现无证书,会生成自签占位证书(保证 APISIX 能带 TLS 启动)。正式签发:

```sh
docker compose run --rm --entrypoint certbot certbot certonly --webroot \
  -w /var/www/certbot -d lkm.s12mc.xyz

# 触发 apisix-render 立即重渲染（把新证书内联进 ssls 段），APISIX 监测到文件变化自动 reload
docker compose restart apisix-render
```

签发成功后证书落在 `certbot_conf` 卷(`/etc/letsencrypt`),重渲染后 443 端口即使用正式证书。
(平时无需手动:`apisix-render` 每 6h 重渲染一次,会顺带拾取续期后的新证书。)

## 五、验证

```sh
# 首页
curl -I https://lkm.s12mc.xyz/

# HTTP 应 301 到 HTTPS
curl -I http://lkm.s12mc.xyz/

# 后端健康检查
curl https://lkm.s12mc.xyz/api/v1/health
# 期望: {"code":0,"msg":"OK","data":{"status":"ok"}}

# GraphQL(示例查询)
curl -X POST https://lkm.s12mc.xyz/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ __typename }"}'

# 静态资源缓存头(应含 Cache-Control: public, immutable)
curl -I https://lkm.s12mc.xyz/_astro/<某资源路径>

# 成员头像(头像已对象存储化,key 形如 avatars/<uid>/v<ms>.webp,经 /avatar/{user_id} 读取)
curl -I https://lkm.s12mc.xyz/api/v1/avatar/<user_id>
# 期望: 200(头像由后端从 S3 流式返回)

# 证书链与有效期
openssl s_client -connect lkm.s12mc.xyz:443 </dev/null 2>/dev/null | openssl x509 -noout -dates
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
- 本地无集群时可用 kind 验收：`sh deploy/k8s/overlays/kind/setup.sh`。

## 数据库

### 默认方案：docker 内置 PostgreSQL

`docker compose up` 会自动拉取 `postgres:16-alpine` 镜像并启动;后端首次启动时通过 Alembic 自动建表,无需手动初始化。

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
- **数据库**:使用 PostgreSQL(`postgres:16-alpine` 服务,卷持久化)。后端经 `LKM_DB_*` 环境变量以 `postgresql+asyncpg` 连接;首次启动时 alembic 自动建表。
- **换域名**:网关侧只需在 `.env` 改 `LKM_COMMUNITY_DOMAINS` / `LKM_OFFICIAL_DOMAINS`(hosts、CORS 来源、MinIO Host、证书 SNI 全量跟随,见「单一来源」),再 `docker compose up -d apisix-render` 重渲染;此外还要改后端**自身身份**类配置 `LKM_ALLOWED_HOSTS`/`LKM_ORIGIN`/`LKM_RP_ID`/`LKM_GITHUB_REDIRECT_URI`/`LKM_FRONTEND_CALLBACK`/`LKM_S3_PUBLIC_ENDPOINT_URL` 与前端 `PUBLIC_SITE_URL`/`PUBLIC_BASE_PATH`,并重新签发证书。

- **头像/文件上传 404**:MinIO 桶未创建(S3 不自动建桶)。先 `mc mb .../lkm` 建桶(见上文「MinIO 首次初始化」)。

- **上传返回 403 SignatureDoesNotMatch**:boto3 对 MinIO 默认生成 SigV2 签名,MinIO 不认 → 需在 s3.py 预签名 client 显式 `signature_version="s3v4"` + `addressing_style="path"` + 给 region。且预签名 URL 的 host 必须与浏览器实际访问的 host 一致(`LKM_S3_PUBLIC_ENDPOINT_URL`)。

- **上传经 APISIX 后 400 Bad Request**(而直连 MinIO 正常)**:MinIO 路由的 Host 必须落为公网站点(SigV4 预签名按公网 host 签)(`deploy/apisix/apisix.yaml` 的 `minio` 路由用 `pass_host: rewrite` + `upstream.upstream_host`;用插件 `proxy-rewrite.host` 会被 pass_host 以 nil 覆盖 → 空 Host → MinIO 400)。

- **MinIO 建议经 APISIX 转发而非开公网 9000**:compose 里 minio 保持仅内网,由 APISIX `/lkm/` 路径转发;安全组只需放行 80/443。

- **后台登录后操作报「需要 MFA」**:登录不再强制 2FA(对齐 GitHub),仅后台危险操作(板块审核等)要求 2FA;通过后信任 1 小时。首次需在后台完成 2FA 设置。
