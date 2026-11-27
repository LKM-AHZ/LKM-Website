# LKM 服务部署教程

> 配置核对：2026-11-28。镜像版本、变量默认值和服务依赖以 `docker-compose.yml` 为准。

> 正式域名尚未确定。本文 `.example` 地址均为占位示例；Compose 默认仅配置本地回环与容器服务名。
> 上线前请显式配置网关域名、允许的 Host、WebAuthn 身份、OAuth 回调及存储公网地址。
> Kubernetes 生产 overlay 还需同步替换 `gateway-tls.yaml` 的证书键和路径。

本文档说明如何把 LKM 的 FastAPI 后端与 Bot 面板通过 APISIX 统一入口部署到生产主机。

> 本文档用于**首次部署、升级和回滚**。已部署环境的日常命令见
> [OPS-CHEATSHEET.md](./OPS-CHEATSHEET.md)，文档职责见 [DOCUMENTATION.md](./DOCUMENTATION.md)。
> 示例中的域名、IP、用户名和密码均为占位符；不要把真实密钥写入本文档或提交到 Git。

## 部署前检查清单

- 服务器时间同步正常，公网安全组只开放实际需要的 `80/443` 和 SSH 端口。
- 已从 `.env.example` 创建 `.env` 并替换所有密码/密钥，或按下文 Infisical 整栈密钥迁移完成注入。
- **`LKM_AUTH_HTTP_TOKEN` 使用强随机值**：模板留空，Compose 拒绝空值，后端生产校验拒绝弱令牌和占位值。
- **`LKM_RESTART_POLICY=unless-stopped`**：默认 `no` 不会在主机重启后自动恢复服务。
- **`LKM_MAX_UPLOAD_BYTES`**：模板与编排默认均为 `104857600`（100 MiB），网关和后端由同一变量派生。
- 默认聊天服务也需要 `.env.example` 中的 Tinode 密钥；客户端 API key 必须与服务端 salt 配对。

- 换域名时另见文末 FAQ「换域名」：后端自身身份的 5 个键也全在 `.env` 里，compose 不再写死。
- `docker compose config --quiet` 成功，且渲染结果中没有空的必填变量。
- 域名 DNS 已指向目标主机；无域名部署已接受自签证书的限制。
- 已确定 PostgreSQL、MinIO 和后端数据卷的备份位置及恢复负责人。
- 生产环境不会直接暴露 PostgreSQL、Redis、Pulsar、MinIO 管理端口或 Grafana 默认密码。

## 架构概览

单机 docker-compose 编排（支持k8s）,APISIX 为统一对外入口:

| 服务 | 端口（对外） | 职责 |
|---|---|---|
| `apisix` | `80` / `443` | **唯一网关**:TLS 终止、HTTP→HTTPS 重定向、反代分流、gzip、CORS 白名单、限流 |
| `apisix-render` | 无 | 纯 shell sidecar:把证书内联进 apisix.yaml 并每 6h 重渲染(触发 APISIX reload) |
| `acme-webroot` | 无 | 微型静态 responder:仅服务 ACME `/.well-known/acme-challenge/`(非网关角色) |
| `certbot` | 无 | 申请与自动续期 Let's Encrypt 证书(webroot) |
| `backend` | 仅内网 `8000` | FastAPI(REST `/api/v1`)+ 论坛域 GraphQL + lag 上报 |
| `auth` | 仅内网 `8001` | AUTH 独立进程(`auth.main`) |
| `worker` | 无 | jobs + user-invalidate 订阅。`python -m boot.workers.default` |
| `worker-send` | 无 | 发送订阅。`python -m boot.workers.send` |
| `worker-notify` | 无 | 对象事件登记订阅。`python -m boot.workers.notify` |
| `worker-notification` | 无 | 站内信生成订阅。`python -m boot.workers.notification` |
| `worker-points-reward` | 无 | points 奖励入账订阅。`python -m boot.workers.points_reward` |
| `worker-points-stats` | 无 | points 行为计数/成就订阅。`python -m boot.workers.points_stats` |
| `worker-points-tasks` | 无 | points 每日任务订阅。`python -m boot.workers.points_tasks` |
| `prefect-server` / `prefect-worker` | 仅内网 `4200` | cron 调度、flow 编排与执行 |
| `worker-dlq` | 无 | 死信落库(`boot.workers.dlq`) |
| `worker-outbox` | 无 | outbox relay(`boot.workers.outbox`) |
| `postgres` | 仅内网 `5432` | 后端数据库(biz `lkm` + auth `lkm_auth`);outbox、`points_ledger` 与 `audit_logs` 为 hypertable |
| `redis` | 仅内网 `6379` | leader 租约、共享限流 / 缓存 |
| `rabbitmq` | 仅内网 `5672`/`15672` | **默认消息总线**(管理端口不发布到宿主) |
| `pulsar` | 仅内网 `6650`/`8080` | **备选消息总线**(standalone,自带 ZK+BookKeeper;6650 broker / 8080 Admin REST)。仅 `--profile pulsar` 启动,见下 |
| `minio` | 仅容器内 `9000`/`9001` | S3 兼容对象存储:文件库文件与成员头像 |
| `lkmbot` | 仅经网关 `/bot/` 子路径 | 社区机器人面板(AstrBot fork)。**可选组件**(`--profile bot`);面板 `6185` 不发布到宿主 |
| `shipyard` | 无 | bot 代码沙箱(旧版 Bay)。**可选组件**(`--profile bot`),挂 docker.sock |
| `worker-content-index` | 无 | 内容与文件检索增量同步 |
| `tinode` | 经网关 `/v0/*` | 聊天服务与附件 |
| `minio-init` | 无 | 首次部署幂等建桶，完成后退出 |
| `clamav` | 无 | 文件病毒扫描 |

> `worker*` 与 `backend`/`auth` 共用 `lkm-service:latest` 镜像,仅启动入口不同;各自常驻消费
> 一个订阅(默认 RabbitMQ 队列;消费失败重投超限后进死信 `system/dlq` / `lkm.dlq-persist`,
> 由 `worker-dlq` 落库)。
> points 拆三个订阅(reward/stats/tasks)消费同一 `biz/points.apply` topic 实现扇出与故障隔离;
> `worker-notification`(M6.8)以第四个订阅消费同一 topic 生成站内信,同样独立记账、互不阻塞。

> **Pulsar 的数据语义**：Compose 的 `deploy/pulsar/entrypoint.sh` 每次启动清空数据目录，
> broker 就绪后重建租户与 `biz/auth/system` namespace，healthcheck 同时检查初始化标记。
> 已发布但尚未消费的消息在重启时丢失；未发布事件仍由 PG outbox 重试。
> 该配置适合本地验证，生产持久化需求应另行部署可靠 broker。
>
> 初始化脚本开启并回读 namespace 的 schema 校验策略。payload 的函数名、参数形状与 routing key
> 由应用层 `LKM-service/core/event_contract.py` 强制，不能以 broker 开关替代应用契约。
> 对应测试见 `tests/test_event_contract.py` 与 `tests/deploy/test_pulsar_config.py`。

### 消息总线：RabbitMQ（默认）与切回 Pulsar

Compose 默认使用 RabbitMQ（`rabbitmq` 服务内置在 `docker-compose.yml`，无需覆盖文件）。
它复用同一套 routing key、outbox、worker 与死信落库；使用持久化的 RabbitMQ quorum 队列，
每个订阅各有一条队列，`points.apply` 的四个订阅仍分别收到事件。消费失败按
`LKM_PULSAR_DLQ_MAX_REDELIVER` 次重投上限进入 `lkm.dlq-persist`，由现有 `worker-dlq` 落库。

1. 在根目录 `.env` 设置 `RABBITMQ_DEFAULT_PASS` 和 `LKM_RABBITMQ_URL`，例如
   `amqp://lkm:<URL编码后的密码>@rabbitmq:5672/`。URL 中的密码需百分号编码，且须与
   `RABBITMQ_DEFAULT_PASS` 一致。RabbitMQ 管理端口只在容器网络内暴露。
