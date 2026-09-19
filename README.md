# LKM Website 全栈项目

LKM（理科迷）网站的本地开发与部署编排仓库。项目由社区 SSR 网站、纯静态官网、FastAPI 后端、社区机器人面板和 VS Code 博客扩展组成，根目录负责统一启动、容器编排和跨项目文档。

## 项目组成

| 目录 | 技术栈 | 默认端口 | 用途 |
|---|---|---:|---|
| `LKM-official-website/` | Astro 7、Vue 3、React、Tailwind CSS 4 | `4321` | 社区与动态官网，SSR 运行 |
| `LKM-official-static/` | Astro 7、Tailwind CSS 4 | `4321`（独立启动时） | 纯静态官网构建 |
| `LKM-service/` | FastAPI、SQLAlchemy、PostgreSQL、Pulsar | `8000` / `8001` | 业务 API、AUTH 服务及后台 worker |
| `LKM-bot/` | Python、AstrBot fork | `6185`（仅经网关 `bot.` 子域） | 社区机器人面板，可选组件（`--profile bot`） |
| `LKM-on-VSCode/` | TypeScript、VS Code Extension API | — | 博客仓库克隆、编辑与同步 |
| `deploy/` | APISIX、Kustomize、可观测性配置 | `80` / `443` | Compose/Kubernetes 部署资产 |

各子目录是独立 Git 仓库；根仓库只管理编排、部署资产和跨项目文档。提交前请在实际修改的仓库中分别检查 `git status`。

## 快速开始

### 环境要求

- Node.js `>=24`、pnpm `11`
- Python `>=3.13`、[uv](https://docs.astral.sh/uv/)
- Git
- Docker Engine + Docker Compose（运行完整基础设施时需要）

### 本地开发

```sh
# Linux / macOS / Git Bash：安装依赖并启动动态前端、静态官网和后端
./dev.sh

# 只安装依赖
./dev.sh --no-run

# 只启动一个服务
./dev.sh front
./dev.sh site
./dev.sh back
```

Windows 可运行 `dev.bat`，或执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1 -Mode all
```

启动后常用地址：

| 服务 | 地址 |
|---|---|
| 动态前端 | `http://127.0.0.1:4321` |
| 静态官网 | `http://127.0.0.1:4322` |
| 后端 API | `http://127.0.0.1:8000` |
| Swagger UI | `http://127.0.0.1:8000/docs` |
| ReDoc | `http://127.0.0.1:8000/redoc` |

完整步骤、环境变量和排错见 [DEVELOPMENT.md](./DEVELOPMENT.md)。

### 完整容器栈

```sh
cp .env.example .env
# 编辑 .env，至少替换所有生产密钥和密码
docker compose config
docker compose up -d --build
docker compose ps
```

不要把 `.env`、私钥、数据库备份或访问令牌提交到 Git。生产部署前必须阅读 [DEPLOYMENT.md](./DEPLOYMENT.md)。

## 常用验证

```sh
# 动态前端
cd LKM-official-website
pnpm check && pnpm test && pnpm build

# 静态站
cd ../LKM-official-static
pnpm check && pnpm test && pnpm build

# 后端
cd ../LKM-service
uv run pytest
uv run ty check
uv run ruff check

# 社区机器人面板（可选组件，默认不随主栈起）
cd ../LKM-bot
python -m pytest

# VS Code 扩展
cd ../LKM-on-VSCode
pnpm run compile && pnpm test
```

## 文档

从 [DOCUMENTATION.md](./DOCUMENTATION.md) 查看文档地图、适用场景和权威来源。常用入口：

- [本地开发](./DEVELOPMENT.md)
- [Compose 生产部署](./DEPLOYMENT.md)
- [运维速查](./OPS-CHEATSHEET.md)
- [Kubernetes 部署](./deploy/k8s/README.md)
- [后端设计方案](./LKM社区开发方案/后端规划.md)
- [后端执行路线图](./LKM社区开发方案/执行路线图.md)

## 文档与实现的优先级

发生冲突时，按以下顺序判断当前行为：

1. 可执行配置与源码（`package.json`、`pyproject.toml`、`docker-compose.yml`、Kustomize 清单）；
2. 对应子项目 README；
3. 根级开发、部署与运维文档；
4. 规划和路线图中的历史记录。

发现文档过期时，应在同一个改动中修正文档，并给出可执行的验证命令。
