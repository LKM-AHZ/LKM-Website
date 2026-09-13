# LKM 网站开发教程

本文档说明如何在本地开发 LKM 网站(前端 Astro + 后端 FastAPI),以及团队协作约定。
与 `DEPLOYMENT.md`(生产部署)分工:**本文件讲本地开发**,另一份讲线上部署。

## 文档分工

| 文件 | 面向 | 内容 |
|---|---|---|
| `DEVELOPMENT.md` | 开发者 | 本地跑通三仓库、日常开发、测试与门禁、协作约定 |
| `DEPLOYMENT.md` | 运维/发布 | 生产单机 docker-compose 部署、证书、备份、常见运维 |

---

## 一、仓库结构与文档约定

LKM 网站由三份独立 git 仓库组成(根仓库仅做编排,包含本教程与 dev 脚本):

```
LKM-Website/                  # 根仓库(编排入口,含 docker-compose.yml / dev 脚本 / 本教程)
├── DEVELOPMENT.md            # 本文件
├── DEPLOYMENT.md             # 生产部署教程
├── docker-compose.yml        # 生产编排(nginx/astro/static/postgres/redis/minio/backend/worker 等)
├── dev.bat / dev.ps1 / dev.sh# 本地一键启动脚本
├── .gitignore                # 忽略 .env、记忆目录等敏感/本地文件
├── docs/                     # 设计文档与需求总结(被 gitignore 忽略,不入库)
├── LKM-official-website/     # 前端仓库(Astro + Vue/React islands)
└── LKM-service/              # 后端仓库(FastAPI,REST /api/v1 + 论坛域 GraphQL)
```

> 三个仓库彼此独立,各自有 `.git`。根仓库只放编排与文档,**不会也不能**包含子项目代码。

---

## 二、环境要求

- **Git**:管理三个仓库。
- **Node.js + pnpm**:前端依赖与开发服务器(用 pnpm,勿用 npm)。
- **Python 3.13 + uv**:后端依赖与运行。
- **Redis(可选)**:后端 `LKM_REDIS_URL` 留空时会**回退到单机内存版限流**(fail-open),
  本地开发不装 Redis 也能跑;需要调试共享限流/任务队列时再启动 Redis。

---

## 三、本地快速开始

### 方式一:一键脚本(推荐)

根目录提供的统一启动脚本,会自动安装依赖、生成开发密钥、并发启动前后端:

```sh
# Windows(bat)
.\dev.bat            # 前后端一起(单窗口实时交错日志,Ctrl+C 全部停止)
.\dev.bat front      # 仅前端
.\dev.bat back       # 仅后端

# 或 PowerShell 直接调用
powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1 -Mode all

# bash
./dev.sh           # 前后端一起
./dev.sh front     # 仅前端
./dev.sh back      # 仅后端
./dev.sh --no-run  # 仅装依赖不启动
```

脚本自动完成的事:

1. 装依赖(`pnpm install` + `uv sync`)。
2. 后端在非宽松环境强制校验 JWT/TOTP/验证码密钥;未配置时自动生成随机开发密钥注入。
3. 并发启动前后端。

### 方式二:手动分窗启动

```sh
# 终端 1 —— 后端
cd LKM-service
uv run uvicorn main:app --reload --port 8000

# 终端 2 —— 前端
cd LKM-official-website
cp .env.example .env      # 首次;设置 API_URL=http://127.0.0.1:8000
pnpm dev
```

本地使用 **PostgreSQL**(连接参数见 `LKM-service/.env.example`);默认端口:前端 `4321`、后端 `8000`。

---

## 四、后端开发(LKM-service)

### 环境变量

后端通过 `LKM_` 前缀读取环境变量(详见 `app/core/config.py`)。宽松环境
(`dev`/`local`/`test`/未设)放行任何密钥用于本地;`production` 才强制强随机密钥。

本地若需显式配置,可在 `LKM-service/` 建 `.env`:

```sh
LKM_JWT_SECRET=<开发用随机串>
LKM_TOTP_ENCRYPTION_KEY=<与 JWT 不同>
LKM_VERIFICATION_CODE_PEPPER=<与上面都不同>
# 不设以上时,dev 脚本也会自动生成
```

- 数据库:PostgreSQL;设 `LKM_DB_HOST/PORT/NAME/USER/PASSWORD`(见 `LKM-service/.env.example`)。
- Redis:设 `LKM_REDIS_URL=redis://...` 启用共享限流与任务队列;留空回退单机(限流失效、任务队列不消费)。

### 对象存储(文件库与头像)

后端存储抽象为 Local/S3 双后端(`LKM_STORAGE_BACKEND`,默认 `local`)。本地开发默认走本地磁盘:

- **本地磁盘存储**:文件库存在 `files_store/`;头像按 `avatars/<uid>/v<ms>.webp` 存放。
  均经 `get_storage()` 统一读写。
- **头像端点**:`GET /api/v1/avatar/{user_id}`,从 storage 流式返回(`Content-Type: image/webp`)。
- **切 MinIO/S3 对象存储**:设 `LKM_STORAGE_BACKEND=s3`,并配
  `LKM_S3_ENDPOINT_URL`(本地 MinIO 填 `http://127.0.0.1:9000`)、`LKM_S3_BUCKET`(默认 `lkm`)、
  `LKM_S3_PREFIX`(默认 `files`)、`LKM_S3_ACCESS_KEY` / `LKM_S3_SECRET_KEY`。
  生产 compose 已默认 `s3`,桶在首次部署时手动用 `mc mb` 创建(S3 不自动建桶)。
