# LKM 项目开发教程

> 核对日期：2026-11-28。命令以当前根仓库脚本与固定的子模块提交为准。

本文档说明如何在本地开发 LKM 桌面客户端、FastAPI 后端与 Bot,以及团队协作约定。
与 `DEPLOYMENT.md`(生产部署)分工:**本文件讲本地开发**,另一份讲线上部署。

> 文档入口与权威边界见 [DOCUMENTATION.md](./DOCUMENTATION.md)。本文命令均从根目录
> `LKM-Website/` 开始，除非代码块前明确要求进入子项目。

## 文档分工

| 文件 | 面向 | 内容 |
|---|---|---|
| `DEVELOPMENT.md` | 开发者 | 本地跑通各子项目、日常开发、测试与门禁、协作约定 |
| `DEPLOYMENT.md` | 运维/发布 | 生产单机 docker-compose 部署、证书、备份、常见运维 |
| `README.md` | 所有人 | 项目总览与最短启动路径 |
| `DOCUMENTATION.md` | 所有人 | 文档地图、职责与更新规则 |

---

## 一、仓库结构与文档约定

LKM 由三个 Git 子模块组成；根仓库维护编排、部署资产、开发脚本与跨项目文档：

```
LKM-Website/                  # 根仓库(编排入口,含 docker-compose.yml / dev 脚本 / 文档)
├── docs/                     # 架构、部署、运维与开发文档(本文件即 docs/DEVELOPMENT.md)
├── docker-compose.yml        # 生产编排(apisix/postgres/redis/minio/backend/worker 等)
├── dev.ps1                   # 本地一键启动脚本(Windows PowerShell 与 pwsh 通用)
├── dev.sh                    # 本地一键启动脚本(Linux / macOS,参数与 dev.ps1 一致)
├── .gitignore                # 忽略 .env、记忆目录等敏感/本地文件
├── LKM-desktop/              # Flutter 桌面客户端与 Vue/WebF 内置小程序
├── LKM-service/              # 后端(FastAPI,REST /api/v1 + GraphQL)
├── LKM-bot/                  # 机器人(bot)
```

> 子项目彼此独立,各自有 `.git`。根仓库只放编排、部署资产与跨项目文档。
> 提交时必须进入对应仓库检查状态，不要假设根仓库的 `git status` 能显示子项目内部改动。

---

## 服务地址配置

项目未确定正式域名。运行默认值仅使用回环地址；文档和生产 overlay 中的 `.example` 地址是待替换示例。

- 桌面端 LKM 服务默认 `http://127.0.0.1:8000`，可在设置中修改，或构建时传 `--dart-define=LKM_SERVER_URL=<服务地址>`；保留的 Solar 后端使用独立的 `NETWORK_SERVER_URL` 构建参数或其设置项。两套地址分别保存。分享链接、账户二维码及网页跳转跟随当前 LKM 服务的 origin，严格匹配协议、主机和端口，不推断别名。
- Android HTTPS 应用链接的主机是打包参数 `LKM_APP_LINK_HOST`（Gradle property 或环境变量，默认 `localhost`）；部署时应与 `LKM_SERVER_URL` 的主机保持一致。更改应用链接主机需要重新打包；自定义 `lkm://` 协议仍可使用。
- Compose 网关域名由 `LKM_COMMUNITY_DOMAINS` 注入，默认 `localhost`；公网部署同时设置 `LKM_ALLOWED_HOSTS`、`LKM_RP_ID`、`LKM_ORIGIN`、OAuth 回调和对象存储公网地址，详见 [DEPLOYMENT.md](./DEPLOYMENT.md)。Bot 面板沿用配置的同源 `/bot/` 路径。
- Kubernetes base/kind 使用本地配置。生产部署需同时替换 `overlays/prod/gateway-domains.yaml`、`site-identity.yaml` 和 `gateway-tls.yaml` 中的示例，保证域名、证书 Secret 键及挂载路径一致；证书脚本通过 `DOMAINS` 或 `APISIX_COMMUNITY_DOMAINS` 接收域名。

## 二、环境要求