2. 直接运行 `docker compose up -d --build`。
3. **切回 Pulsar**：先停止写入、等待 `outbox_pending_count` 和各订阅积压归零（两种 broker
   的在途消息不会自动迁移；不要让两套 worker 同时处理业务流量），再运行
   `docker compose down`（不要加 `-v`），在 `.env` 设 `LKM_MESSAGE_BUS=pulsar`，最后用
   `docker compose --profile pulsar up -d --build` 启动。合并后 Pulsar 仅在 `--profile pulsar`
   时启用；RabbitMQ 服务仍会被 `up` 拉起但无流量，可 `docker compose stop rabbitmq` 省资源。
   切回 RabbitMQ 时反向操作：排空 Pulsar 积压、`down`、去掉 `LKM_MESSAGE_BUS=pulsar` 后再 `up`。

Kubernetes 生产部署可用 `deploy/k8s/overlays/rabbitmq`：先在密钥源设置
`RABBITMQ_DEFAULT_PASS` 和 `LKM_RABBITMQ_URL=amqp://lkm:<URL编码后的密码>@rabbitmq:5672/`，
重跑 `deploy/k8s/gen-secret.sh`，再渲染该 overlay。它继承 `prod` 配置，以 RabbitMQ
StatefulSet 取代 Pulsar。切换已有集群时也需先排空旧订阅，停掉旧 worker，并显式删除
旧的 `pulsar` StatefulSet/Service（普通 `kubectl apply` 不会删除新清单中缺席的资源）；
切换不会搬迁 broker 中的消息。
监控使用 `message_subscription_backlog{broker=...}`；原 `pulsar_subscription_backlog`
保留供旧看板读取 Pulsar 指标。

### 聊天服务：Tinode

聊天由 compose 的 `tinode` 服务（`tinode/tinode-postgres`）承载，客户端经网关 `/v0/*`
直连（HTTP + WebSocket）；账号仍以 LKM 为准，登录时由 `/api/v1/auth/internal/tinode/*`
桥换算成 Tinode 会话。必填密钥与客户端 API key 的生成见 `.env.example`。

实测（2026-11-17，v0.25.3）两个部署约束：

1. **连接用户名必须是 `postgres`**。Tinode 的 postgres 适配器在此用户名之外的场景会忽略
   `DBName`，直接连到与用户名同名的库并失败。compose 使用
   `deploy/initdb/03-tinode-role.sh` 在 PG 首启时创建该角色（`LOGIN CREATEDB`，密码复用
   `POSTGRES_PASSWORD`）。
2. **已初始化的数据卷不会重跑 initdb**。升级既有部署时须手工执行一次：

   ```sql
   CREATE ROLE postgres WITH LOGIN CREATEDB PASSWORD '<POSTGRES_PASSWORD>';
   ```

   随后重启 `tinode`（首启由它自建 `tinode` 库，不要预建空库）。