- **存量迁移**:本地磁盘的文件库已有存量时,在切换 S3 前跑一次性脚本搬迁(幂等):
  `./.venv/Scripts/python.exe -m scripts.migrate_files_to_s3`。

### 任务队列(worker)

后端用 Redis + ARQ 消费异步任务(节点事件推送、发送、积分事件等),生产由 compose 的 `worker` /
`worker-send` / `worker-points` 三个服务独立消费。本地 dev 脚本不启动 worker,需要验证队列消费时手动起:

```sh
uv run python -m app.core.worker_default   # 默认队列
uv run python -m app.core.worker_send      # 发送队列
uv run python -m app.core.worker_points    # 积分事件队列
```

### 测试

```sh
uv run pytest                 # 单元/接口测试,默认排除 integration 标记
uv run pytest -m integration  # 显式运行需真实 Redis 的集成测试(否则 skipped)
```

`addopts` 默认 `-m "not integration"`,日常 `uv run pytest` 不会碰 Redis。
测试函数可用前缀 `test_*` 或 `should_*`,asyncio 自动模式(auto)开箱即用。

### 类型门禁与 lint

```sh
uv run ty check       # 硬门禁:类型检查 0 诊断(ty 是硬性要求)
uv run basedpyright   # 可选:更严格的基本类型检查(已降级为辅助,不强制)
uv run ruff check     # 代码风格/静态检查
uv run ruff format    # 代码格式化
```

约定:以 **ty + ruff** 为准(ty 0 诊断 + ruff 干净);`basedpyright` 作为补充可选。
测试文件豁免返回值类型标注(ruff 的 `ANN` 规则于 `tests/**` 关闭)。

---

## 五、前端开发(LKM-official-website)

### 配置

首次复制 `.env.example` 为 `.env`,按需设置:

```sh
API_URL=                # 指向后端:本地 http://127.0.0.1:8000;留空则不请求后端
PUBLIC_SITE_URL=        # 站点对外 URL(可选,默认读 src/data/config.yaml)
PUBLIC_BASE_PATH=       # 子路径部署(可选,默认 /)
```

### 常用命令

```sh
pnpm dev               # 开发服务器(端口 4321)
pnpm dev:clean         # 清 vite 缓存后重启(遇 dev 异常时用)
pnpm check             # astro check + eslint + prettier 全量校验
pnpm typecheck         # 仅 astro check
pnpm lint              # 仅 eslint
pnpm test              # vitest 单元测试
pnpm test:security     # 安全相关测试
pnpm test:auth         # auth 模块测试
pnpm build             # 生产构建(含图标生成 + 静态资源压缩)
```

### 图标

项目用 `astro-icon` + Iconify,新增/修改 `.astro` 里引用的图标后需重新生成白名单,
否则 dev 会报 `Unable to locate icon`:

```sh
node scripts/generate-icons.mjs
```

(`pnpm build` 的构建流程已自动包含此步骤。)

---

## 六、协作约定(轻量)

这里是**当前实际生效**的约定,尽量保持最小、不臆造规范:

- **三仓库独立 git**:前端、后端各自独立提交;根仓库只负责编排与文档。不要在子项目里提交与该项目无关的根级文件。
- **根仓库提交**:托管 docker-compose.yml、dev 脚本、.gitignore、本教程与 DEPLOYMENT.md
- **中文注释**:代码注释如非必要一律用中文;与团队沟通用中文。
- **文档目录**:面向运维的 `DEPLOYMENT.md`、面向开发的 `DEVELOPMENT.md`。
- **测试验收**:后端改完跑 `uv run pytest` + `uv run ty check` + `uv run ruff check` ，前端需要`pnpm run fix` + `pnpm run check` + `pnpm run build`,0error通过后再谈提交。

---

## 七、常见问题

- **前端页面不显示后端数据**:检查 `LKM-official-website/.env` 是否设了 `API_URL=http://127.0.0.1:8000`,设完重启 `pnpm dev`。
- **后端启动报密钥相关错误**:确认 JWT/TOTP/PEPPER 三密钥已提供(非默认占位);dev 脚本会自动生成,手动启动时自行设置。
- **dev 报 `Unable to locate icon`**:新增图标后没跑 `node scripts/generate-icons.mjs`。
- **前端 dev 异常/卡死**:用 `pnpm dev:clean` 清 vite 缓存后重启。
- **集成测试 skipped**:`uv run pytest -m integration` 需要先设置 `LKM_REDIS_URL` 并启动 Redis。
- **数据库是全新的**:后端启动时(`lifespan` 的 `init_db`)默认用 `Base.metadata.create_all()` 自动建缺失表（开发免维护增量迁移；新增表只改 `models.py` 即可，无需手动初始化）;生产/有历史数据的库需显式设 `LKM_USE_ALEMBIC=true` 走 Alembic 增量迁移,手动管理时用 `uv run alembic upgrade head`。