- **Git**:管理根编排仓库及三个独立子项目仓库。
- **Flutter/Dart**：桌面客户端，版本与平台工具见 `LKM-desktop/README.md`。
- **Node.js 24+ + pnpm**：Bot 面板及桌面 WebF 模块，使用各自 package.json 声明的版本与锁文件。
- **Python 3.13 + uv**:后端依赖与运行。
- **PostgreSQL**:后端必需；先启动数据库，并创建 `lkm` 数据库。连接参数见
  `LKM-service/.env.example`，未配置时默认连接 `localhost:5432/lkm`，用户 `postgres`。
- **Redis(可选)**:后端 `LKM_REDIS_URL` 留空时会**回退到单机内存版限流**(fail-open),
  本地开发不装 Redis 也能跑;需要调试共享限流、缓存、租约、WS 广播时再启动 Redis；异步任务使用所选消息 broker。

---

## 三、本地快速开始

### 方式一:一键脚本(推荐)

根目录脚本安装依赖并启动 AUTH 进程、业务后端与桌面端：

```sh
./dev.sh            # AUTH(:8001) + 后端(:8000) + 桌面端(flutter run)
./dev.sh back       # 只启动 AUTH 与业务后端
./dev.sh desktop    # 只启动桌面端
./dev.sh --no-run   # 仅安装依赖
```

Windows 使用 `.\dev.ps1`，安装了 pwsh 的 Linux/macOS 使用 `pwsh ./dev.ps1`，参数与
`dev.sh` 一致（也可写 `后端` / `桌面端`）。`all` 为默认模式。AUTH 固定 `:8001`，业务后端通过
`BACKEND_PORT` 覆盖、默认 `8000`；脚本还会起本地网关 `GATEWAY_PORT`（默认 `8002`），把
`/api/v1/auth/*` 转给 AUTH、其余转给业务后端——客户端只有一个服务地址，浏览器/桌面端
指向 `:8002` 才能登录（生产由 APISIX 承担同样的分流）；桌面端设备按当前平台选择，可用 `DESKTOP_DEVICE`
覆盖（如 `android`、`ohos`）。启动桌面端前脚本会安装 webf 依赖并构建小程序资源
（`assets/webf/` 是生成物、不进 git，需要 Node.js 24+ 与 pnpm）。桌面端在脚本中非交互运行，
需要热重载等交互键时请在 `LKM-desktop` 下先执行 `pnpm --dir webf build` 再运行 `flutter run`。脚本会自动注入内部缝地址/令牌。缺少开发密钥时两个
脚本都会补齐（`scripts/prepare_dev_secrets.py`：RS256 密钥对生成到 `deploy/jwt/keys/`，
TOTP/pepper 为每次运行临时生成），环境变量或后端 `.env` 已有配置时不改动。
启动前会检查 PostgreSQL 连接并初始化业务库和认证库的 schema；`--no-run` 不检查数据库。

Linux/macOS 若尚未配置数据库，可先运行 `./scripts/start_dev_db.sh`，在 Git 忽略的 `.dev/`
中创建并启动独立的 PostgreSQL，生成凭据，写入后端 `.env`，同时创建 `lkm` 和 `lkm_auth`
库。需要安装 PostgreSQL 命令行与服务端工具。重启机器后再次运行该脚本即可启动已有实例；
它不会覆盖自定义 `.env`。

若使用已有 PostgreSQL，先启动服务（Linux 常用 `sudo systemctl start postgresql`），
确认 `pg_isready -h localhost -p 5432` 有响应，再按 `LKM-service/.env.example` 创建业务库
`lkm` 并配置用户、密码；使用其他主机或端口时，
在 `LKM-service/.env` 设置相应的 `LKM_DB_*`。AUTH 服务若单独运行，还需要 `lkm_auth` 库和
`LKM_AUTH_DB_*` 配置。生产 `docker-compose.yml` 需要完整生产环境变量，不能直接替代本地数据库准备步骤。

### 方式二:分别启动与桌面热重载

需要分别查看进程日志或使用 Flutter 交互键时，先让根脚本准备开发环境并启动服务：