客户端接入协议要点见 [实时协议的 Tinode 接入](实时协议.md#5-tinode-聊天接入)。

请求分流：

```text
客户端 ──> APISIX(80/443)
              ├─ /api/v1/auth/*、后台认证写面、JWKS ──> auth:8001
              ├─ /api/*、/graphql/v1               ──> backend:8000
              ├─ /v0/*                            ──> tinode:6060
              ├─ /lkm/*                           ──> minio:9000
              └─ /bot/*                           ──> lkmbot:6185
```

`/api/v1/admin/auth/me` 精确路由到 backend；内部 AUTH 端点由网关拦截。
APISIX 通过动态 DNS 发现容器上游。静态官网独立部署，不属于本编排的页面验收范围。

## 前置条件

- 一台有公网 IP 的 Linux 主机,防火墙/安全组放行 `80` 与 `443` 端口。
  > MinIO 不开放独立公网端口:对象存储经 APISIX `/lkm/` 路径转发到 `minio:9000`(仅内网),
  > 浏览器访问经 APISIX 统一入口即可,无需在安全组另开 9000。
- 公网生产环境准备正式域名与证书；本机可使用默认 localhost 配置，自签证书仅用于验证。
  无公网域名的远程验证方式见下文，仓库未交付完整的 IP + 明文 HTTP 部署方案。
- 已安装 Docker 与 Docker Compose 插件(`docker compose version` 可正常输出)。
- 如果需要 k8s 则需要安装 kubeadm 或使用发行版。
- 已有 k8s 集群的情况下只需要安装 kubectl 不需要安装全套。

## 一、获取代码

根仓库作为编排入口，包含桌面客户端、后端与 Bot 三个独立子模块；Compose 只构建服务端与可选 Bot：

```
LKM-Website/                  # 根仓库(含 docker-compose.yml 与本教程)
├── docker-compose.yml
├── docs/DEPLOYMENT.md
├── deploy/
│   ├── initdb/               # PostgreSQL 首启初始化脚本(auth 独立库建库、timescaledb 扩展)
│   ├── apisix/               # 全站公网入口 APISIX 声明式路由/SSL 渲染/冒烟脚本
│   └── certbot/              # certbot 常驻入口脚本(webroot 申请与续期)
├── LKM-desktop/              # Flutter 客户端，不作为服务端容器部署
├── LKM-service/              # 后端仓库(含后端 Dockerfile)
└── LKM-bot/                  # 机器人仓库(AstrBot fork,含 Dockerfile;仅 --profile bot 用到)
```

示例:

```sh
git clone --recurse-submodules https://github.com/LKM-AHZ/LKM-Website.git
cd LKM-Website
```

## 二、配置环境变量

从模板创建根目录 `.env`，逐项填写注释标出的密钥和密码；不要提交此文件。
模板是完整配置入口，下面只列部署时必须核对的类别。

```sh
cp .env.example .env
sh deploy/jwt/gen-keys.sh
# 每个密钥单独生成；Tinode 的字节数/base64 及 API key 配对按模板专用命令处理
openssl rand -hex 48
```

| 类别 | 关键配置 |
|---|---|
| 应用与内部通信 | `LKM_TOTP_ENCRYPTION_KEY`、`LKM_VERIFICATION_CODE_PEPPER`、`LKM_AUTH_HTTP_TOKEN` |
| RS256 文件 | `LKM_JWT_PRIVATE_KEY_FILE=/etc/lkm/jwt/jwt-private.pem`、`LKM_JWT_PUBLIC_KEY_FILE=/etc/lkm/jwt/jwt-public.pem` |
| 数据库和存储 | `POSTGRES_PASSWORD`、`MINIO_ROOT_PASSWORD`、`PREFECT_DB_PASSWORD` |
| RabbitMQ | `RABBITMQ_DEFAULT_PASS`、密码一致且经过 URL 编码的 `LKM_RABBITMQ_URL` |
| 聊天 | `LKM_TINODE_API_KEY_SALT`、`LKM_TINODE_TOKEN_KEY`、`LKM_TINODE_UID_KEY`、`LKM_TINODE_AUTH_TOKEN` |
| 站点身份 | `LKM_COMMUNITY_DOMAINS`、`LKM_ALLOWED_HOSTS`、`LKM_RP_ID`、`LKM_ORIGIN`、`LKM_S3_PUBLIC_ENDPOINT_URL` |
| OAuth（启用时） | client id/secret、`LKM_GITHUB_REDIRECT_URI`、`LKM_FRONTEND_CALLBACK`，并同步 OAuth 平台回调 |
| 运维及可选服务 | 重启策略、上传上限，以及所用 profile 的密码、令牌和地址 |

生产域名示例（替换为实际地址）：

```dotenv
LKM_COMMUNITY_DOMAINS=community.example
LKM_ALLOWED_HOSTS=community.example,backend,auth,localhost,127.0.0.1
LKM_RP_ID=community.example
LKM_ORIGIN=https://community.example
LKM_S3_PUBLIC_ENDPOINT_URL=https://community.example
LKM_GITHUB_REDIRECT_URI=https://community.example/api/v1/auth/oauth/github/callback
LKM_FRONTEND_CALLBACK=https://community.example/login/success
LKM_RESTART_POLICY=unless-stopped
```

网关域名变量只控制路由、CORS 和证书选择，不会自动替换后端身份和 OAuth 配置。
Host 白名单保留容器服务名及回环地址，供内部通信和探针使用。

```sh
docker compose config --quiet
python3 tools/preflight.py --static-only
```

`config` 检查插值和结构；预检检查配置问题。通过这些检查仍需执行启动和目标环境验收。

## 三、构建并启动

```sh
docker compose up -d --build
docker compose ps --all
```

首次构建需拉取基础镜像与依赖,可能耗时数分钟。`depends_on` 等待 PostgreSQL、Redis、MinIO 等基础服务；所选消息总线可晚于应用就绪，worker 会重连，outbox relay 会重试投递，`/readiness` 在已配置 broker 不可达时返回 503。Pulsar 的 `healthy` **已蕴含**租户与 namespace 初始化完成(见上「Pulsar 无状态化」)。

## 三·六、网关：APISIX

接入层为 **APISIX standalone**（无 etcd，路由声明式来自 `deploy/apisix/apisix.yaml`）：

- `apisix-render` sidecar 读路由模板 + certbot 证书，渲染出内联 PEM 的 `ssls` 段写入共享卷（每 6h 或重启时重渲染），APISIX 监测文件变化自动 reload。
  它同时是**网关配置的单一模板展开点**：模板里只放占位，域名与请求体上限从环境变量展开——
  `LKM_COMMUNITY_DOMAINS` → 各路由 `hosts`、CORS `allow_origins`、MinIO Host 改写、证书 SNI
  （多域名用空格分隔，逗号也接受；**首个**域名充当 MinIO Host 改写目标，每域自动带 www 变体 —
  渲染与 `tools/preflight.py` 的证书检查共用同一条分隔符规整规则，两种写法不会各切各的）；
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

**运行时冒烟/验收**（网关 up 后，在仓库根执行）：

```sh
sh deploy/apisix/smoke.sh 127.0.0.1          # 301(社群)/健康/GraphQL/限流/MinIO/缓存/WS/…
SMOKE_HEAVY=1 sh deploy/apisix/smoke.sh      # 追加 100m 上传边界（真发 ~101MB）
SMOKE_BOT=1 sh deploy/apisix/smoke.sh        # 追加 /bot 面板可达（需先 --profile bot 起 lkmbot）
```

脚本用 `--resolve <域名>:<端口>:127.0.0.1` 保证 TLS SNI 正确（APISIX 按 SNI 选证书，直连 IP 无 SNI 会握手失败），并用 `--noproxy '*'` 绕过宿主机代理。
其中第 2b 项专查 `/api/v1/auth/internal/*` 是否被网关挡住（期望 403/404，401/200 都算失败：
那说明内部缝已暴露、只剩共享令牌）。

**金路径验收（经网关，产物才是交付证据）**：

```sh
export LKM_COMMUNITY_DOMAINS=<社群域名>     # 脚本据此推导 https://<域名>；也可直接给 BASE_URL
./scripts/demo_golden_path.sh                # 产物落 docs/acceptance/golden-path-<UTC>.log
```

脚本默认拒绝打 `127.0.0.1:8000` 这类直连地址：直连只覆盖「进程 + DB + Redis」，
会整段绕过 APISIX 路由、`/lkm/` 预签名 Host 改写、CORS、证书与 WS upgrade（历史 502 的现场）。
仅本地调接口时用 `DEMO_DIRECT=1` 显式放行，此时日志头部 `GATEWAY: no`，不能当验收证据。

## 三·六·一、Infisical 整栈密钥迁移

Compose 与 K8s 共用同一套 Infisical `prod` 项目密钥。Infisical 自身的数据库密码、
`ENCRYPTION_KEY` 和 `AUTH_SECRET` 是引导密钥，必须独立保管并与 Infisical 数据库一同备份。
引导命令只启动 Infisical、它的独立 PostgreSQL 与 Redis，不会重建主栈 Redis。
业务库、MinIO、后端/Auth、ClickHouse 等现有环境变量名保持不变，由 Infisical CLI 在**部署时**
注入；K8s 再将注入值生成原生 Secret。此路径无需打开应用内的 `LKM_INFISICAL_ENABLED`。

```sh
# 1) 首次引导：此文件只含 Infisical 自身的三项密钥及重启策略，已被 .gitignore 排除。
umask 077
{
  printf 'INFISICAL_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)"
  printf 'INFISICAL_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 16)"
  printf 'INFISICAL_AUTH_SECRET=%s\n' "$(openssl rand -base64 32)"
  printf 'LKM_RESTART_POLICY=unless-stopped\n'
} > .env.infisical
sh deploy/infisical/bootstrap.sh

# 2) 在本机 http://127.0.0.1:8085 注册管理员、建立项目和 prod 环境。
#    按 https://infisical.com/docs/cli/overview 安装 CLI；`infisical login -i`
#    选择自托管地址，再 `infisical init` 关联该项目。
#    将现有 .env 的真实业务/中间件键值导入 prod；不要导入 change-me 占位值、
#    INFISICAL_* 引导密钥或 LKM_INFISICAL_* 旧应用内拉取配置。
#    必须包含 POSTGRES_PASSWORD、MINIO_ROOT_PASSWORD、CLICKHOUSE_PASSWORD、
#    PREFECT_DB_PASSWORD、LKM_GRAFANA_ADMIN_PASSWORD、LKM_SIGNOZ_JWT_SECRET、
#    LKM_BOT_SHIP_ACCESS_TOKEN、LKM_AUTH_HTTP_TOKEN、
#    LKM_TOTP_ENCRYPTION_KEY、LKM_VERIFICATION_CODE_PEPPER，以及 JWT 的 *_FILE 路径。
#    若启用 OAuth、Meilisearch、OpenSearch 或带鉴权的 Prefect，再导入对应的
#    LKM_GITHUB_CLIENT_SECRET、LKM_SEARCH_MEILI_API_KEY、
#    LKM_SEARCH_OPENSEARCH_PASSWORD、LKM_PREFECT_API_TOKEN。

# 3) 验证所需密钥齐全，然后启动主栈；/dev/null 禁止 Compose 回退读取根 .env。
infisical run --env=prod -- sh deploy/infisical/check-env.sh \
  docker compose --env-file /dev/null config -q
infisical run --env=prod -- sh deploy/infisical/check-env.sh \
  docker compose --env-file /dev/null up -d
```

启用可选 profile 时，把相应的密码/token 一并导入 Infisical，再在最后一条命令中加
`--profile clickhouse` 等。Prefect 是默认服务，`infisical run` 只在部署命令期间注入，
容器仍按原有环境变量启动；轮换密钥后需重新执行并重建对应服务。PostgreSQL 等有状态服务的
账号密码变更还要先完成服务端密码轮换，不能只改 Infisical 的值。RSA 私钥、公钥和 TLS 证书
仍按现有文件/Secret 流程挂载，不写入 `.env`。

K8s Secret 注入流程见 [Kubernetes 部署说明](../deploy/k8s/README.md#部署顺序)。
先创建命名空间并准备 RSA 密钥文件；用空的普通配置文件禁止本地 `.env` 回退，
不要将 `ENV_FILE` 设为 `/dev/null`。

核对 Secret 更新后再部署/重启消费它的 Pod。回滚时使用安全保存的上一版 Secret 与对应数据库
凭据，不要把旧 `.env` 或 Infisical 引导密钥提交到仓库。

## 三·七、Prefect 编排

全部 cron 由 Prefect deployment 调度，经所选消息总线发布事件，由 jobs worker 执行任务。复杂数据管道（如 `user_dim` 对账/回填）继续由 Prefect flow 编排。Prefect server/worker 默认启动；`LKM_PREFECT_ENABLED` 只控制 jobs handler 是否把复杂任务转交 flow。

启动与接线：

```sh
# 1) 配好 PREFECT_DB_PASSWORD 后起全栈（独立 Prefect 库，UI 不发布公网端口）
docker compose up -d
# 2) 可选：开启复杂 flow 转交，重建 jobs worker：
#    LKM_PREFECT_ENABLED=true
#    LKM_PREFECT_API_URL=http://prefect-server:4200/api
#    LKM_PREFECT_DEPLOYMENT=user-dim-reconcile/reconcile
docker compose up -d --force-recreate worker
```

运维：

```sh
# Prefect UI 默认不映射宿主端口；需浏览器访问时，先用本地 override
# 将 127.0.0.1:4200:4200 映射到 prefect-server，再通过 SSH 隧道访问
# 查看 flow run
docker compose exec prefect-worker prefect flow-run ls
# 手动触发一次对账
docker compose exec prefect-worker prefect deployment run 'user-dim-reconcile/reconcile'
# 回填指定用户（在 worker 容器内以本地代码执行 flow）
docker compose exec prefect-worker python -m app.flows.user_dim --backfill --ids <用户UUID1>,<用户UUID2>
```

- 复杂 flow 触发失败会 **fail-open 回落直调**；`LKM_PREFECT_ENABLED=false` 只关闭复杂 flow 转交，不关闭 cron 调度。
- Prefect worker 每次启动都会更新 cron 和 flow deployments。首次从 APScheduler 升级时，先停止旧 `worker-scheduler`；Compose 用包含当前启用 profiles 的 `docker compose up -d --remove-orphans` 清掉旧容器，再确认 `prefect-worker` 运行。K8s 先把旧 Deployment 缩到 0，应用新清单并等待 `prefect-worker` 就绪，最后删除旧 Deployment，避免重复触发。
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
# 3) 可选：走已常驻的 Prefect 触发导出
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
# 按小时汇总（category：日志=service、失败事件=routing_key、审计=action）
curl -s 'http://<host>/api/v1/admin/analytics/app_logs/summary?since=2026-10-01T00:00:00Z&until=2026-10-02T00:00:00Z&interval=hour' -b 'lkm_admin_access=<cookie>'
```

- 汇总接口只接受最长 31 天的时间窗，最多返回 `LKM_CLICKHOUSE_QUERY_LIMIT_MAX` 个时间/类别组合；可用 `interval=day` 降低结果粒度。
- Vector 将待写日志缓存到持久卷（Compose `vector_data`；Kubernetes 节点 `/var/lib/lkm/vector`，每个节点最多 512 MiB）。缓冲满时暂停读取，源日志仍受 Docker/kubelet 轮转限制。
- 表 TTL：`app_logs` 30 天 / `event_failures` 180 天 / `audit_logs` 365 天。首启由 init.sql 建表；既有表需评审后执行对应 ALTER TABLE，修改初始化文件不会更新既有表，也不应为修改 TTL 删除数据卷。
- CH 未启用 / 不可达时：admin 查询返 **503**（不返空列表），周期导出 no-op 不报错。
- 停用：将 `LKM_CLICKHOUSE_ENABLED=false` 写入配置并重建消费该配置的应用，再用 `docker compose stop vector clickhouse` 停止分析组件。

## 三·九、监控面板

Prometheus 抓 `backend` 的 `/metrics`，Grafana 预置「LKM 后端总览」面板。默认不启：

```sh
# 1) 拉起（先设置 LKM_GRAFANA_ADMIN_PASSWORD 强密码）
docker compose --profile monitoring up -d prometheus grafana

# 2) 打开面板（默认只绑回环，不对外暴露）
#    http://127.0.0.1:3000  →  面板「LKM 后端总览」
```

面板内容：QPS（按 handler）、延迟 P50/P95、5xx 错误率、**outbox 积压**
（`outbox_pending_count`）、**消息订阅积压**（`message_subscription_backlog{broker=...}`）、
GraphQL P95 与受控拒绝速率。

- 数据源与面板由 `deploy/grafana/provisioning` 预置（改面板改 `deploy/grafana/dashboards/lkm-overview.json`，30 秒自动重载）。
- **已知限制**：`/metrics` 只挂在单体 `backend`；auth 进程刻意不挂，故面板无 auth 的 QPS/延迟。
- 停用：`docker compose stop prometheus grafana alertmanager alertmanager-render`，保留数据卷。

### 三·九·一、告警投递(Alertmanager)

`deploy/prometheus/rules/` 里的规则只负责**算出**告警;要让人真的收到,还需要 Alertmanager
把告警送出去。此前链路缺这一段:规则在跑,但告警只在 Prometheus UI 里可见,等于没人会知道
(`DBPoolExhausted`、`OutboxBacklogHigh` 这类尤其致命)。

```sh
# 1) 在根 .env 配置接收地址。取值是**凭证**,只放 .env,不进 git:
#    LKM_ALERT_WEBHOOK_URL=https://example.com/hooks/lkm-alerts

# 2) 拉起(prometheus + alertmanager;alertmanager-render 会先渲染配置)
docker compose --profile monitoring up -d prometheus alertmanager

# 3) 验收:Prometheus 已连上告警台,且告警台自身就绪
docker compose exec prometheus wget -qO- http://alertmanager:9093/-/ready
docker compose exec alertmanager amtool --alertmanager.url=http://127.0.0.1:9093 alert
```

要点(都是踩过的坑):

- **改地址后必须重启** `docker compose restart alertmanager`。Alertmanager 不自动重载配置,
  改了 `.env` 不重启等于没改(界面上一切正常,只是还在往旧地址发)。
- **未配置地址时是降级,不是报错**:渲染出「只有 name 的接收器」,告警仍进告警台
  (UI/`amtool` 可见、可打 silence),只是不投递,渲染期会打一条 stderr 警告。
  故意不让它启动失败 —— 告警落不了地是降级,容器起不来会让整套 monitoring 起不来。
- **抑制规则**只在 `deploy/alertmanager/alertmanager.yml.tpl` 里加,且加之前先读对应规则的
  `expr`:把真告警压掉比多收几条通知糟得多。
- **k8s 侧**:webhook 走 Secret(不是 `.env`),缺失时按可选键处理、不会卡住 Pod:

  ```sh
  kubectl -n lkm create secret generic lkm-alert-webhook \
    --from-literal=url='https://example.com/hooks/lkm-alerts'
  ```

  alertmanager 在 k8s 里是**可选组件**(`replicas: 0`),需要时改 1。

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

# 3) 打开 UI（只绑回环；首次注册用户会成为管理员，勿在注册前直接暴露公网）
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
- 停用：关闭应用 tracing 配置并重建相关应用，再停止 `signoz`、`signoz-otel-collector`、`signoz-clickhouse`、`signoz-zookeeper`；数据卷保留。

## 三·十一、LKM Bot 社区机器人(可选,`--profile bot`)

`LKM-bot/` 是 AstrBot 的 fork，提供 IM 平台、后端 API 和独立管理面板。
面板源码在 `LKM-bot/dashboard/`，bot 镜像构建产物到 `bot/dashboard/dist/` 并由 bot 进程服务。
网关将 `/bot/` 静态页、API 和 WebSocket 统一剥前缀后转发到 lkmbot，构建与运行均不依赖官网仓库。

```sh
# 1) .env：配面板初始密码（留空则面板自生成随机密码并打到日志）
#    LKM_BOT_DASHBOARD_PASSWORD=<强随机>   # ≥8 位且含大小写字母+数字，否则面板启动即
#                                          # ValueError 反复重启；openssl rand -hex 全小写会被拒
# 2) SSO 免登（可选但推荐）：配好 RS256 密钥（含公钥），见「二、配置环境变量」的 RS256 段
#    sh deploy/jwt/gen-keys.sh         # 未配则面板回落自带登录页，其余功能不受影响
# 3) 起 bot（网关 /bot 路由随主栈起时已生效，无需重启 apisix）
docker compose --profile bot up -d --build
# 4) 验收
SMOKE_BOT=1 sh deploy/apisix/smoke.sh 127.0.0.1
```

访问方式（二选一，同一个面板）：

- **支持 Bot 管理的客户端**：管理员具有 `admin.bot_panel` 权限时可换取 SSO 票据。
- 直接开 `https://community.example/bot/`：无后台会话时落到面板自带登录页（账号/密码见首启日志或
  上面的 `.env`）。

停用 Bot：`docker compose stop lkmbot shipyard`。带 profile 的 `down` 会停止整个 Compose 项目。

**Bot 管理 BFF（可选）**：backend 可用 API Key 读取面板 OpenAPI v1，配置
`LKM_BOT_API_BASE_URL=http://lkmbot:6185/api/v1` 与 `LKM_BOT_ADMIN_API_KEY`。
客户端入口以当前桌面实现为准；不再沿用旧网页原生页面和 iframe 的交付描述。
K8s 中 API Key 放进 `lkm-secrets`，地址放进 `lkm-config`。

**bot → backend 服务通道（媒体 + 文件库，可选但推荐）**：与上面方向相反——这次是 bot 以服务
身份调后端。配齐后 bot 产出的媒体（TTS 音频、T2I 图片、聊天附件）改存后端对象存储
（Local/S3 同一套，容器重建不丢、多副本共享），并能只读社区文件库中**已审阅通过**的条目。

```sh
# .env：两端填同一把（≥32 位随机串；弱令牌 / 占位符会让后端启动校验告警）
# LKM_BOT_INTERNAL_TOKEN=<强随机>
```

compose 里 bot 侧的地址是固定的容器内网名（`http://backend:8000` / `http://auth:8001`），
媒体公网 origin 复用站点域名变量 `LKM_ORIGIN`，都不需要额外配置。

- 未配 `LKM_BOT_INTERNAL_TOKEN` → 后端 `/api/v1/internal/*` 全部 401（该面关闭，**不会**退化成
  公开可写存储桶）；bot 侧自动回落原来的本地 token 服务，消息照常发得出去。
- 媒体链接是**带过期签名**的公开地址（默认 900s），IM 平台无需携带任何凭据即可拉取；
  签名密钥由同一把内部令牌派生，故令牌轮换会让旧链接立即失效。
- `LKM_ORIGIN` 未配置时媒体 URL 回落到 `LKM_SERVICE_BASE_URL`（集群内网名），只在单机
  开发场景正确。
- 行为开关在**面板配置**里，不在环境变量：`media_storage_mode`（`auto`/`local`/`backend`）。
- 存量文件不迁移：bot 本地已有的媒体仍由旧 token 端点提供（行为未变），新产生的媒体才入库。

**面板身份统一（可选）**：面板登录可改为校验社区账号，不再维护第二套密码。开关是面板配置
`dashboard.auth_mode`：`local`（默认，仅面板密码）、`both`（面板密码或社区管理员账号）、
`backend`（仅社区管理员账号，AUTH 不可用时**失败而非降级**）。委托校验走 AUTH 的内部端点，
需要 `LKM_AUTH_HTTP_TOKEN`（compose 已作为 `LKM_AUTH_INTERNAL_TOKEN` 注给 bot）。只有 `account_level=admin` 的社区账号能进面板——面板是控制面
（可改平台配置、装插件、看日志），没有只读角色可授予其他账号。

**面板静态资源全部自托管**：字体（Outfit / Noto Sans，SIL OFL，随源码打包）、提供商图标
（`@lobehub/icons-static-svg`，构建期打包）、语音检测运行时（构建期从 `node_modules` 复制到
`public/vendor/vad`，已 gitignore）都不再请求第三方 CDN，也不需要额外配置。构建日志里不应再
出现 `cdn.jsdelivr.net` / `fonts.googleapis.com` 的实际请求（`@monaco-editor/loader` 里保留的
CDN 默认值只是死代码：面板始终在 `setupMonaco` 里注入本地打包的 monaco 实例）。

**子路径前缀是单一来源**：面板涉及三处前缀，全部由 `.env` 的 `LKM_BOT_BASE_PATH`（默认 `/bot`）
派生，改这一处即全量跟随，不要再分别改：

| 消费点 | 形态 | 来源 |
| --- | --- | --- |
| 网关路由 `uri` 与剥前缀正则 | 无尾斜杠 | `render.sh` 展开 `__BOT_BASE_PATH__`（compose 传 `APISIX_BOT_BASE_PATH`；k8s 取 `lkm-gateway-config/LKM_BOT_BASE_PATH`）|
| 面板运行期 `BOT_DASHBOARD_BASE_PATH` | 无尾斜杠 | compose 展开同一变量；k8s 的 lkmbot 部署读 `lkm-gateway-config/LKM_BOT_BASE_PATH` 同一个键 |
| 面板构建期 `VITE_BASE_PATH` | **带尾斜杠** | `LKM-bot/Dockerfile` 的 `BOT_BASE_PATH` 参数（compose 同源注入） |

**首次构建**：`docker compose --profile bot build lkmbot` 会在 bot 仓库内独立构建面板，
需要 Node 包仓库或完整本机缓存。源码本机构建使用
`VITE_BASE_PATH=/bot/ pnpm --dir LKM-bot/dashboard build`。k8s 使用同样的 bot 镜像；
自定义子路径时，镜像构建参数 `BOT_BASE_PATH` 应与运行期网关配置保持一致。

**systemd 单元不参与本部署**：`deploy/systemd/lkmbot.service` 是 LKM-bot standalone（系统包
管理器 / AUR，见 `LKM-bot/docs/*/deploy/bot/sys-pm.md`）安装路径的 `systemd --user` 单元，
本站用 compose / k8s，**不使用**它（从 `LKM-bot/scripts/` 迁到此处归档，以免看起来像本项目的
部署面）。

**SSO 票据的协议值是单一来源**：`LKM_BOT_SSO_AUDIENCE` / `LKM_BOT_SSO_ISSUER` /
`LKM_BOT_SSO_TYPE` / `LKM_BOT_SSO_ACCOUNT_LEVEL` 由 compose 的 `x-bot-sso-env` 锚点**只写一次**
默认值、同时注入 auth（签发侧）与 lkmbot（消费侧）；k8s 侧为 `lkm-config-botsso` 一张表，两侧读
同一个键（`lint-imports` 之外，另有静态测试锁两侧默认值一致）。`ttl` 是唯一的例外：只有签发侧
消费，故挂在 auth 服务上、不进共享锚点（k8s 表里有它但 lkmbot 的 keyRef 不列），代码内另有
300s 上界钳制。消费侧**现在会校验 `iss`**——此前签发时写入 `iss` 却从不校验，等于放行任何持同一
audience 的签发方；不符或缺失一律 302 回面板登录页（fail-safe，不会变成 5xx）。注意
`account_level` 同时是**铸票门禁**（`mint_ticket` 与 internal 端点都拿它做相等比较），调低等于
放宽免登范围，详见 `.env.example` 的「LKM Bot」段。

**端口面**——只经网关：

- 面板 `6185` **不发布到宿主**，对外只经 APISIX 的 `/bot/*` 路由（含面板 WebSocket）。
- OneBot v11 `6199` 同样不发布，按 NapCat 的位置二选一：
  - **同机容器**（推荐）：让 NapCat 加入 `lkm` 网络，连 `ws://lkmbot:6199/ws`，无需开端口。
  - **异机**：自行加端口映射（绑定实际内网网卡，如 `<内网IP>:6199:6199`）并在 bot 配置里设 token；
    不要把 6199 挂到 `/bot` 路径上（`/ws` 与面板同 host，鉴权与协议都不同）。

**请求体上限独立**：bot 允许单文件 512MB，而社区站是 100MB，故用 `LKM_BOT_MAX_UPLOAD_BYTES`
（默认 550000000）单独展开到 `/bot` 路由——两个值**不要**合并成同一个变量。

**数据目录**：`./LKM-bot/data`（宿主机 bind，非命名卷）。必须 bind 的原因见下条沙箱共享目录；
副作用是该目录归 root 所有，非 root 运维删除需 sudo。

**面板升级**：重建并替换 lkmbot 镜像，面板随 bot 一起交付。显式的 `--webui-dir` 与
`LKM-bot/data/dist` 优先于内置产物；存在旧覆盖目录时，需由运维核对并移开，才能使用新内置版本。
不再通过重建官网镜像更新面板。

**⚠️ 面板里的平台回调地址要带 `/bot` 前缀**：`callback_api_base`（面板「配置」里）用于给外部
IM 平台回调用，需填 `https://community.example/bot`，否则回调会打到社区站 backend（`/api/v1/webhooks/...`
同前缀）。

**升级注意**：`/bot` 路由不新增证书域，故不再需要单独首签子域证书——`render.sh` 的证书域集合
只剩社群域一个（旧部署里残留的 `bot.community.example` 证书目录可删；官网域已迁出独立部署，不在本栈内）。

**代码沙箱（shipyard，同一 profile）**：

- ⚠️ **安全面**：shipyard 挂 `/var/run/docker.sock`（≈把宿主机 root 交给容器），因此它只在
  `--profile bot` 下启用、用完用 `docker compose stop shipyard` 停止；它 spawn 的沙箱容器落在独立网络 `lkm-bot-sandbox`，
  刻意**不接** `lkm`，否则沙箱里跑的模型生成代码就能直连 postgres/redis/minio。
- ⚠️ **与 bot 默认 booter 不匹配**：bot 默认 `sandbox.booter=shipyard_neo`，而本服务是**旧版 Bay**。
  要生效需在面板「配置 → 沙箱」把 booter 改成 `shipyard`，endpoint 填 `http://shipyard:8156`，
  access token 填 `LKM_BOT_SHIP_ACCESS_TOKEN`。不改则沙箱功能不生效（`computer_use_runtime`
  默认 `none`，不影响 bot 其余功能）。
- `LKM_BOT_SHIP_DATA_DIR` 必须是**宿主机绝对路径**（Bay 原样交给 Docker API 做 bind），默认取
  `${PWD}/LKM-bot/data/shipyard/ship_mnt_data`，故 compose 必须在仓库根执行。

## 无公网域名的验证环境

默认 `localhost` 适用于本机验证。需要远程访问时，可用测试域名配合客户端 hosts/DNS，
并让域名、Host 白名单、origin、RP ID 和证书保持一致。自签证书需由客户端显式信任。
生产使用正式域名和受信证书。

仓库没有交付完整的公网 IP + 明文 HTTP overlay；不要沿用旧手册中修改 Compose 字面量、
移除 HTTPS 路由的步骤。管理员 Secure cookie、WebAuthn 和 TLS/SNI 均需要相符的访问配置。

## 四、首次签发 HTTPS 证书

`apisix-render` 首次渲染时若发现无证书,会生成自签占位证书(保证 APISIX 能带 TLS 启动)。正式签发:

```sh
docker compose run --rm --entrypoint certbot certbot certonly --webroot \
  -w /var/www/certbot -d community.example

# 触发 apisix-render 立即重渲染（把新证书内联进 ssls 段），APISIX 监测到文件变化自动 reload
docker compose restart apisix-render
```

签发成功后证书落在 `certbot_conf` 卷(`/etc/letsencrypt`),重渲染后 443 端口即使用正式证书。
(平时无需手动:`apisix-render` 每 6h 重渲染一次,会顺带拾取续期后的新证书。)

## 五、验证

```sh
# HTTP 重定向及 HTTPS 探针
curl -I http://community.example/api/v1/liveness
curl --fail https://community.example/api/v1/liveness
curl --fail https://community.example/api/v1/readiness

# 只读 GraphQL
curl --fail https://community.example/graphql/v1 \
  -H 'Content-Type: application/json' -d '{"query":"{ __typename }"}'

# 网关契约与证书
sh deploy/apisix/smoke.sh <网关IP>
openssl s_client -servername community.example -connect community.example:443 \
  </dev/null 2>/dev/null | openssl x509 -noout -dates
```

业务响应使用 `message` 字段；就绪状态及失败依赖以实际响应为准。
再用桌面端验证登录、文件上传/下载、考试和聊天；Bot 启用时加测 `/bot/`。
静态官网和旧网页资源路径不在本栈验收范围。

## 六、证书续期(自动)

- `certbot` 容器每 12 小时执行 `certbot renew`,证书文件原地更新。
- `apisix-render` 容器每 6 小时重渲染一次 `apisix.yaml`(内联新证书),APISIX 监测文件变化自动 reload。
  上游容器地址由动态 DNS 发现，当前解析有效期为 30 秒。

无需人工干预;证书与续期状态都在 `certbot_conf` 卷,容器重建不丢。

## 七、升级与回滚

日常命令见 [运维速查](./OPS-CHEATSHEET.md)。升级前记录根仓库与子模块提交、
保留旧镜像标签及配置，并完成备份。更新根仓库后执行
`git submodule update --init --recursive`，构建后端镜像一次，再更新所有共用镜像的
API、AUTH、worker 和 Prefect 服务。环境变量变更用 `up -d` 重建容器。

回滚时恢复对应提交、镜像标签和配置，再检查 readiness、网关冒烟与用户路径。
schema 已变化时先确认旧镜像兼容；需要恢复数据时按下面的恢复演练验证，不能以删卷代替回滚。

## 八、Kubernetes 部署（可选）

入口见 [Kustomize 部署说明](../deploy/k8s/README.md)。先创建命名空间，再导入 Secret 和证书，
最后渲染并应用 overlay。当前清单的渲染阻塞见 Kubernetes 说明；先解决并确认渲染通过。本地 kind 脚本封装了部署步骤：

```sh
sh deploy/k8s/overlays/kind/setup.sh
```

kind 是单节点验证环境。生产需核对存储、broker 持久化、域名/证书、镜像、资源限制和备份；
Compose 与 K8s 的镜像版本、默认 broker 及组件覆盖存在差异，不能视作逐服务等价交付。

## 八·一、切换 L2 后端（Redis ↔ Dragonfly）

L2 缓存 / 跨进程锁 / 限流 / pub-sub 的后端默认是 **Redis 7**，可整套换成 **Dragonfly**
（内存效率、单实例多核更好）。两者共用同一套 RESP 协议，后端的唯一客户端是
`LKM-service/app/core/redis.py` 的 `Redis.from_url(settings.redis_url)`，故**切换不改任何
应用代码**，只改部署侧的镜像与启动参数；Service 名（redis）与 URL（`redis://redis:6379/0`）
都不变。

切之前先读**取舍**：

- **两边都无持久化**。默认 `--save '' --appendonly no`（Redis 侧原先开的 AOF 已关闭），
  Dragonfly 也不再配 `--snapshot_cron` —— 重启即空，两个后端行为完全一致。原先靠 AOF 兜底的
  状态已改为**不依赖持久化**：outbox 租约（短 TTL 自愈）、限流计数（fail-open）、admin 单设备
  撤销（落 DB 表 `revoked_access_tokens`）、feed 大 V 集合（读时按 DB 现算）、直传会话
  （落 DB 表 `upload_sessions`）。
- **灰度（双后端并行）**：设 `LKM_REDIS_URL_SECONDARY` 指向第二后端、`LKM_REDIS_SECONDARY_PREFIXES`
  列出要走它的 key 前缀（逗号分隔，如 `user:snap,feed`），即按业务域把流量逐步切过去；两者都
  留空时行为与单后端**完全一致**。同一前缀恒定落同一后端，故缓存/锁/版本号/epoch 的一致性
  天然成立；L1 失效广播会双发到两个后端。
- **命令面已核对**：只用 RESP 核心命令（含 SETBIT/GETBIT 位图、WATCH/MULTI 事务、
  EVALSHA + NOSCRIPT、SCAN、GETDEL、pub/sub），无 RedisBloom 等模块依赖。
- 多 DB 无忧：Dragonfly `--dbnum` 默认 16，`SELECT 1` 可用。

**compose**（根 `.env`，三行即切，见 `.env.example`「L2 缓存后端」块）：

```sh
LKM_REDIS_IMAGE=docker.dragonflydb.io/dragonflydb/dragonfly:v1.40.2
LKM_REDIS_COMMAND=--dir=/data --dbnum=16   # 不配 snapshot，与 Redis 侧一样不持久化
LKM_REDIS_PING=redis-cli ping
docker compose up -d redis
```

**k8s**（Kustomize component，默认不启用；在目标 overlay 加一行即切）：

```yaml
# deploy/k8s/overlays/{prod,kind}/kustomization.yaml
components:
  - ../../components/redis-dragonfly
```

该 component 见 `deploy/k8s/components/redis-dragonfly/`，覆盖镜像 / 启动参数 / 探针
（改 TCP，不依赖镜像内是否带 CLI）/ 资源。**版本 tag 三处须一致**：该 component、
`.env.example`、`deploy/k8s/overlays/kind/setup.sh`。

**验证**（两个后端跑同一套集成断言，见
`LKM-service/tests/integration/test_redis_backend_compat.py`）：

```sh
cd LKM-service
# Redis 7
LKM_IT_USE_TESTCONTAINERS=1 .venv/bin/python -m pytest -m integration
# Dragonfly
LKM_IT_USE_TESTCONTAINERS=1 \
    LKM_IT_REDIS_IMAGE=docker.dragonflydb.io/dragonflydb/dragonfly:v1.40.2 \
    .venv/bin/python -m pytest -m integration
```

CI 的 integration job 已按这两个后端做 matrix，两边都绿才算兼容不回退。

## 数据库

### 默认方案：docker 内置 PostgreSQL(TimescaleDB)

`docker compose up` 会自动拉取 `timescale/timescaledb:latest-pg16` 镜像并启动;后端首次启动时自动建表(默认通道 `LKM_USE_ALEMBIC=false` 走 `create_all`,见后端 README),无需手动初始化。

**为什么是 TimescaleDB 版**:`outbox_events`/`outbox_archived`/`points_ledger` 和 auth 独立库的 `audit_logs` 被装配为 **hypertable**(按 `created_at` 自动时间分区；已投递的 outbox 行先归档到冷表，冷表再按时间压缩),并在 `points_ledger` 上建**连续聚合视图** `points_daily`(积分度量/行为报表,读口 `/admin/points-report`),详见[后端架构与现状](./后端架构与现状.md) §3.6。`outbox_events` 不设置按时间删除策略，避免未投递事件在长时间故障后随 chunk 被丢弃。压缩率取决于实际数据，须在生产数据上测量；`prefect-postgres`、`infisical-db` 仍是普通 PG 镜像。

两点部署注意:

- **hypertable 的每个唯一索引必须含分区列** → 这三张表的主键是 `(created_at, id)`(`points_ledger` 的幂等键唯一约束也并入了 `created_at`,约束名不变)。业务库由单条基线 `0001_initial` 直接把 `points_ledger` 建成 hypertable 形态（主键/幂等约束已含分区列；连续聚合 `points_daily` 由**应用启动时**装配——它在事务块内建不了，连 DO 块的隐式事务都不行，故刻意不放进迁移）。TimescaleDB 不支持把 hypertable 原地转回普通表；基线的 `downgrade` 会删除业务表，不能用来保留数据回退。
- 引擎不可用时(如误用普通 PG 镜像或手工安装的主机 PG)**不会导致启动失败**:`init_db` 会告警并降级为**普通表**——主键多一列 `created_at` 无副作用,outbox 投递语义与积分幂等(由 `reward` 的按用户行锁 + 预检承担,唯一约束只是兜底)均不变,只是失去分区裁剪/压缩,且**连续聚合视图不会被创建**(`/admin/points-report` 据此返 503,而非返回空列表冒充「无数据」)。

auth 库的 `audit_logs` 由 `0001_auth_baseline` 按 `(created_at, id)` 复合主键建表，并尝试装配为 hypertable。可在两个库分别用 `SELECT extname FROM pg_extension WHERE extname = 'timescaledb'`、`SELECT hypertable_name FROM timescaledb_information.hypertables` 验证装配。

连接数据库:

```sh
docker compose exec postgres psql -U lkm -d lkm
```

常用 SQL:

```sql
\dt          -- 列出所有表
\d content_items -- 业务表；users 在独立 AUTH 库
```

手动执行迁移(一般不需要:启动时按 `LKM_USE_ALEMBIC` 决定走 create_all 还是 `upgrade head`):

```sh
docker compose exec backend alembic upgrade head
docker compose exec backend alembic current
docker compose exec auth alembic -c alembic.auth.ini upgrade head
docker compose exec auth alembic -c alembic.auth.ini current
```

### 备份与恢复

**不要只备份数据库。** 文件库与成员头像都在 MinIO,博客仓库在 `backend_data` 卷里 ——
只 dump PostgreSQL 等于丢文件。用仓库自带的 `tools/backup.py`,覆盖业务库、MinIO 与 backend_data：

```sh
# 备份(产物落在 <仓库>/backups/<YYYY-MM-DD>/,已 gitignore)
python3 tools/backup.py backup
python3 tools/backup.py list

# 恢复(破坏性操作,必须 --yes 确认)
python3 tools/backup.py restore --from backups/2026-09-19 --only db --yes
```

**当前工具的范围限制**：`tools/backup.py` 对 `POSTGRES_DB` 执行单库 `pg_dump`，
不包含同实例的 AUTH/Tinode 库，也不包含 Tinode 附件、Prefect 或可选 Bot 数据。
这些数据必须另行备份，且与主备份使用一致的停写窗口。默认库名示例：

```sh
# 宿主机保存；自定义库名时替换 lkm_auth / tinode
mkdir -p backups/extra
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" lkm_auth' > backups/extra/auth.sql
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" tinode' > backups/extra/tinode.sql
docker compose exec -T tinode tar czf - -C /var/lib/tinode/uploads . > backups/extra/tinode-media.tar.gz
# 保留 Prefect 编排数据库
docker compose exec -T prefect-postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > backups/extra/prefect.sql
# 启用 Bot 时另备份宿主机 LKM-bot/data（停 Bot 后复制），以及所用沙箱数据
```

检查每条命令退出码和产物，按日期保存到独立介质；同时保管恢复所需的配置与密钥。
`lkm-backup.timer` 只调用现有工具，额外数据需纳入自己的定时备份流程。

#### 自动定时(推荐)

手工备份等于「想起来才做」,而没人会发现「三个月没备份」,直到真的需要恢复:

```sh
cp deploy/systemd/lkm-backup.service deploy/systemd/lkm-backup.timer /etc/systemd/system/
systemctl edit lkm-backup.service      # 把 WorkingDirectory 改成实际仓库路径
systemctl daemon-reload
systemctl enable --now lkm-backup.timer
systemctl list-timers lkm-backup.timer # 确认下次触发时间
systemctl start lkm-backup.service     # 先手工跑一次,确认退出码为 0
```

默认每日 03:30(本地时区)、`Persistent=true`(到点机器关着则开机补跑)、
`--keep 14`(保留两周)。**保留策略不是可选项**:只增不减的每日全量备份终会写满磁盘,
而磁盘写满会让 PostgreSQL/MinIO 先于备份工具挂掉,比没有备份更糟。

#### 恢复演练(至少每季度一次)

在独立 Compose 项目和独立目录中恢复，使用独立配置；Bot 的 bind 路径、端口和网络也要隔离。
先启动空库和对象存储，不启动应用，避免应用先建表导致 SQL 恢复冲突：

```sh
COMPOSE_PROJECT_NAME=lkm-drill docker compose up -d postgres minio minio-init
# 确认 postgres / minio 健康、minio-init 完成后恢复工具覆盖的数据
COMPOSE_PROJECT_NAME=lkm-drill python3 tools/backup.py restore --from backups/<日期> --yes
# 对空的 AUTH 库恢复；自定义库名时替换 lkm_auth
COMPOSE_PROJECT_NAME=lkm-drill docker compose exec -T postgres \
  sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d lkm_auth' < backups/extra/auth.sql
```

再恢复 Tinode 数据库、附件及其他启用组件。Tinode 库应先由管理员创建为空库并导入完整 dump，
恢复完成后才启动 Tinode；这与全新部署由 Tinode 自建库的流程不同。
确认恢复到空库，SQL 遇错立即中止；现有非空库需先另行制定清理/重建方案。

数据齐全后启动演练应用并检查：登录、帖子和文件、博客、聊天历史与附件、
AUTH 库用户数、业务库关键表计数。检查通过后清理演练项目；需要删除卷时先核对项目名。
演练记录至少包含备份日期、恢复耗时、核对结果和问题，至少每季度执行一次。

### schema 变更纪律(迁移链与大表)

后端有**两条独立迁移链**,各自单头线性。业务库与 auth 库各只有
**一条自包含基线** revision(`0001_initial` / `0001_auth_baseline`),后续变更再按 `NNNN_语义名`
追加单头增量；每个迁移聚焦一个变更并明确回滚影响：

| 链 | 目录 | 配置文件 | 覆盖 |
|---|---|---|---|
| 业务库 | `LKM-service/alembic/versions/` | `alembic.ini` | 业务域全部表(含 `user_dim` 宽表) |
| auth 库 | `LKM-service/alembic_auth/versions/` | `alembic.auth.ini` | 认证、用户、角色、Tinode 映射及聊天封禁表 |

**默认通道仍是 `LKM_USE_ALEMBIC=false`(create_all)**,迁移链是生产后备;两者不混用。

两条通道必须给出**同一结构**：CI 的 `scripts/check_schema_drift.py` 在空库上跑两条迁移链再跑
`alembic check`，任何「迁移链 ↔ ORM metadata」差异都会让 `test` job 变红（本地同样可跑，需可连 PG）。
**既有库**切换前先备份，并逐项核对表结构、索引和约束；补齐到目标基线后才可 `stamp` 对应 revision。`stamp` 只改版本记录，不会修复结构；不得直接对任意旧库执行 `stamp head`。

在 `LKM-service/` 对空的业务库运行 `alembic upgrade head`，对空的 auth 库运行 `alembic -c alembic.auth.ini upgrade head`，由各自的 `0001` 基线建表。

**改 schema 的规矩**:

1. **加列/加索引**可走 create_all 通道的**加性同步**(`_sync_additive_schema`,只增不改,见[后端架构与现状](./后端架构与现状.md) §3.4)；超过 64 MiB 的大表及 Timescale hypertable 按第 3 步执行。模型改了**也要补一条 alembic revision**,否则 Alembic 通道建出的库缺列。
2. **破坏性变更**(改类型 / 删列 / 改约束 / 改主键)**只能走 alembic 并人工评审**:create_all 通道不会 ALTER,直接改模型会让既有库静默失配。
3. **大表变更分阶段执行**，先出 SQL 评审，不要直接 `upgrade`:

```sh
# 只生成 SQL、不连库执行(逐 revision 双向:upgrade 与 downgrade 各一份)
docker compose exec -e LKM_USE_ALEMBIC=true backend \
  alembic upgrade <prev>:<rev> --sql > /tmp/mig.sql
# 先审查 /tmp/mig.sql；大表的加列、回填、建索引、非空收紧按下方工具分阶段执行。
```

   `content_items`、`content_comments`、`outbox_events`、`outbox_archived`、
   `interaction_view_logs`、`points_ledger` 属大表。已有表超过 64 MiB 或已转 hypertable 时，应用启动的
   加性同步会拒绝自动补列，并跳过自动建索引。先以旧版应用运行，执行以下分阶段操作，
   再发布依赖新列的镜像（命令在 `LKM-service/` 下运行，默认只打印计划，`--apply` 执行）：

```sh
# 例：给 content_items 增加可空列并从现有列回填。每批 500 行独立提交，可中断重跑。
uv run python -m scripts.online_ddl add-column --table content_items --column new_value --type bigint
uv run python -m scripts.online_ddl --apply add-column --table content_items --column new_value --type bigint
uv run python -m scripts.online_ddl --apply backfill --table content_items --column new_value \
  --expression 't.existing_value' --batch-size 500 --max-batches 1000 --sleep-ms 50
# 根据实际模型定义创建索引；在事务外并发建索引，失败后先核对/清理无效索引再重跑。
uv run python -m scripts.online_ddl --apply index --table content_items \
  --name ix_content_new_value --columns new_value
# 仅当新列需要 NOT NULL；先 VALIDATE CHECK，再短锁 SET NOT NULL。
uv run python -m scripts.online_ddl --apply set-not-null --table content_items --column new_value
```

   回填表达式是管理员审核过的 SQL 表达式，可引用表别名 `t`；工具拒绝多语句输入，
   但不会替代 SQL 审核。每次回填有批次上限，尚有 NULL 时返回失败，可调整上限重跑。
   Timescale hypertable 的非唯一索引自动改用 `transaction_per_chunk`；唯一索引需单独评审，
   分 chunk 建索引不支持唯一性。工具执行前会检查同名索引，包括失败后留下的无效索引。
   如需回填已压缩的 `outbox_archived` chunk，先制定解压与恢复压缩的维护窗口；
   压缩 chunk 上的更新仍受 TimescaleDB DML 限制。
   对表达式索引、部分索引、改类型、删列等超出工具范围的变更，单独写可回滚的
   Alembic revision 和运维 SQL，评审后低峰执行。CI 的 `migrations` job 仅做双向离线 SQL
   体检，不代表线上 DDL 已获批准。

### 后端 CI 生产部署

`LKM-service/.github/workflows/ci.yml` 的 `deploy` 仅在 `master`/`main` 上手动触发，
在 `production` environment 中构建推送 SHA 镜像，并更新集群内使用
`lkm-service` 镜像的 backend、auth、worker 与 Prefect Deployment，逐个等待 rollout。
集群清单先按本文件部署；CI 不重放父仓库 Kustomize 清单。Prefect worker 在滚动更新后自动更新 cron 和 flow deployments。

在 **LKM-service** GitHub 仓库设置 `REGISTRY_IMAGE` 变量（如
`ghcr.io/lkm-ahz/lkm-service`）、可选 `REGISTRY_HOST` / `REGISTRY_USER` /
`KUBE_NAMESPACE` 变量；非 GHCR 仓库还需在 `production` environment 设置
`REGISTRY_TOKEN` secret（GHCR 默认使用 `GITHUB_TOKEN`）。
并在 `production` environment 设置 `KUBE_CONFIG_B64` secret：内容为专用 kubeconfig
文件的 base64 单行编码。该身份至少需在目标 namespace 读取、patch Deployment 并读取
rollout 状态；生产镜像为私有仓库时，集群还需预先配置 imagePullSecret。
任一目标不存在或 rollout 失败时 job 失败，不能将镜像推送成功误认作部署成功。
需要人工复核时，在 GitHub 的 `production` environment 配置 required reviewers。

## 数据持久化

| 数据 | 位置 | 备份要求 |
|---|---|---|
| 业务、AUTH、Tinode 数据库 | `postgres_data` | 每个库分别备份，或使用经验证的整实例方案 |
| 文件与头像 | `minio_data` | 与业务库使用一致恢复点 |
| 博客仓库 | `backend_data` | 与业务记录一起备份 |
| 聊天附件 | `tinode_media` | 与 Tinode 库一起备份 |
| Prefect | `prefect_pg_data` | 备份编排运行数据；deployment 定义可由 worker 重建 |
| Bot | `LKM-bot/data` bind 目录 | 启用时单独备份；沙箱按配置另备 |
| Redis | 缓存、限流和租约 | 默认不持久化，重启后重建 |

可选 Infisical、ClickHouse/SigNoz、监控数据和密钥材料按实际启用范围补充备份策略。
命令和工具覆盖边界见上文“备份与恢复”。

## MinIO 首次初始化(建桶)——已自动化,人工只在排查时用

**后端 S3 存储不会自动创建 MinIO 桶**,缺桶时文件库上传与头像读写会全部 404。
因此编排里有一个一次性 job `minio-init`(`minio/mc`):

- `depends_on: minio: service_healthy` → 等 MinIO 健康后再连;
- `mc mb --ignore-existing "$LKM_S3_BUCKET"` → **幂等**,桶名与 `backend` 的 `LKM_S3_BUCKET` 同源;
- `restart: 'no'`、退出码 0 即完成,不常驻。

验证:`docker compose up -d && docker compose ps --all minio-init` 应看到 `Exited (0)`;
`docker compose logs minio-init` 末行为 `minio-init: bucket <名字> ready`。
已有桶会被保留；任务失败时先排查连接、凭据与日志。

仍保留人工命令,只用于「job 失败后手工补一次」的排查场景:

```sh
# 手工建桶(桶名=LKM_S3_BUCKET,默认 lkm)。优先先看 minio-init 的日志找失败原因。
docker exec <minio容器名> sh -c 'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc mb --ignore-existing m/lkm'
```

> 该 job 的存在由部署契约测试 `LKM-service/tests/deploy/test_compose_semantics.py::test_minio_init_creates_the_configured_bucket` 锁定——删掉它或改坏桶名同源关系都会在 CI 里直接红。

> 头像与文件库对象都在该桶内;上传/上传后由后端写回 MinIO,无需再手动预置。

## 迁移存量到 MinIO

首次从「本地磁盘存储」切换到 MinIO 时,若本地文件库已有存量,在**切换前**(`LKM_STORAGE_BACKEND=s3` 生效前)执行一次性迁移脚本把本地数据搬进 MinIO(幂等,空数据安全跳过):

```sh
cd LKM-service
# 需先配好指向 MinIO 的 LKM_STORAGE_BACKEND=s3 及 s3_* 连接参数
uv run python -m scripts.migrate_files_to_s3       # 文件库存量
```

## 常见问题

启动、上传、证书、Bot 与沙箱排障见 [运维速查](./OPS-CHEATSHEET.md#常见故障)。

- **换域名**：更新网关域名、Host 白名单、origin、RP ID、OAuth 回调和存储公网地址；
  用 `docker compose up -d` 重建受影响的 backend/auth、worker 与渲染容器，再签发证书并验收。
- **上传上限**：修改 `.env` 的 `LKM_MAX_UPLOAD_BYTES` 并重建 backend 与 apisix-render；
  Bot 使用独立的 `LKM_BOT_MAX_UPLOAD_BYTES`。
- **数据库变更**：使用迁移或经核对的加性同步；保留数据卷，不将 `down -v` 作为更新步骤。



- **后台看不到「机器人」分组（或 iframe 提示无权限）**：该管理员缺 `admin.bot_panel` 能力点。
  它默认只授予复合角色 `admin:super_admin`（bot 票据换的是面板会话＝Bot 控制面），
  不是「是 admin 就有」。需要时在 `role_permissions` 里给对应复合角色补一行（`enabled=true`），
  再用 `/api/v1/admin/auth/me` 确认 `permissions` 里出现该值；换票成功与拒绝都会写 `audit_logs`
  （`admin_bot_panel_ticket_issued` / `admin_bot_panel_access_denied`）。

- **后台登录后操作报「需要 MFA」**:普通登录免 2FA(产品策略),仅后台危险操作(板块审核等)要求 2FA;通过后信任 1 小时。首次需在后台完成 2FA 设置。