```sh
./dev.sh back
```

另开终端，从根目录启动桌面端，并把 LKM 服务地址指向开发网关：

```sh
cd LKM-desktop
./buildtools/setup-dev.sh --install
flutter run --dart-define=LKM_SERVER_URL=http://127.0.0.1:8002
```

`assets/webf/` 是生成物，不进 Git；改了 `webf/` 源码后先执行 `pnpm --dir webf build`。
如需完全手动启动，按后端 README 配置双库、RS256 密钥和内部通信变量，分别运行
`uvicorn main:app`（8000）与 `uvicorn auth.main:app`（8001），再运行根目录
`scripts/dev_gateway.py`（8002）。仅启动业务进程不能完成拆分认证登录。

### 方式三:CI 门禁与本地等价命令

每个仓库的门禁都能在本地原样跑一遍，提交前可逐条对照：

| 仓库 | 门禁 | 本地命令 |
| --- | --- | --- |
| 根仓库 | 跨仓部署契约 | `cd LKM-service && uv run pytest tests/deploy -q`（**不需要数据库**） |
| 根仓库 | 文档链接 | `python3 scripts/check_doc_links.py` |
| 根仓库 | 子模块指针 | `python3 scripts/check_submodule_pointers.py`（指针可达 + 子仓 CI 结论） |
| 根仓库 | compose 插值 | `docker compose config --quiet`（先按 `.env.example` 导出必填变量） |
| LKM-service | lint / 格式 / 边界 / 类型 | `uv run ruff check app auth core boot tests scripts`、`uv run ruff format --check app auth core boot tests scripts`、`uv run lint-imports`、`uv run ty check app auth core boot scripts` |
| LKM-service | 测试 | `uv run pytest -q`（需要 PostgreSQL） |
| LKM-desktop | 静态检查 / 测试 | `flutter analyze`、`flutter test`；WebF 改动再跑 `webf/package.json` 对应检查 |
| LKM-bot | 类型 / 格式 / 测试 | `uv run ty check .`、`uv run ruff format --check .`、`uv run pytest` |

几点约定：

- `contracts` 只读根仓库的 compose / deploy 资产，**不需要数据库**——本地没起 PostgreSQL 也能跑。
- 子模块指针改动的正确顺序是：先让对应子仓库的 CI 变绿并 push，再更新根仓库指针；
  `submodule-pointers` 会检查指针 commit 的 check-runs，红的会被拦下。

## 四、后端开发(LKM-service)

### 环境变量

后端通过 `LKM_` 前缀读取环境变量(详见 `core/config.py`)。宽松环境
（`dev`/`local`/`test`，默认 `dev`）允许开发值；其他环境执行生产密钥校验。

本地若需显式配置,可在 `LKM-service/` 建 `.env`:

```sh
LKM_TOTP_ENCRYPTION_KEY=<开发用随机串>
LKM_VERIFICATION_CODE_PEPPER=<与上面不同>
# JWT 为 RS256-only(无 HS256 对称密钥):先生成 RSA 密钥对,让进程读到文件路径
#   sh deploy/jwt/gen-keys.sh
# LKM_JWT_PRIVATE_KEY_FILE=<私钥 PEM 路径>   # 仅签发方(auth)需要
# LKM_JWT_PUBLIC_KEY_FILE=<公钥 PEM 路径>    # 验签方需要
# Bash 与 PowerShell dev 脚本均会补齐缺失的开发密钥；完全手动启动时自行提供
```

- 数据库:PostgreSQL;设 `LKM_DB_HOST/PORT/NAME/USER/PASSWORD`(见 `LKM-service/.env.example`)。
- Redis:设 `LKM_REDIS_URL=redis://...` 启用共享限流、缓存、租约与 WS 广播；未配置时相关能力降级。异步任务需另配消息总线。
- L2 后端可换:默认 Redis 7,也可整套换成 Dragonfly(RESP 兼容,应用代码零改动)。compose 侧
  切换与取舍见 `DEPLOYMENT.md`「八·一、切换 L2 后端」;集成测试对两种后端都能跑,见下「测试」段。

### 对象存储(文件库与头像)

后端存储抽象为 Local/S3 双后端(`LKM_STORAGE_BACKEND`,默认 `local`)。本地开发默认走本地磁盘:

- **本地磁盘存储**:文件库存在 `files_store/`;头像按 `avatars/<uid>/v<ms>.webp` 存放。
  均经 `get_storage()` 统一读写。
- **头像端点**:`GET /api/v1/avatar/{user_id}`,从 storage 流式返回(`Content-Type: image/webp`)。
- **切 MinIO/S3 对象存储**:设 `LKM_STORAGE_BACKEND=s3`,并配
  `LKM_S3_ENDPOINT_URL`(本地 MinIO 填 `http://127.0.0.1:9000`)、`LKM_S3_BUCKET`(默认 `lkm`)、
  `LKM_S3_PREFIX`(默认 `files`)、`LKM_S3_ACCESS_KEY` / `LKM_S3_SECRET_KEY`。
  生产 Compose 默认 `s3`，由一次性 `minio-init` 服务幂等建桶；应用本身不自动建桶。
- **存量迁移**:本地磁盘的文件库已有存量时,在切换 S3 前跑一次性脚本搬迁(幂等):
  `uv run python -m scripts.migrate_files_to_s3`。

### 任务队列(worker)

后端通过消息总线（Compose 默认 RabbitMQ；直接启动时 Settings 默认 Pulsar，按 `LKM_MESSAGE_BUS` 选择）订阅和独立进程消费异步任务；生产 Compose 将默认任务、发送、通知、积分、
内容索引、死信和 outbox relay 分开运行，cron 调度由 Prefect 承载。本地 dev 脚本不启动这些进程，需要验证时按目标订阅单独启动：

```sh
uv run python -m boot.workers.default   # 默认队列
uv run python -m boot.workers.send      # 发送队列
uv run python -m boot.workers.notify    # 对象事件登记
uv run python -m boot.workers.notification  # 站内信
uv run python -m boot.workers.content_index # 内容/文件索引同步
uv run python -m boot.workers.dlq          # 死信落库
uv run python -m boot.workers.points_reward # 积分入账
uv run python -m boot.workers.points_stats  # 积分统计/成就
uv run python -m boot.workers.points_tasks  # 每日任务
uv run python -m boot.workers.outbox    # outbox relay
```

### 测试

```sh
uv run pytest                 # 单元/接口测试,默认排除 integration 标记
uv run pytest -m integration  # 显式运行需真实 Redis 的集成测试(否则 skipped)
# 换 L2 后端跑同一套兼容性断言(Dragonfly;默认 redis:7-alpine)
LKM_IT_USE_TESTCONTAINERS=1 \
  LKM_IT_REDIS_IMAGE=docker.dragonflydb.io/dragonflydb/dragonfly:v1.40.2 \
  uv run pytest -m integration
```

`addopts` 默认 `-m "not integration"`,日常 `uv run pytest` 不会碰 Redis。
`LKM_IT_REDIS_IMAGE` 指定 Testcontainers 起哪个后端(默认 `redis:7-alpine`);
命令面兼容性回归在 `tests/integration/test_redis_backend_compat.py`。
测试函数可用前缀 `test_*` 或 `should_*`,asyncio 自动模式(auto)开箱即用。

### 类型门禁与 lint

```sh
uv run ty check app auth core boot scripts  # 与 CI 类型检查范围一致
uv run ruff check                      # 代码风格/静态检查
uv run ruff format --check .           # 检查格式；去掉 --check 才写入文件
uv run lint-imports                    # 分层边界契约(见 pyproject.toml)
uv run python scripts/check_raw_sql.py # 裸 SQL 门禁:业务查询必须走 ORM
```

静态门禁包括 ty、Ruff、import-linter 和裸 SQL 检查；测试目录类型债务按 CI 的独立检查执行。
测试文件豁免返回值类型标注(ruff 的 `ANN` 规则于 `tests/**` 关闭)。

**金路径验收**:起好后端后可跑 `./scripts/demo_golden_path.sh`(注册 → 登录 → 发帖 →
评论 → 文件审核 → 通知查询),逐步骤 HTTP 状态写入 `docs/acceptance/golden-path-<UTC>.log`。
两条注册路径:

- 真实验证码注册:后端开 `LKM_DEV_CODE_SINK=1`(仅 dev/local/test,生产启动校验会拒绝),
  脚本设 `DEMO_REGISTER_EMAIL` 与 `AUTH_INTERNAL_TOKEN`(= `LKM_AUTH_HTTP_TOKEN`);脚本走
  `/reg/normal` → `/auth/internal/dev-code` 取码 → `/reg/normal/verify`,再用新账号登录。
  验证码只以哈希落库，明文仅由开发内部响应返回。
- 未开 dev-code:只跑 `/reg/local` 做接口 smoke,内容路径用已 seed 的 `DEMO_USER`。

其余可选:`DEMO_USER2` 产生通知、`DEMO_TOTP_SECRET` 自动完成管理员 2FA step-up、
`DEMO_ADMIN/DEMO_ADMIN_PASSWORD` 做文件审核。

**数据库访问一律走 ORM**:PostgreSQL 查询用 SQLAlchemy ORM 与
`core/db/repository.py` 的 `AsyncRepository` 表达,不要写裸 SQL——基类已内置软删除过滤、
批量 upsert(`pg_upsert`)、`update_where`/`hard_delete_where` 等,service 层也靠它守住
「只 flush、不 commit」的分层契约。只有 ORM 无法表达的场景才允许原生 SQL:DDL/索引/扩展
装配与 TimescaleDB 策略(`core/db/init_db.py`)、列的 `server_default` 调 PG 函数
(`core/db/base.py`)、健康探活 `SELECT 1`、以及 ClickHouse(独立客户端,无 ORM)。
`scripts/check_raw_sql.py` 用 AST 扫描守住这条线,放行名单在脚本的 `ALLOWLIST` 里
(新增条目须确认确属 ORM 无法表达的场景)。

---

## 五、桌面与 Bot 面板开发

桌面客户端在 `LKM-desktop/` 开发，复用同仓库的编辑器与原生 UI。内置小程序源码位于
`webf/`，其构建资源随桌面客户端打包。Bot 面板位于 `LKM-bot/dashboard/`，使用自己的
锁文件，构建到 `bot/dashboard/dist/` 并由 bot 进程服务。

具体开发与构建命令以各子仓库 README 和 package.json 为准。

## 六、协作约定(轻量)

这里是**当前实际生效**的约定,尽量保持最小、不臆造规范:

- **多仓库独立 git**:桌面客户端、后端和机器人面板各自独立提交;根仓库只负责编排与文档。不要在子项目里提交与该项目无关的根级文件。
- **根仓库提交**:托管 docker-compose.yml、dev 脚本、.gitignore、本教程与 DEPLOYMENT.md
- **中文注释**:代码注释如非必要一律用中文;与团队沟通用中文。
- **文档目录**:面向运维的 `DEPLOYMENT.md`、面向开发的 `DEVELOPMENT.md`。
- **测试验收**:后端改完跑 `uv run pytest` + `uv run ty check` + `uv run ruff check` + `uv run python scripts/check_raw_sql.py` ；桌面改动运行 `flutter analyze` 和 `flutter test`，面板改动运行对应 package.json 中的检查与构建。

---

## 七、常见问题

- **后端启动报密钥错误**：两个 dev 脚本均补齐缺失开发值；已有但错误的环境变量或 `.env` 不会被覆盖。完全手动启动时需提供 RS256 密钥对、TOTP 密钥与验证码 pepper。
- **集成测试 skipped**:`uv run pytest -m integration` 需要先设置 `LKM_REDIS_URL` 并启动 Redis。
- **数据库是全新的**：默认 create_all 通道建缺失表，并对小表执行受限的加性同步；模型变化仍需维护迁移链。新库可选 `LKM_USE_ALEMBIC=true`；已有库切换前先核对结构和版本，不能直接重跑基线或盲目 stamp。业务与 AUTH 分别初始化，详见部署手册的 schema 变更纪律。
